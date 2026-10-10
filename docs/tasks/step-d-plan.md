# Step D Plan — Re-point the state writers at the engine (PROPOSAL, not executed)

Date: 2026-10-07. Status: **proposed for review**. No Step D change has been made.

**Superseded for execution (2026-10-08):** use
[the remediation plan](remediation-plan-20261008.md). This document retains the original proposal and
review history; its module-import, synchronization, sorting and bridge conclusions are not all proven.

This plan exists because a review of the migration reached the wide edit and the risk profile is not what
it first appeared. It is written to be argued with, and section 8 lists the specific questions a reviewer
should attack.

---

## 1. What Step D is actually for — and it is not the ListView

The framing carried over from the task pack was "move ~150 `ListView.Items` mutation sites onto the
store". Surveying the file changes that emphasis. There are **two** things in the payload region, and
only one of them is a correctness problem:

| | Count | Consequence if left |
|---|---|---|
| Direct ListView mutation (`EditItem`/`CommitEdit`/`Refresh`) in payloads | 81 sites (+16 helper calls) | engine/view coupling; cosmetic |
| **Direct row-property writes in payloads** (`$computer.State = ...`) | **59 sites** | **the identity fence is bypassed** |

The second is the real defect. Measured: the payloads call the **fenced** helpers only **twice**
(`SetComputerTimeoutScript` at `Wuu.Core.psm1:2096` and `:2368`). The other 59 state writes are raw
assignments that never pass through a fence at all.

So Step C — which fenced the two helpers — currently protects almost nothing. A superseded or
force-stopped payload can still overwrite another operation's row through any of those 59 writes. That
is the same defect T007 exists to close, still open in production, and it is the reason Step D must not
be treated as a cosmetic refactor.

**This also means Step C's value is currently latent.** It becomes real when the writes are routed
through it. That ordering is uncomfortable and worth a reviewer's scrutiny: we added a fence before
routing anything through it. The justification is that the fence had to exist and be tested before the
wide edit could be verified against it — but it does mean Step C alone bought no production safety.

---

## 2. Measured inventory (`Wuu.Core.psm1`, 4796 lines)

**Region 1 — helper functions (lines 8–2691).**
`Set-ComputerState` (278), `Set-ComputerTimeout` (331), `Invoke-AutoRecovery` (540), dialog helpers
(619, 637), `Suspend`/`Resume-BackgroundProcessing` (669, 686), **`SafeUpdateListViewItem` (712)**,
`Set-ColumnProportionalWidths` (2691).

`SafeUpdateListViewItem` is the **chokepoint**: it is a real function with ~15 call sites and it wraps
the `EditItem`/`CommitEdit` sequence. It is the single place a row write is already funnelled — but only
in the main session; payloads use their own inlined copy of the same idea.

**Region 2 — payload scriptblocks (1192–2600), the isolated runspaces.**
`$DownloadUpdates` (1192), `$GetUpdates` (1287), `$InstallUpdates` (2148), `$RemoveOfflineComputer`
(2228), `$RestartComputer` (2285).

- 81 direct ListView mutations + 16 `SafeUpdateListViewItem` calls.
- **59 direct row-property writes**, e.g.:
  ```
  1975  $computer.State = 'UpdatesFound'
  2126  $computer.State = 'Error'
  2196  $computer.State = 'Complete'
  2547  $computer.State = 'Timeout'
  ```
- Only 2 fenced-helper calls.

**Region 3 — UI event handlers (2649–4796), the UI thread.**
`$event*` scriptblocks for menus, buttons, keys, clipboard, AD. 50 UI-facing sites: `SelectedItems`,
`SortDescriptions`, `ItemsSource`, `EditItem`/`CommitEdit`/`Refresh`. These are presentation, not state.

---

## 3. Design decisions (each has an alternative; see §7)

### D-a. The payload writes go through the twin, not the module funnel
An injected runspace cannot resolve `Update-WuuOperationState`, so the twin (`SetComputerStateScript`)
is the only available fence. That is why the twin exists.

### D-b. The twin must gain a literal `-Status` parameter
Measured: payloads write arbitrary progress text —
`$computer.Status = "Downloading $($dlStats.Count) Updates ($([math]::Round($dlStats.Sum/1MB))MB)."`
The twin currently has only `-StatusDetail`, which *appends* to a canned string for the state. Routing
those writes through it as-is would **change every progress message**. The twin needs a `Status` literal
that overrides the canned text, mirroring the funnel's own `Status` parameter. This is a required edit,
not an optional one, and getting it wrong is a silent cosmetic regression across the whole UI.

### D-c. `SafeUpdateListViewItem` becomes the single write path in the main session
Rather than editing 15 call sites, its body changes once to route through the store funnel and to stop
being the thing that owns the ListView refresh. Same chokepoint discipline as `Wuu.Gui`.

### D-d. Keep the refresh envelope in D; replace it in E
This is the risk that decides the staging. Payload writes today happen **inside**
`$uiHash.ListView.Dispatcher.Invoke(...)`, which is what makes the `ObservableCollection` safe to touch
from a worker (it is not thread-safe). If D removes that envelope without E in place, the row updates but
**the grid stops refreshing** — a working-but-invisible intermediate state.

So D changes the **write** and leaves the **refresh** alone:

```powershell
# before
$uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
    $uiHash.Listview.Items.EditItem($computer)
    $computer.State = 'Installing'
    $computer.Status = $progressText
    $uiHash.Listview.Items.CommitEdit()
    $uiHash.Listview.Items.Refresh()
})

# after (D)
$uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
    & $SetComputerStateScript -Computer $computer -State 'Installing' -Status $progressText
    $uiHash.Listview.Items.Refresh()          # E removes this line, projection takes over
})
```

`EditItem`/`CommitEdit` become unnecessary once the row is written by the twin (they wrap list-item
editing; the row object is shared by reference), but `Refresh` must stay until E.

### D-e. One site at a time, each verifiable
Each payload write site is an independent, mechanical transform with its own assertion, so a mistake
localises to one state transition rather than the whole app.

---

## 4. Sub-steps

| # | Change | Verify |
|---|--------|--------|
| **D1** | Add `-Status` literal to `SetComputerStateScript` (and `-Status`/`-Color` parity check against the funnel) | extend `Test-WorkerTwinFence`: a literal `-Status` reaches the row verbatim; a `-StatusDetail` still appends |
| **D2** | `SafeUpdateListViewItem` delegates to the store funnel (or the twin) instead of writing the row and owning the refresh | `Test-StateStoreMirror` extended: a `SafeUpdateListViewItem` call is visible through the store |
| **D3** | Convert the 59 payload row-writes to `SetComputerStateScript` calls, ~5 payloads at a time, keeping the `Dispatcher.Invoke` envelope | after each payload: drive its timeout/error path and assert the row settles identically to before; a **store-vs-ListView equality check** after a synthetic run |
| **D4** | Delete the now-redundant `EditItem`/`CommitEdit` pairs (keep `Refresh`) | suites green; `Refresh` count unchanged |
| **D5** | Static gate: assert no payload region contains a direct `$(<row>).(State\|Status\|UpdatesStatus\|Color)\s*=` assignment outside the twin | gate fails if one is reintroduced — this is the assertion that keeps D from rotting |

**D5 is the important one.** Without it, the next feature that reaches for `$computer.State = ...` inside
a payload silently reopens the defect, and nothing would notice — exactly how this one survived.

---

## 5. Verification strategy

1. **Per-site:** each converted write is exercised through its own state transition.
2. **Cross-check:** after a synthetic fleet run, compare **store rows against ListView rows** field by
   field. Any missed site shows up as a divergence. This is the safety net that makes a single-pass
   conversion defensible.
3. **Static:** D5's gate, so the property is enforced rather than merely achieved.
4. **Existing:** all 17 suites, plus the release gate (currently **17 PASS / 1 SKIP / 0 FAIL**, gate
   exit 0), must stay green at every sub-step.

**Honest limitation:** none of this is end-to-end. There is no automated exercise of a *real* download →
install → reboot chain against a live host — that is T028 (disposable hosts, needs elevation). Steps D
and E can be proven correct in structure and in simulated transitions, but "a real patch run still
works" remains unverified until T028. That gap should be stated in whatever release notes come out of
this, not glossed.

---

## 6. Risks

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Progress messages change wording when routed through the twin (D-b) | HIGH — silent, cosmetic, fleet-wide | `-Status` literal + a test asserting exact text for a real progress string |
| Grid stops refreshing if the envelope is removed early (D-d) | HIGH — app looks broken | keep `Refresh` until E; assert a row update still repaints |
| A missed site leaves the two states divergent | MEDIUM | cross-check test (§5.2) + D5 gate |
| `ObservableCollection` touched off the UI thread | HIGH if mishandled | keep `Dispatcher.Invoke` envelopes throughout D |
| `$uiHash` remains a second dependency inside payloads | LOW during D, must be gone by E | tracked as E's entry condition |
| The twin diverges from the module funnel | MEDIUM | existing `Test-WorkerTwinFence` agreement assertions extended per change |

---

## 7. Alternatives considered

- **Big-bang D+E together.** Rejected: it combines a wide mechanical edit with a rendering rewrite, so a
  failure gives no localisation.
- **Convert the ListView sites first, writes second.** Rejected: the ListView sites are cosmetic; the
  writes are the defect. Doing the cosmetic work first delays the only change that closes T007.
- **Delete `Dispatcher.Invoke` in D.** Rejected: breaks refresh until E (§D-d).
- **Have payloads call the module funnel by re-importing Wuu.State in the runspace.** Rejected: the
  helper would not see the same store instance, and the identity comparison would be against a
  different object graph — a fence that compares nothing.

---

## 8. Questions for an independent reviewer

These are the places I am least confident, and where a second opinion would be most valuable:

1. **Is adding a fence before routing anything through it defensible?** Step C's tests pass, but its
   production value is zero until D lands. Should C and D have shipped as one change instead?
2. **Is the "keep `Refresh` in D, remove in E" staging actually safe**, or does it create a window where
   the row and the ListView disagree in a way that matters (e.g. sorting, selection, the
   `clientObservable` index)?
3. **Is `SafeUpdateListViewItem` genuinely a chokepoint**, or are there direct `EditItem`/`CommitEdit`
   paths in the main session that bypass it — and would changing its body alone therefore be
   insufficient?
4. **Is the cross-check test (store vs ListView) sound**, given both may be mutated by the same worker
   concurrently? Could it pass while a race is live?
5. **Is D5's static gate the right shape?** Regex over a payload region is exactly the kind of
   source-pattern assertion the CLI's C2 defect showed can pass while the real behaviour diverges.
6. **Have I mis-scoped the payload region?** The boundaries 1192–2600 were derived from top-level
   scriptblock assignments; if a payload assigns a nested scriptblock, its writes would be mis-attributed.
7. **Does anything in the 59 direct writes need to STAY direct** — e.g. writes that intentionally bypass
   the fence because they establish the row's initial state?

---

## 9. External review (obtained 2026-10-07) and what it changed

Review obtained from Copilot CLI (`--model auto`), 6412 chars. The bridge failed initially (see §10);
the review was taken directly from the CLI instead.

**Its most serious objection — partially verified, and it is a real gap.**
The claim: *routing 59 writes through the twin does not close T007 unless the twin can tell a stale
payload from the live one, and the identity is a string comparison that requires the row to be the SAME
object in the runspace.* If the row arrived as a marshalled copy, the comparison would compare nothing
and every test would still pass.

**Verified in favour of the design:** a row passed into a runspace **is the same instance** — measured
`SAME INSTANCE ACROSS RUNSPACE: True`, and a mutation made inside the runspace was visible in the main
session. So a string identity comparison is meaningful, and the reviewer's specific fear does not hold
for the mechanism as built.

**But the reviewer's recommended test is still missing and I have NOT run it successfully.** It asks for
two payloads driven through **real runspaces** (not direct calls), the first superseded, asserting the
late writer is refused. My attempt failed twice with a **parse error inside the injected function**
(`Missing function body in function declaration`) — the twin never executed, so the unchanged row was a
false negative, NOT evidence the fence holds. This remains an open verification gap: the twin's
refusal semantics are proven in-process (`Test-WorkerTwinFence`, 37 assertions) but not yet through a
genuine cross-runspace supersession.

**Objections accepted (to act on):**

1. **`EditItem`/`CommitEdit` removal is riskier than "cosmetic".** It is the documented way to avoid a
   resort mid-edit, so writing `State`/`Status` on a *sorted* column without it can reorder rows during
   a multi-property write, exposing intermediate states. D4 must be proven **with live sorting active**.
2. **The cross-check test is weak as designed.** It compares two views of the *same shared object*, so it
   agrees trivially and cannot catch a missed site. Fix: assert the store and the ListView hold the same
   **instances**, then assert on a **write log or sequence**, not final state — a transient wrong write
   that is later overwritten is invisible to a post-run comparison.
3. **`SafeUpdateListViewItem` is only a chokepoint for the main session.** The 81 direct sites and the
   payloads bypass it, and payloads *cannot* call it (module function). D2 therefore covers a subset —
   good for the subset, not sufficient alone. Also `-Status` vs `-StatusDetail` confusion is a live
   hazard when routing progress text.
4. **D5 should use the PowerShell AST, not regex.** Regex misses splatting, `$c = $computer; $c.State =`,
   `$_.State`, `Set-Variable`, `$row.('State')` and nested scriptblocks. Parse payload
   `ScriptBlockAst` nodes and flag `AssignmentStatementAst` whose target is a `MemberExpressionAst` on a
   row-variable name.
5. **Region scoping is wrong.** Line ranges 1192–2600 include helper bodies and miss payloads defined via
   `[scriptblock]::Create` or nested. Derive scope from the AST: every `ScriptBlockAst` assigned to the
   known payload names, descending into children.
6. **Some writes should stay direct** — row construction and ownership *acquisition* must not go through
   a stale-writer fence (there is no prior owner). The gate must also cover fields outside
   `State|Status|UpdatesStatus|Color` (counts, timestamps), which D5 as drafted would not.

**Missed entirely (accepted as real):**

- **The twin must not throw.** A property write to a field the row lacks throws inside a runspace and
  kills the payload silently; and a throw inside `Dispatcher.Invoke` surfaces as
  `TargetInvocationException` and can leave the operation hung. The twin should return a bool and
  callers should act on it. (Note: Step A's `Set-WuuRowEngineDefaults` mitigates the *property* half for
  rows entering the store, but not for rows created elsewhere.)
- **The fence guards state, not actions.** A superseded payload keeps running for minutes: its writes are
  dropped, but it can still download, install and call `Restart`. Worth stating explicitly in the plan
  and in the release notes — the fence does not make a stale payload safe, only silent.
- **`Refresh()` from a rejected writer** should be skipped once callers act on the return value.

**Over-engineered per the review:** nothing was called out; the plan's staging was judged sound.

**Status of this document:** the plan is **not** approved for execution as written. Items 1–6 above are
corrections to make first. The single most valuable addition is the real-runspace supersession test,
which neither the per-site tests nor the cross-check provides.

---

## 10. Peer-review bridge defect (found and fixed 2026-10-07)

`ask_copilot` in `~/.gemini/mcp/peer_models.py` hung on any substantial prompt. Cause, measured:

```
UnicodeEncodeError: 'charmap' codec can't encode character '\u2192' in position 10476
```

`subprocess.run(..., text=True)` without an explicit encoding uses the **locale codec (cp1252)**, and the
prompt is the thing being encoded — so any character outside cp1252 (an arrow, a tick, a warning glyph)
raised from `stdin.write` **before the CLI ever started**. A plan document full of such glyphs is
therefore the worst case, and the failure was indistinguishable from a hang.

Three fixes applied to the bridge, each verified:

1. **`encoding="utf-8", errors="replace"`** on both `subprocess.run` calls — the actual fix.
2. **`shell=True` → `shell=False`.** The command is a resolved executable path and the prompt goes on
   stdin, so the shell only added failure modes (re-parsing, and returning the shell's exit code instead
   of the CLI's).
3. **PATH-independent CLI resolution** (`_copilot_candidates`/`_resolve_copilot`). The server runs in the
   VS Code **extension host**, whose PATH is not the developer terminal's; the CLI lives under VS Code
   `globalStorage` and was frequently unfindable, producing the misleading message *"not installed or not
   in PATH"*. Candidates now include the globalStorage path, and a new **`ask_copilot_diagnose()`** tool
   reports interpreter, resolved path, environment and a trivial round-trip.

Timeout raised 120s → 300s (a 2.6 KB review prompt measured ~36s, so 120s was adequate; the raise is
headroom for a full plan). Non-zero exit codes and empty-stdout-with-stderr are now reported explicitly
instead of returning an empty string, which read as "the model said nothing".

Verified outside the MCP host: the fixed function returned `BRIDGE-FIXED-OK` and a coherent two-sentence
review. **The MCP server must be restarted in VS Code for the running process to pick this up** —
retrying the tool against the old process will keep hanging.

