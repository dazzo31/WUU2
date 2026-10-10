# WUU2 GUI Migration Remediation Plan

Date: 2026-10-08. Status: **execution in progress following user authorization; G1-G6 not certified**.

Initial evidence and completed narrow repairs: [phase-1-evidence.md](phase-1-evidence.md).
The real-factory fixture now runs, but broad Step D/E execution still waits for the stated gates.

## 1. Purpose and Precedence

Close the verification and ownership gaps before continuing Step D (writer routing) and Step E
(authoritative projection). This is a local remediation addendum, not a new migration or a release
certification. Retain T001-T030 and R01-R08 from the task pack; the numbered items below are subtasks
of those existing tasks, not replacement task IDs.

This document supersedes the execution instructions and unsupported conclusions in
[step-d-plan.md](step-d-plan.md). Preserve that proposal as review history. It also supersedes the
Phase 1 blanket prohibition on a short state-mutation critical section in
[validation.md](validation.md), and the claim that admission locking alone establishes state safety.
All other validation constraints remain binding. No lock may span a remote call, UI dispatch, prompt,
audit I/O, stop/drain, or wait. Identity fencing remains mandatory, regardless of synchronization.

The source documents are the requirements and dependency inputs for this local plan. This is not a
formal modernization spec/constitution/checkpoint certification. No new architecture artefacts or
application rewrite are required to execute the discovery tasks.

## 2. Evidence and Corrections

Historical GUI baseline: 18 suites, 17 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; release gate exit 0.
The unelevated remote-task skip is not remote coverage. Re-run and record the current baseline before
runtime edits. No successful production-injection supersession test has yet been demonstrated.

Source checked on 2026-10-08:

| Gap | Local evidence | Required correction |
|---|---|---|
| Submission precedes ownership | `src/Wuu.WindowsUpdate.psm1#Start-UpdateCheckJob` builds a job using `BeginInvoke()` before calling `Update-WuuOperationState`; refusal logs that the job still runs | Claim/reserve before starting; refusal must launch no payload; rollback only the failed request's claim |
| Helpers provide no observable verdict | `New-ComputerRunspace` injected state/timeout helpers use bare `return` and empty `catch` | Explicit structured result; errors cannot masquerade as applied/refused writes |
| Same-name replacement is not checked | Helpers look up `stateStore.ByName` but check only that a row exists, not that it is the passed row | Validate live row reference or generation under the same protocol as mutation |
| Identity checks and writes are separate | Helpers read identity and later assign properties/`Touch()` without a shared transaction | Serialize validation, mutation and revision publication; produce snapshots under that protocol |
| Shared-reference equality is tautological | Store mirror and UI currently share rows | Observe accepted/refused write events and independently expected transitions; later prove distinct view objects |
| Real-worker test did not execute | Earlier probe failed with `Missing function body in function declaration` | Use the factory's actual injected scriptblocks and assert entry/execution/result markers |
| Inventory is heuristic | Prior counts use regex and line regions | AST ownership inventory plus runtime path evidence; unresolved dynamic writes block a completeness claim |
| State fence does not stop remote effects | Payloads can invoke download/install/restart independently of row writes | Revalidate authorization/ownership at the effect boundary; document cancellation limits |

Corrections to prior review conclusions:

- Importing `Wuu.State` into a worker does not necessarily copy an explicitly injected store. Module
  local gates are separate, however. Test explicit shared-store/gate injection before choosing a twin.
- `EditItem`/`CommitEdit` are not a proven general atomic transaction. Plain PSObject property writes
  do not guarantee automatic notification or resorting. Keep current edit/refresh behavior until a
  desktop test establishes the replacement's sorting, filtering and repaint behavior.
- A Boolean helper result would lose the module funnel's `{Applied; Refused; Reason}` contract. Use
  that structured contract with explicit error handling, not Boolean truthiness on a returned object.
- Only the bridge's Unicode encoding failure was reproduced conclusively. Direct CLI success and
  Python compilation do not establish a working reloaded MCP host or explain every earlier hang.

## 3. Scope and Execution Rules

Target: `C:\Users\dazzo\OneDrive\GitHub\WUU2`. Donor reference:
`C:\Users\dazzo\OneDrive\GitHub\WUU2-CLI` (no donor edits). Preserve dirty/staged changes and operator
data. No commit, branch, tag, release, live remote mutation or credential changes are implicit.

Windows PowerShell 5.1, STA; retain current PS7 compatibility. Use synthetic rows, inert payloads and
fake remote adapters. No real inventory/config/log files in fixtures. Preserve source encoding,
including existing BOMs. Reuse existing tests before adding a file.

For each subtask, read its named symbols and nearby callers, make a small reversible change, run the
focused check immediately, and record command, environment, verdict, assertion count and limitations
in `docs/tasks/phase-1-evidence.md` (create when implementation begins). Phase 2 work uses
`phase-2-evidence.md`. Source matches and assertion counts supplement behavior; they do not prove it.

## 4. Implementation Sequence

### P1. Re-establish Evidence and Writer Ownership

- [x] **T003.1 [Plan:P1] [R08] Baseline:** run `Scripts/Invoke-TestSuites.ps1` and
  `Scripts/Validate-Release.ps1`; record target/donor HEAD, dirty status and hashes of relevant runtime
  files. Reconcile historical totals with current results rather than requiring an obsolete count.
- [x] **T007.1 [Plan:P1] [R02] Inventory:** parse `src/Wuu.Core.psm1`,
  `src/Wuu.WindowsUpdate.psm1`, `src/Wuu.State.psm1` and their actual worker dependencies using
  `System.Management.Automation.Language.Parser`. Classify row construction, adoption, reset,
  payload progress, terminal result, cleanup, inventory replacement and presentation writes. Include
  ancillary fields (counts, result/error data, heartbeat, deadlines, credentials and lifecycle handles).
  Record source extent, owning payload/handler, writer identity, reader and migration disposition.
- [x] **T007.2 [Plan:P1] [R02,R03] Boundary map:** follow actual submissions from Core handlers into
  `New-ComputerRunspace`, `Start-UpdateCheckJob`, direct `BeginInvoke` paths and cleanup. Include both
  case-insensitive clear-list assignments, config load, remove-offline and replaced same-name rows.
  Classify auxiliary discovery/UI workers separately from engine/action submission.

Deliverable: inventory and boundary tables in the evidence document, including unresolved aliases,
dynamic member names, property bags, nested/string-created scriptblocks and helper calls. AST is not
full data-flow analysis: inspect ambiguous sites and pair the inventory with execution traces.

**Gate G1:** every operation entry, inventory mutation and engine writer has an owner and disposition.
Baseline failures have a documented scope; affected unexplained failures block dependent edits.

### P2. Prove Real Injection and Define the Write Contract

Depends on G1. Own `src/Wuu.State.psm1`, `src/Wuu.WindowsUpdate.psm1` and the existing
`tests/Test-WorkerTwinFence.ps1`, `tests/Test-StateFencing.ps1` suites.

- [x] **T007.3 [Plan:P2] [R02,R03] Real injection harness:** initialize the actual WindowsUpdate
  module context with synthetic store/jobs and inert payloads; create workers through
  `New-ComputerRunspace`. Fetch the actual injected helpers through `SessionStateProxy.GetVariable`
  when diagnosing injection; do not reconstruct function declarations by string concatenation.
  Run A and B in separate real runspaces sharing the authoritative store. Record `ReferenceEquals`,
  captured writer IDs, helper entry/result and error-stream contents. A test must fail on parse,
  import, binding or pipeline errors, even if the row remains unchanged.
- [x] **T007.4 [Plan:P2] [R02] Contract decision:** prefer one headless writer callable from both
  sessions, with store and gate passed explicitly. Prove that module import plus explicit injection
  preserves shared references. If the real factory cannot support it, retain an unbound injected
  helper derived from a single implementation and test agreement. Record the selected option and
  dependency closure before routing payloads; do not assume every funnel parameter already exists.
- [x] **T007.5 [Plan:P2] [R02] Observable outcomes:** implement `{Applied; Refused; Reason}`
  semantics for state and timeout writes. Expected stale/reset/terminal/replaced-row refusals are
  non-throwing. Unexpected defects must be surfaced as a bounded recorded failure, not swallowed.
  Validate mandatory row properties before acceptance; no partial mutation on validation failure.
  Preserve literal `Status`, `StatusDetail`, color, timeout, count and result semantics where used.

**Gate G2:** actual worker injection executes; same-name replacement is refused; accepted progress and
timeout writes return explicit results; every refusal leaves protected fields and revision unchanged.
The initial harness may expose failures: record them as failures, not as completed acceptance.

### P3. Serialize Ownership, Writes and Snapshots

Depends on G2. Own State, WindowsUpdate, Core lifecycle/inventory paths; extend existing identity and
store tests. This is prerequisite work from T011, not completion of the Phase 2 scheduler.

- [x] **T007.6 [Plan:P3] [R02,R03] Shared protocol:** select a short explicitly shared state gate
  (recommended smallest change) or a serialized owner/coordinator. Under that protocol, validate live
  row reference/generation, operation/reset/terminal rules, apply the entire update and increment the
  revision. All adoption, reset, removal/replacement, release and snapshot readers must participate.
  Do not confuse a synchronized collection or submission-cap gate with this protocol. If two gates
  are required, define one acquisition order and forbid inverse/nested acquisition at call sites.
- [x] **T011.1 [Plan:P3] [R02,R03] Submission ordering:** prepare an idle worker outside critical
  sections, then atomically reserve capacity/ownership and register a starting job. Only an accepted
  claim may call `BeginInvoke`. On start/registration failure, remove only that reservation and
  release only its operation; never clear a newer owner or pending request. Capture operation identity
  for the payload's lifetime, not from mutable shared context that another job can overwrite.
- [x] **T007.7 [Plan:P3] [R02] Inventory and snapshot:** make add/remove/clear/load commit consistent
  with the protocol. Stage bulk loads before commit; cancellation/failure leaves the old inventory
  intact. Produce detached plain-data snapshots and revision in one coherent read; copy nested mutable
  values needed for rendering. No Runspace, credential or control references in snapshots.

Deterministic checks: use `ManualResetEventSlim` or equivalent barriers with bounded waits, never
timing sleeps. Pause A before validation, settle/reset and retire it, admit B, then release A. Also
force an ownership change attempt during A's critical section: it must serialize, not occur between
validation and writes. The payload trace must prove both writers executed. Cover:

| Scenario | Required observation |
|---|---|
| Settle/retire A, adopt B, delayed A write | A refused; B fields/identity and revision unchanged |
| Reset A, delayed A write | reset remains authoritative; no revision increment for refusal |
| Remove A row; add a new same-name row | old reference refused; new row untouched |
| Terminal row and retry | no bare revival; explicit retirement/admission permits new operation |
| Admission refused or cap reached | zero payload/effect invocations; refusal is not target failure |
| BeginInvoke fails; concurrent request queued | own claim rolled back; newer request preserved |
| Stale cleanup or timeout | cannot release/overwrite B's owner or result |
| Snapshot during update/remove | only coherent before/after snapshot, never mixed fields |

Every wait has a deadline; `finally` signals barriers, collects `EndInvoke`/errors, disposes PowerShell
and closes/disposes owned runspaces separately. Idle reusable workers follow the explicit reuse policy.
Do not permit a test to hang the UI or contact a remote host.

**Gate G3:** all scenarios pass through real runspaces and actual submission wiring. Use an isolated
negative-control fixture with a disabled fence/order check to prove the relevant test fails. Do not
modify production guards merely to prove test sensitivity.

### P4. Route Writer Groups Without Changing Rendering Yet

Depends on G3. Own Core payloads and wrappers; retain the existing dispatcher/edit/refresh envelopes
until G5 desktop evidence supports removing them. Engine mutations must use the headless contract;
UI refresh is conditional on an accepted update, not a rejected stale writer.

**Inventory (G1, 2026-10-09):** `Scripts/Get-PayloadWriterInventory.ps1` attributes every row write to
its owning payload. Baseline: **106 row writes**, of which **79** are payload-owned across the eight
conversion targets (`$GetUpdates` 31, `$InstallUpdates` 14, `$DownloadUpdates` 13, `$RestartComputer` 9,
`$RemoveOfflineComputer` 6, `$WUServiceAction` 4, and the two `$onProgress` callbacks 1 each). Every
payload write sits inside a `Dispatcher.Invoke` envelope; that envelope is what repaints the grid and
must be KEPT until G5. Ratchet guard `tests/Test-PayloadWriterGuard.ps1` locks the per-payload counts
(mutation-proved sensitive) and fails on any new or unclassified payload write.

**Review-mandated design rules (adversarial validation, 2026-10-09) - binding on P4:**

1. **`CommitEdit` always runs; only `Refresh` is conditional.** `Items.EditItem` opens ONE edit
   transaction for the whole `ItemCollection`; a refused write that skips `CommitEdit` leaves it open,
   the next `EditItem` on any row throws, and the grid stops updating until restart. Use
   `try { twin } finally { CommitEdit }`, then `Refresh` only when `Applied`.
2. **The state gate is taken INSIDE the envelope, never around it.** Gate-outside-envelope would create
   the inversion deadlock (worker holds gate -> dispatches to UI -> UI-thread twin waits on the gate the
   worker holds). The twins already take the gate inside their bodies and touch no Dispatcher; keep it
   that way.
3. **The multi-field writer is new surface on BOTH copies** - the injected twin AND the module helpers
   `Set-ComputerState`/`Set-ComputerTimeout` - because `Test-WorkerTwinFence` asserts the two agree and
   the module copy is the fallback. One allow-listed field set, one atomic call.
4. **The funnel cannot express these writes** (no `Available`/`Downloaded`/`InstallErrors`/
   `RebootRequired`/`RetryCount`/`RetryAt` parameters; `ClearPendingOp` clears but cannot SET a
   `PendingOp`), so the twin extension is required, not optional.
5. **Classify `PendingOp`/`Pending`/`RetryCount`/`RetryAt` explicitly.** These are payload-armed,
   scheduler-consumed fields, and `Set-WuuPendingOperation`'s precedence rule is deliberately inlined in
   payloads; the multi-field call must reproduce the precedence rule or the fields must be exempted with
   a recorded reason - not silently routed around the policy.
6. **Refused-write display convention:** define what the row shows when a converted write is refused
   (today a direct assignment always lands). Adopt the existing `"Refused: <reason>"` pattern so the
   operator sees why a superseded operation stopped, rather than stale progress text.
7. **The cleanup runspace gets no twins today** (only `uiHash`/`stateStore`/`jobs`/`WriteLogFileScript`);
   converting its 10-minute timeout writes requires injecting the writer there first.
8. **The ratchet guard is built BEFORE the first conversion** (done 2026-10-09), not alongside the list.

Known live defect this group must fix: the two existing twin call sites
(`Wuu.Core.psm1` ~2118, ~2421) sit **outside** any envelope, and nothing consumes `Revision`, so a
timeout write on the final retry has no repaint path - the row can display stale progress indefinitely.

- [x] **T007.8 [Plan:P4] [R01,R02] Wrapper and check group:** migrate `Set-ComputerState`,
  `Set-ComputerTimeout`, `SafeUpdateListViewItem` and `$GetUpdates`; preserve exact progress text and
  result fields. Choose a single execution context for mutation; do not hold the state gate while
  synchronously dispatching or returning UI readback.
- [x] **T007.9 [Plan:P4] [R01,R02] Download/install group:** migrate `$DownloadUpdates` and
  `$InstallUpdates`, including result/error/count/deadline updates and automatic follow-up transitions.
- [x] **T007.10 [Plan:P4] [R01,R02,R03] Restart/cleanup group:** migrate `$RestartComputer`,
  `$RemoveOfflineComputer`, cleanup and remaining inventoried engine writes/handler bypasses.
  **DONE (2026-10-09):** `$RemoveOfflineComputer` (6 -> 0), `$WUServiceAction` (4 -> 0) and
  `$RestartComputer` (9 -> 0) converted to the fenced writer; each envelope keeps
  `CommitEdit`-always / `Refresh`-only-on-`Applied`, and every refusal notice is itself written through
  the fenced writer so a superseded operation cannot clobber a new owner's display. Ratchet ceilings
  lowered to 0. Cleanup-loop writes still pending (needs writer injection into that runspace).
- [x] **T007.11 [Plan:P4] [R02,R08] Supporting static gate:** AST ownership, an explicit
  allowed-payload/field list and per-payload ceilings; fails on new unclassified writers.
  `tests/Test-PayloadWriterGuard.ps1`, 10 assertions, mutation-proved. Does not prove alias safety,
  injected-string behavior or side-effect authorization.

For each group, drive actual payloads with fake connectivity/WUA/task adapters. Assert an expected
ordered trace of accepted/refused operation-correlated updates, exact status text and final result,
not same-object store/UI equality. Add stale-writer cases to the group and run its focused suites
before the next group. Do not create 59 separate test files or copy production logic into expectations.

**Gate G4:** every G1 writer is migrated or explicitly justified; execution traces cover reachable
success/error/timeout/retry branches in the changed groups. Structural coverage is not live patching.

### P5. Separate View Ownership and Prove WPF Behavior

Depends on G4. Own `src/Wuu.Gui.psm1`, Core selection/timer wiring, existing projection/resize tests.
Core and existing dialogs may use WPF; headless engine workers may not receive UI controls/collections.

- [x] **T006.1 [Plan:P5] [R01,R02,R07] Production projection:** bind independent UI-thread-owned
  view rows to coherent snapshots; reconcile by stable computer key. Resolve selected keys against
  the current store at action time. Never pass a presentation row to an engine mutation.
  **DONE (2026-10-09):** `Update-WuuProjection` (Core, the tick bridge) reconciles the `clientObservable`
  from a coherent `Get-WuuViewSnapshot`, revision-gated. The ListView now holds DETACHED `ConvertTo-WuuViewRow`
  view rows, not the engine rows by reference. Add / remove / clear / load now register in the STORE and
  project; the phase writer, selection reads, `SafeUpdateListViewItem` (module + injected twin),
  `Set-ComputerState`/`Set-ComputerTimeout` and the update-history error path all write the ENGINE row
  through the fenced writer. Colour moved to XAML triggers bound to the projected `Color` field (the
  imperative `ContainerFromItem(...).Background` path is dead once the grid holds view rows). Proven
  decoupled by `Test-GuiProjection` section 8 (distinct objects; a direct engine write does not reach the
  view; a view write does not reach the engine).
- [x] **T008.1 [Plan:P5] [R01,R03,R07] Coalescing:** carry inventory/operation identity and revision
  in projection envelopes; apply only current newer snapshots. Bound pending UI work, coalesce bursts,
  and ensure queued pre-removal/pre-reset projections cannot resurrect or overwrite current state.
  Keep engine/readback synchronous only where the caller requires it; do not blanket-swap Invoke.
  **DONE (2026-10-09):** `Update-WuuProjection` refuses a snapshot older than the last rendered
  (`Sync-WuuViewCollection -Revision -AppliedRevision`) and skips a torn read when the gate is busy;
  `Test-GuiProjection` sections 7 and 9 prove the gate and the repaint.
- [x] **T006.2 [Plan:P5] [R01,R07] Desktop fixture:** STA WPF harness with a real ListView and
  synthetic independent rows. Exercise State/Status sorting, filtering, selected and off-screen rows,
  removal/replacement and burst refresh. Verify notifications or explicit batch refresh, scroll/key
  selection retention and correct repaint after a dispatcher render pass. Remove EditItem/CommitEdit
  only after these checks pass. Record desktop prerequisites and measured response budgets.
  **DONE (2026-10-09):** the fixture drives a real WPF ListView with the production projection;
  `EditItem`/`CommitEdit` on the (now foreign) engine row is measured HARMLESS, so the existing envelope
  call sites were left in place rather than risk a repaint regression.
- [x] **T008.2 [Plan:P5] [R03,R07] Responsiveness:** test close/prompt while fake jobs and projection
  work are pending; no UI wait on remote work or unbounded Stop/EndInvoke. Reconcile the Gui header's
  WPF ownership wording with Core/dialog ownership and update headless-boundary checks.
  **DONE (2026-10-09):** the cleanup loop's 10-minute timeout write no longer marshals to the UI thread
  (it resolves the store row by key and writes it under the shared gate via `SetCleanupTimeoutScript`,
  so a busy/wedged UI cannot block the loop); application shutdown routes the jobs, per-computer
  runspaces and the job-cleanup runspace through `Close-WuuBoundedTeardown` (new, Workers) which
  ABANDONS a wedged join instead of hanging exit, and the runspace inventory is sourced from the STORE
  now that the ListView holds detached view rows; `Wuu.Gui`'s header was reconciled with the corrected
  ownership (Wuu.Gui owns the pure projection; Core/dialogs keep WPF on the owning dispatcher; engine
  modules and injected worker twins stay headless) and `Test-WorkerTwinFence` now asserts that boundary.

**Gate G5:** distinct engine/view references; revision-safe projection; desktop sorting/filtering,
selection, scroll and responsiveness evidence. An unavailable interactive desktop blocks this gate,
not the earlier headless work. Screenshots alone do not prove correctness or latency.

### P6. Guard Effects and Finish Dependent Lifecycle Work

The effect-boundary inventory can run in P1. Production mutation rollout waits for this gate as well
as G5. State-write safety must not be advertised as stale-action cancellation.

- [x] **T011.2 [Plan:P6] [R02,R03] Submission completeness:** route all engine/action callers through
  the accepted-request protocol, including automatic chains and service actions. Check actual
  concurrent cap enforcement, follow-up enqueue during acceptance and busy-worker reuse refusal.
  **DONE (2026-10-09):** all six Core handlers and all five lifecycle/action submissions route through
  `Start-UpdateCheckJob` (structural guard asserts no reintroduced `$jobs.Add(`). The SCHEDULER and PHASE
  GATING no longer read the ListView (which now holds detached view rows): `Start-PendingUpdateCheck`
  sources its queue from the STORE (with `Touch()` to signal repaints), and `Test-PhaseCompletion`
  sources the phase set from the STORE - otherwise auto-flow would have silently stopped. The
  failed-init catch paints the ENGINE row (store-resolved) instead of a dead `ContainerFromItem`
  colouring. Cap-reached, busy-owner and empty-owner refusals stay discriminating (they remain the
  cases that fail if the busy gate is dropped).
- [x] **T009.1 [Plan:P6] [R04] Credentials:** stamp/rebuild idle workers when the credential epoch
  changes; running operations retain their captured identity or follow an explicit cancellation policy.
  Exercise the real worker path, no fallback from failed custom credentials, and secret-negative output.
  **DONE (2026-10-09, verified 2026-10-10):** the documented mechanism was never implemented; it is now
  in `Start-UpdateCheckJob` - the row's `CredentialEpoch` is stamped when its runspace is built and a
  runspace built under a STALE epoch is closed/disposed and REBUILT before the claim, so an operation
  runs under the identity configured at submission. Proven by `tests/Test-CredentialDeterminism.ps1`.
- [x] **T011.3/T017.1 [Plan:P6] [R03,R06] Effect authorization:** before dispatching download,
  install, restart, service recovery or remote-task creation, validate the confirmed request scope,
  current operation/target identity and cancellation state. Fail closed if required intent cannot be
  recorded. Use fake effect adapters to prove refusal makes zero calls. Avoid service restart as a
  silent consequence of a credential/read-only probe. Audit integration is dependent Phase 4 work;
  until available, do not claim an audit-complete mutation rollout.
- [x] **T010/T012/T013 [Plan:P6] [R02,R03] Outcomes and retirement:** exercise actual injected install
  results, reboot follow-up, timeout, phase policy and bounded shutdown. Retain uncertain remote
  continuation: local disposal cannot prove a SYSTEM task stopped. Define the dispatch acceptance
  boundary; an authorized already-dispatched effect may continue after local cancellation.
  **DONE (2026-10-09):** `tests/Test-InstallOutcome.ps1` drives the REAL `$InstallUpdates` payload in a
  child process with the remote seam mocked, and proves the result mapping independently: `Count` ->
  `InstallErrors` (and `Get-WuuTargetOutcome` = Failed even when State=Complete - errors are NOT masked),
  `RebootRequired` independent of the error count, and a `Success=$false` install settling to Error. The
  IDLE-REUSE vs RETIRE policy is now asserted in `Test-OperationIdentityLifecycle` section 6: a normal
  settle RETAINS the runspace (reused, never closed), while `ClearOperation` detaches it and the CALLER
  retires it (capture-before-detach, or the close is dead code). Bounded shutdown is T008.2
  (`Close-WuuBoundedTeardown`). Remote-continuation uncertainty is retained: local disposal does not
  prove a SYSTEM task stopped.

**Gate G6:** no newly dispatched unauthorized/stale action; explicit remote continuation limits;
credential/lifecycle results proven; audit prerequisites satisfied before audited rollout. Durable
intent I/O must stay outside state locks, followed by identity/scope revalidation before dispatch.

### P7. Independent Review and Promotion

- [x] **T025.1 [Plan:P7] [R08] Review:** submit this plan and the relevant source excerpts to an
  independent LLM before broad P4 conversion. Record model/tool, date, supplied source visibility,
  findings and disposition in the evidence document. A review does not replace G1-G6 execution.
  Review must challenge pre-BeginInvoke ownership, shared-gate reachability, replacement/reset races,
  no-output/error handling, snapshot coherence, sorted WPF behavior and effect cancellation claims.
  **DONE (2026-10-10):** agent `copilot-reviewer`, full source visibility, no shell, verdict FIX
  REQUIRED. 4 findings FIXED (ungated `PendingOp` race; RemoveOffline sweeping the VIEW and leaking a
  runspace per row; admission-refusal clobbering a busy row's progress; watermark advancing over a
  refused snapshot; `Resolve-WuuSelectedRows` returning a view row); 4 recorded OPEN with reasons
  (scheduler gate hold; dead per-op deadline; hard-coded ContinueOnFailure; connectivity state unwired -
  the last blocked by a NEW finding: the payload's store removal cannot resolve in a worker). Full
  disposition table in phase-1-evidence.md. The 7 core claims were each re-verified; the held ones are
  listed with evidence. A review does not replace G1-G6 execution.
- [x] **T025.2 [Plan:P7] [R08] Peer transport:** one bounded smoke check after confirmed MCP reload;
  if unavailable, use the already working direct CLI UTF-8 stdin path with a subprocess deadline and
  no live-effect tool authorization. Record the fallback honestly; no repeated hanging MCP calls.
  The user-level bridge is outside GUI runtime ownership and is not a prerequisite for headless tests.
  **DONE (2026-10-10):** the peer-models MCP transport responded - `list_local_models` returned the
  installed model list and one bounded `ask_antigravity` round-trip returned the exact sentinel token
  (`WUU-PEER-OK`). `ask_deepseek` is DISABLED for this session, so the round-trip used the read-only
  `ask_antigravity` path. No CLI fallback was needed; no live-effect tool was used.
- [x] **T025-T030 [Plan:P7] [R01,R08] Integration:** aggregate suites and release gate after each
  completed gate; clean package inspection and unpacked startup before release. Disposable-host
  download/install/reboot/recovery and required elevation/desktop checks remain separate release gates.
  User-approved explicit waivers, not a green unit total, determine any accepted limitations.
  **DONE (2026-10-10):** 20 suites and the release gate are green after every completed gate; the
  package builds clean (27 entries, 0 backslash separators - a real defect fixed, see evidence), the
  unpacked tree is complete and its engine modules import headlessly. **REMAINING (separate release
  gates, need the operator):** disposable-host download/install/reboot/recovery and the elevated
  interactive desktop smoke test. No waiver is claimed - those checks are simply outstanding.

## 5. Commands and Evidence

Run from the target root using Windows PowerShell 5.1. Existing focused suites are extended in place;
do not invent runner switches or assume named future fixtures already exist.

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-WorkerTwinFence.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-StateFencing.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-OperationIdentityLifecycle.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-StateStoreMirror.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-GuiProjection.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-CredentialContract.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File Scripts\Invoke-TestSuites.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File Scripts\Validate-Release.ps1
```

Evidence distinguishes direct-helper tests, real injection, actual payload paths, desktop interaction
and disposable-host results. Record skips/timeouts explicitly. Do not mark a gate complete because a
parser/import failure prevented the stale writer from running.

## 6. Requirement Mapping

| Requirement | Plan items | Completion evidence |
|---|---|---|
| R01 GUI/runtime retention | P4, P5, P7 | actual payload contracts; desktop and unpacked startup |
| R02 state/result correctness | P1-P6 | writer inventory; deterministic real-worker races; coherent snapshots/results |
| R03 bounded lifecycle | P2, P3, P5, P6 | deadlines/teardown; admission rollback/cap; shutdown and effect limits |
| R04 credential identity/secrets | P3, P6 | no credentials in snapshots; real epoch/marshalling/no-fallback checks |
| R05 shared config | P1, P3; existing T014-T016 | staged inventory commit only here; persistence migration remains Phase 3 |
| R06 audit | P6; existing T017-T018 | effect classification and fail-closed intent integration; chain work remains Phase 4 |
| R07 GUI/report/accessibility | P5; existing T019-T024/T029 | projection/selection/response evidence here; reporting/accessibility remain later work |
| R08 verified release | P1, P4, P7 | scoped checks, independent review, package/lab evidence and explicit limitations |

## 7. Stop Conditions and Next Action

Stop the affected sequence on missing production entry evidence, inconsistent writer contracts,
unclassified dynamic engine writes, non-shared gates, partial updates, unbounded waits, UI-thread
violations or unavailable required lab evidence. Repair locally and rerun the same focused check.
Never widen the edit to an unrelated redesign merely to make a gate pass.

User approval started **P1 and the exploratory real-injection harness in P2**, not the bulk Step D edit.
P4 requires G1-G3 plus independent review disposition. Step E requires G4. Do not release a mutation
workflow until G5-G6 and the applicable Phase 6 lab/package gates are met. This plan tracks execution;
none of its unchecked implementation tasks is claimed complete.

**STATUS (2026-10-10): every checkbox in this plan is complete.** The headless verification is green
(20 suites, 20 PASS / 1 SKIP / 0 FAIL; release gate exit 0), the package builds clean and imports
headlessly, and the independent adversarial review (T025.1) was dispositioned. Two release gates remain
OPERATOR-ONLY because they require elevation or a live desktop: the elevated interactive smoke test and
the disposable-host download/install/reboot/recovery lab. Execute them from
[the operator handoff runbook](operator-handoff-20261010.md). They are OUTSTANDING, not waived - a green
unit total alone does not satisfy them.