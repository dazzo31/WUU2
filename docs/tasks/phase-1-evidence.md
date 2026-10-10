# Phase 1 Remediation Evidence

Date: 2026-10-08. Status: initial remediation implemented; **G1-G6 are not certified**.
User authorized proceeding with the remediation plan. Broad Step D/E conversion has not begun.

## Scope and Provenance

Requirements: R01, R02, R03, R08. Existing tasks: T003, T006-T008; lifecycle follow-up T011-T013.
Target HEAD: `f1d5f97465d2301b331ded8655ee8e1b745e779e`.
Donor HEAD: `e81b620905d549783d7e17498a0b3cbbcf5f4095` (`v1.5.0-rc.4-cli`).
Target was already heavily dirty/staged. Donor status before this work was one modified document,
`docs/DEFECTS_AND_COVERAGE_20261006.md`; no donor files were edited in this remediation.
No commit, branch, tag, package release, real inventory mutation or live remote action was performed.

Runtime: Windows PowerShell `5.1.26100.9444`, STA; non-elevated test child processes.
Baseline source hashes and target dirty paths are captured in
[remediation-inventory-20261008.json](remediation-inventory-20261008.json). This capture predates the
runtime repairs below; it is not a hash manifest of the final working tree.

Read-only donor SHA-256 provenance:

| Donor file | SHA-256 |
|---|---|
| src/Wuu.State.psm1 | 3461D80A1EF5600D9A2D3D84AFE4E08A67F7BBD6032DA4A8A2B5A85BC6CB6DF1 |
| src/Wuu.Configuration.psm1 | BE44DFD751A9189142FC3F24A66B7BD4056A40716E4E4BBFB5552F61E1D488B2 |
| src/Wuu.WindowsUpdate.psm1 | 842AA08CD5B4F497C230B13991F5FD83EB17E9A83866051015BEF944534E4149 |
| src/Wuu.Workers.psm1 | 086FF3E5ECBCB579E61AE0AC10447EECE8257EDFF1E794A9A08EC733850A03E1 |
| src/Wuu.Remote.psm1 | FE17CBD187EE996B16729A1C6041187B97DB86B4B4B1CE1181DA874F74BF41F0 |
| src/Wuu.Credentials.psm1 | 45177ED248B2491AF9F1A1D362E7C28CCEC59CD85CC0DC8CC083254A6C1FBC24 |
| Scripts/Download-Patches.ps1 | F0723410A751D73E2403870267A183F2DCA0647FA5090B5097B5E9F8CF248B42 |
| Scripts/Install-Patches.ps1 | 8C8B5D4BB195CCFB044EC1BD09B3ED8B26495F5A4836A6A88F25145348A3A2C7 |

## Baseline and Post-change Checks

From the target root, using `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File`:

| Check | Before | After |
|---|---|---|
| Scripts/Invoke-TestSuites.ps1 | 18 suites: 17 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT | same totals, exit 0 |
| Scripts/Validate-Release.ps1 | all emitted checks PASS, exit 0 | all emitted checks PASS, exit 0 |
| tests/Test-WorkerTwinFence.ps1 | 37 assertions, prior historical evidence | 89 PASS / 0 FAIL, exit 0 |
| tests/Test-StateStoreMirror.ps1 | 33 assertions, prior historical evidence | 37 PASS / 0 FAIL, exit 0 |

Aggregate machine-readable results:
[baseline](remediation-baseline-suites-20261008.json) and
[post-change](remediation-post-suites-20261008.json). The runner captures suite verdicts, not assertion
totals; the focused totals above came from direct suite output. The sole skip is `Test-RemoteTask`,
which requires elevation to register a SYSTEM task. It is not counted as remote coverage.
Touched scripts/modules have no reported editor diagnostics.

The final source compatibility check found both extended tests had existing non-ASCII comments
without a UTF-8 BOM. Added BOMs without changing their text. All five touched PowerShell files then
passed encoding and parser checks; both affected suites passed again under the bounded PS5.1 STA
runner (2 PASS / 0 FAIL / 0 SKIP / 0 TIMEOUT). The aggregate artifact above predates only these
encoding-only changes.

## AST Inventory and Boundary Review

[Scripts/Get-RemediationInventory.ps1](../../Scripts/Get-RemediationInventory.ps1) parses all current
source modules under PS5.1 and records full ancestor ownership, source extents and hashes. The initial
capture contains 935 syntactic candidates: 440 member assignments, 22 indexed assignments,
16 increments, 85 property-bag/context assignments, 150 member invocation boundaries and
222 command boundaries. These include presentation and unrelated local values, not 935 engine writes.
Records remain `NeedsReview`; no alias/data-flow completeness is claimed.

| Owner/path | Reviewed disposition | Remaining work |
|---|---|---|
| Core `$AddEntry`, direct/dispatched add | row construction, backfill, store mirroring | shared inventory protocol |
| Core `$removeEntry` and `$clearComputerList` | removal plus job/resource cleanup | serialize retirement/removal; bound cleanup |
| Core `$ClearComputerList` case-only alias | overwrote real block and self-recursed | removed; regression passes |
| Core `$RemoveOfflineComputer` | worker removal of UI row and mirror | G3 inventory ownership and G4 routing |
| Core `$eventLoadConfig` | clears UI collection and later adds rows to store | no whole-store replacement at clear; staged atomic replacement remains open |
| Core `$GetUpdates` nested WUA search/reboot pipelines | auxiliary in-process operations, not fleet admission | preserve COM and bounded retirement |
| Core background job cleanup | lifecycle owner with direct row writes | serialized identity-safe release and bounded drain |
| Core `$eventGetUpdates` | first start uses Start-UpdateCheckJob; reused workers submit directly | admission bypass remains open |
| Core download/install/remove-offline/restart/service handlers | direct BeginInvoke plus jobs.Add | all six direct engine submission paths need unified admission |
| Core window-init and Credentials dispatcher BeginInvoke | presentation callbacks | not engine admission; retain dispatcher ownership |
| WindowsUpdate Start-UpdateCheckJob / Start-PendingUpdateCheck | managed submission / queued caller | currently BeginInvoke precedes stamp; refusal can leave payload running |
| Workers Invoke-WithPoolTimeout | auxiliary bounded probe pool | not fleet admission; pool shutdown remains unbounded |

Dynamic member writes were reviewed explicitly:

- Core `SafeUpdateListViewItem`: `$actualItem.$propertyName` writes a live UI/engine shared row;
  route its property bag through the eventual headless contract (G4), not an approved exception.
- WindowsUpdate `SafeUpdateListViewItemScript`: same dynamic row writer in injected UI callback;
  remains an unfenced bypass (G4). Factory workers still receive UI dependencies; not headless certified.
- State `Update-WuuOperationState` local `$set`: the funnel's dynamic field writer; include in the
  shared mutation/snapshot protocol (G3), not a caller bypass.
- Gui `Sync-WuuViewCollection`: presentation object reconciliation; prove production rows are detached
  before treating this as view-only (G5).

Ancillary `updatesHash`/`performanceHash` indexed writers in `$GetUpdates` are also operation-related.
They are not made safe by fencing State/Status; classify their stale-result ownership during G3/G4.
String-created scriptblocks, aliases and all ancillary fields still require complete disposition.
**G1 remains open** until that review is complete; a generated candidate count is not its gate.

## Executed Repairs and Discriminating Evidence

### Admission Before Ownership (D14)

**Defect.** `Start-UpdateCheckJob` created the job entry with `BeginInvoke()` **before** the row was
claimed, and a refused claim was only logged ("the job still runs"). Consequences read from the old
source: a submission against an already-running computer started a **second payload** on the same
runspace - the engine silently discards concurrent work but `BeginInvoke` is accepted - and that
payload's writes carried no identity, so the fence permitted them. The global cap was also tested at a
different moment from the one at which capacity was consumed, so it could overshoot.

**Fix.** Admission now precedes the start, inside the existing `Enter-WuuSubmissionLock` section:
re-test `Test-WuuComputerBusy`, re-test `Test-WuuConcurrencyAvailable`, claim the row through the
funnel, and only then `BeginInvoke`; the complete job entry is appended to `$jobs` inside the same
section. A start failure rolls the claim back with a `SubmissionFailure` reset and refuses. The
section holds no I/O, dispatcher wait or remote call. `$MaxConcurrentJobs` resolves from the context
with a global fallback so it cannot be silently `$null` (which `Test-WuuConcurrencyAvailable` refuses
by design).

**Evidence** (`tests/Test-AutoFlowChain.ps1`, bounded PS5.1 STA; a marker file proves work did or did
not start, which a return value alone cannot):

| Case | Assertion |
|---|---|
| Busy computer (`OpState='Running'`, live owner) | refused, **zero** payload marker lines, job count unchanged, owner untouched |
| Cap reached (one placeholder entry with cap 1) | refused, zero marker lines, no job appended, row not left `Running` |
| Queued follow-up only (`Pending=$true`, `OpState='Idle'`, no identity) | refused; the discriminating case, because the identity funnel alone would **accept** this claim |
| `OpState='Running'` with **empty** `OperationId` | refused; the gate is load-bearing here because the funnel's adoption rule would otherwise accept and overwrite the busy row |
| Scheduler re-arm | a queued request refused by the tick is put back (`Pending`/`PendingOp` restored), so the auto-install tail is not silently lost |
| Refusal record | a refusal is recorded (`RefusedCount`/`RefusedReason`) and cleared on admission, so a permanently refused row is visible rather than an invisible stall |
| Gate halves | `Test-WuuComputerBusy -Row` is busy while `-IgnorePending` is not, proving the `Pending` half does the blocking |

The busy-with-owner and cap assertions hold even with the busy-gate line removed, because the funnel
claim also refuses a `Running` row that names an owner - so those two alone would **not** catch a
regression of the gate. The queued-follow-up case and the **empty-owner** busy case are the ones that
fail if the gate is dropped, which is why they exist. The plan's rule against mutating production
guards for sensitivity proof was followed (an attempted temporary probe was reverted), so their
discriminating power is argued from the contract rather than demonstrated by mutation.

**Independent review of this change** (agent `copilot-reviewer`, 2026-10-08) found the ordering correct
and the lock section free of I/O, and raised one critical: the scheduler cleared `Pending`/`PendingOp`
**before** submitting and discarded the refusal, so a refused queued request (e.g. the auto-install tail
that queues while the download is still `Running`) was lost. Fixed by re-arming on refusal and by
calling the previously-unused `Update-WuuRefusalRecord`/`-Admitted`. Its other notes were addressed
(cap fallback mirrored in the scheduler; rollback now passes `-OperationId`). Remaining accepted notes:
`Test-WuuComputerBusy` treats `OpState='Queued'` as busy although nothing assigns it (unreachable
branch), and the rollback branch is not reached by any test.

**Still open:** the validation/mutation step is still not atomic against row replacement; the
shared-protocol work (T007.6) remains required. Action authorization at the effect boundary (G6) is
also still outstanding - a claimed operation can still download/install/restart.

### Direct Handler Conversion (D14 follow-up)

**Defect.** Six Core handlers composed their own `BeginInvoke` and `$jobs.Add(...)` with no claim and no
admission check, so they bypassed the D14 ordering entirely: `$eventGetUpdates` (reused-worker path),
`$eventDownloadUpdates`, `$eventInstallUpdates`, `$eventRemoveOfflineComputer`, `$eventRestartComputer`,
`$eventWUServiceAction`. A submission here started a payload with no operation identity - every write it
made was "unattributed" and therefore permitted by the fence - and it ignored the per-computer and global
gates.

**Fix.** `Start-UpdateCheckJob` gained a `-Payload` path: an ordered array of
`@{ Script = <scriptblock>; Arguments = @(...) }` composed exactly like the built-in chains, plus three
lifecycle op names (`Restart`, `RemoveOffline`, `ServiceAction`) in its `ValidateSet`. A lifecycle op with
no payload is refused rather than silently running a plain Check under that op's deadline. All six
handlers now route through `Start-UpdateCheckJob`, reproducing their previous pipelines byte-for-byte:
download -> `-Op Download`; install -> `-Op InstallAndRecheck` (the built-in install/restart/recheck
chain); check/reuse -> `-Op Check`; remove-offline -> `-Payload @(@{ Script = $RemoveOfflineComputer; ... })`;
restart -> two-step restart-then-recheck payload; service action -> service-action payload. Core no
longer appends a job entry anywhere.

**Evidence** (`tests/Test-AutoFlowChain.ps1`): an explicit-payload lifecycle op (op `Restart`) is
admitted, claimed and executed with the row's identity, and a payload-less lifecycle op is refused. A
structural guard fails if Core reintroduces `$jobs.Add(` or if any one of the six op names stops
routing. `grep` confirms the only remaining `BeginInvoke` calls in Core are the in-payload nested
pipelines (WUA search/reboot, inside `$GetUpdates`) and the separate cleanup loop - not job submissions.

**Finding during this work:** the first version of the lifecycle wait used `.IsCompleted` on the
Runspace object (a Runspace has no such property), so the suite spun its full 15 s timeout and reported
`Test-AutoFlowChain` at 18.6 s. Corrected to wait on the job's async handle; the suite returned to ~3.5 s.
Recorded because a silent full-timeout wait in a green test is exactly the kind of cost that hides.

**Independent review of this conversion** (agent `copilot-reviewer`, 2026-10-08) confirmed all six
handlers route and the only remaining `$jobs.Add(` in `src/` is the funnel's own, and raised:

| Finding | Disposition |
|---|---|
| Payload-less lifecycle guard threw inside the acquisition `try`, so the runspace-failure handler painted the row `Error`/`Failed to initialize` and abandoned a runspace | fixed: validation moved **before** `try`; returns `$false`; test now asserts no row corruption (not an exception) |
| `-Payload` step assumed `ContainsKey`, throwing on a plain object/`[pscustomobject]` step into the same misleading path | fixed: dictionary **or** property-bag handling |
| A refusal only reached `Write-InfoLog`, invisible with `EnableDebugLogging=$false`, so a one-shot menu action looked like a no-op | fixed: refusal sets the row `Status`, and remove-offline/restart emit an aggregate `Update-StatusBackground` summary |
| `-Payload` overrides `-Op` for all ops, so a payload could run under an unrelated op's deadline | **accepted, documented**: op↔pipeline pairing is unconstrained; every current caller pairs them correctly, and the alternative (per-op payload validation) added a second source of truth. Left as a known limitation, not silently |
| Structural guard was case-sensitive/line-sensitive | fixed: case-insensitive, whitespace-tolerant regex; noted that a determined alias still evades a text guard, which is why behavioural cases exist |

Its remaining notes are recorded as accepted: the remove-offline sweep is intentionally all-rows (a busy
row is not an offline row, and the refusal is now visible); the download path now passes `'Download'`
as the payload's second argument (inert - it only gates `$alreadyAutoFlow`); and the restart payload's
`$false` (manual, not auto-install) is now commented.

**Verified after these fixes:** 18 suites, 17 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0;
all three modified files PS5.1-safe; no direct `$jobs.Add(` in Core.

### Atomic State Protocol (D12 follow-up / G3)

**Defect.** The funnel validated a row (identity, reset, terminal, live-row reference) and *then*
wrote its fields as separate steps. A worker twin or another writer could interleave between the check
and the write - the classic check/write race - so "the row is still ours" was not a true precondition of
the mutation. It was also opt-in: the gate was consulted only when a caller passed `-Store`, which most
`Wuu.Core` handlers do not.

**Fix.** A shared **state-mutation gate** now lives on the store object (`$store.Gate`), so it is the
same reference in the main session and every worker runspace. It is deliberately **not** the submission
lock: that serialises capacity reservation and is held around admission; this one serialises row state
and is held only for the validate-mutate-publish window. `Update-WuuOperationState` takes it around
validation, every field write and the revision bump; the two injected worker twins take the same gate;
and `Add-WuuComputerRow`/`Remove-WuuComputerRow` take it around their two-step mutation. It is
**re-entrant** (Monitor), **bounded** (10 s default, `-StateGateTimeoutMs`), and **fail-closed** - if the
gate cannot be taken the write is refused, never run unlocked. A runspace close is captured under the
gate but performed **after** release, because `Close()` can block. The store is resolved from the
`-Store` parameter or `$global:stateStore`, so existing handlers get atomicity without being changed.

**Evidence** (`tests/Test-StateFencing.ps1`, 37 assertions): a real worker runspace takes the **same**
store gate (`ReferenceEquals`), the main-session funnel is **refused** while it holds it (short gate
timeout) and the row is unchanged, the gate is released, and the owning writer is then accepted. Also
asserted: an explicit `-Store` write reaches the same gate, and the funnel works without a store (a pure
test row).

**Limitations recorded, not claimed closed:** the atomic window covers *state* writes, not the *effect*
boundary - a claimed operation can still dispatch a remote download/install/restart (G6). Worker twins
still duplicate the funnel rule (agreement is tested, not proven identical for every parameter). The
projection/snapshot coherence and whole-store config replacement remain open (G5 / T007.7).

**Independent review of this change** (agent `copilot-reviewer`, 2026-10-08) confirmed no lock-ordering
deadlock (submission-lock -> state-gate is the only nesting, and the state gate is released before any
runspace close), re-entrancy correctness and bounded twin TryEnter, but found two criticals:

| Finding | Disposition |
|---|---|
| The cleanup **release** blocks (job completion and the 10-min timeout) cleared `OpState`/`OperationId`/… and `Touch()`-ed with **no gate**, so a worker twin could interleave between its validation and its write - release is a producer of the same protected fields | fixed: both release blocks take the shared store gate (`TryEnter`, 5 s, skip-and-retry rather than block) |
| The **funnel** never checked that the row was still the store's row, so a removed/same-name-replaced row was written with `Applied=$true` while the twin refused it - a real copy divergence the agreement test did not cover | fixed: the funnel now refuses an orphan row under the same gate; the twin harness points `$global:stateStore` at its fixture (as production has one global store) |

Its other notes, dispositioned: the refusal `Reason` should be machine-readable `StateGateBusy` (accepted
as a follow-up - the current text is human-only); the section-3 test's 400 ms settle is a timing
assumption (accepted, bounded, and the run is stable across repeats); the comment about `$detachedRunspace`
covers only the reset path, not `ClearOperation` (the invariant holds either way because `ClearOperation`
never detaches a live runspace - comment to be tightened).

**Verified after these fixes:** 18 suites, 17 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0;
`Test-StateFencing` 41 assertions, `Test-WorkerTwinFence` 89; all modified files PS5.1-safe.

### Atomic Whole-Inventory Replacement (T007.7)

**Defect.** Loading a config cleared `$uiHash.clientObservable` and then added rows **one at a time**,
each in its own dispatcher tick, backfilling and `Add-WuuComputerRow`-ing per row. A load was therefore
not a transaction: a reader could observe a **half-loaded fleet**, a failure part-way left the
inventory truncated, and N rows cost N UI ticks.

**Fix.** `Set-WuuComputerRows -Store -Rows` builds new `Rows`/`ByName` indexes and publishes them by a
**single reference assignment** under the shared state gate, bumping `Revision` **once** - so a reader
that does not take the gate still sees either the old fleet or the new one, never a partial one. The
load path now **stages** every row first (backfilled, no UI/store), commits the store once, then
replaces the view in **one** dispatcher tick with the same row objects. An empty `-Rows` is the
clear-list path.

**Evidence** (`tests/Test-StateStoreMirror.ps1` section 9): full replacement, lookup replaced with it, no
old row survives, the store holds the **same** new row objects, exactly **one** revision bump, dropped
rows absent from both collections, empty replacement empties both. Wiring assertions updated (the two
single-computer add sites still mirror; the bulk load uses `Set-WuuComputerRows`).

**Verified:** 18 suites, 17 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0; sources PS5.1-safe.

**Independent review of this change** (agent `copilot-reviewer`, 2026-10-08) confirmed the build-then-swap
is a single-reference publish and that the funnel's orphan check uses the new lookup correctly, but
rejected the end-to-end claim and found three real issues, all fixed:

| Finding | Disposition |
|---|---|
| The store commit and the view commit were **two transactions with no shared error path** (`$eventLoadConfig` has no `catch`), so a failing dispatcher tick left the store on the NEW fleet while the view showed the OLD one | fixed: the store commit is rolled back if the view commit throws, then the error is re-raised |
| A row that failed **staging** was logged and skipped, so the commit silently **dropped** that computer (and its live runspace/operation state) | fixed: any staging failure **aborts** the whole load and leaves the fleet unchanged |
| Rows dropped by the replacement had their **runspaces leaked** (unreachable from both collections, so never closed) | fixed: outgoing rows' runspaces are closed/disposed, skipping any computer a live job still owns |

Its remaining minor notes: the cross-property window between `$Store.Rows` and `$Store.ByName`
(theoretical only - no production reader observes both), `Get-WuuComputerRow` is not a coherent
snapshot (no production caller), the revision bumps even on a no-op replacement, and per-row view-add
error reporting was dropped by design. Accepted and recorded.

**Verified after these fixes:** 18 suites, 17 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0;
`Test-StateStoreMirror` 49 assertions.

### Bounded Worker-Pool Teardown (D15)

**Defect.** `Close-WuuWorkerPool` called `RunspacePool.Close()`/`Dispose()` **synchronously**. A pooled
pipeline wedged in an uninterruptible native call (the abandoned-wrapper case in
`Invoke-WithPoolTimeout`) never returns, so teardown could hang the caller for ever.

**Fix.** The close runs in a dedicated helper runspace so the deadline is observable; on timeout the
helper is **abandoned** (same pattern as `Invoke-WithPoolTimeout`) rather than disposed (disposing a
stuck `PowerShell` calls `Stop()` synchronously - the very block being avoided). Returns `$true` when
closed, `$false` when abandoned; the pool reference is cleared either way so `Get-WuuWorkerPool`
re-opens lazily.

**Why not `Task.Run` of a scriptblock:** a PowerShell scriptblock on a bare thread-pool thread has no
runspace and fails with *"There is no Runspace available to run scripts in this thread"*; and a compiled
`Add-Type` helper proved unreliable here (the type did not register from module scope), so the helper
runspace is the mechanism that works under PS 5.1.

**Evidence** (`tests/Test-WorkerPool.ps1`): the close returns `$true` promptly within its deadline, a
second close is a safe no-op, the pool **re-opens lazily**, and a probe still runs afterwards.

**Not a live caller:** `Close-WuuWorkerPool` has no application call site (only tests). This change is
groundwork for the T012/T013 shutdown work; no production shutdown guarantee is claimed yet.

**Verified:** 18 suites, 17 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0; sources PS5.1-safe.

### Effect-Boundary Authorization (D16 / G6)

**Defect.** The state fence stops a superseded payload from **writing the row**, but the payload keeps
**running** for minutes - so it could still download, install and reboot. The fence made a stale payload
silent, not safe.

**Fix.** A new worker helper `TestEffectAuthorizedScript` (injected beside the twins) returns
`@{Authorized;Reason}` and **fails closed**: it refuses when the writer is unattributed, the row is owned
by a different operation, the operation was reset, or the row was removed/replaced. Each real effect site
- download, install, restart, and the Windows Update service action - now calls it and **throws before
dispatch** when not authorized. Note the deliberate asymmetry: an unattributed **state write** is
permitted (row population); an unattributed **effect** is refused.

**Evidence** (`tests/Test-WorkerTwinFence.ps1` section 7, extracted from the live injection site): owning
writer authorized; superseded writer refused (`StaleOperation`); unattributed refused; reset refused;
removed row refused; and bounded-window assertions place the guard before each of the four effects.

**Honest residual:** this guards the **dispatch** of an effect, not an effect already in flight - a
sustained remote download/install that is superseded mid-call cannot be revoked from here. Already-
dispatched SYSTEM tasks may continue; the guard's guarantee is "no *new* effect is dispatched by a
superseded writer".

**Independent review of this change** (agent `copilot-reviewer`, 2026-10-08) confirmed the helper is
correctly injected and fail-closed, and that every current call site has a claimed row (so the
unattributed-effect refusal cannot wrongly refuse a legitimate effect). It found three criticals, fixed:

| Finding | Disposition |
|---|---|
| A refusal `throw` fell into each payload's shared `Catch`, which painted `State`/`UpdatesStatus`='Error', armed a **stale auto-retry** and aborted the chain - the opposite of the helper's documented "clean refusal" | fixed: all four guard blocks now **report and `return`** instead of throwing; a drift assertion forbids "refused before dispatch" text |
| The service-action catch never set `UpdatesStatus`/`State`, so a refused service action looked still-working to phase accounting | resolved by the same change (the refusal no longer enters that catch at all) |
| Real remote effects in `$GetUpdates` were **unguarded**: the pre-flight wuauserv check/start and `Invoke-AutoRecovery` (which restarts remote services) | fixed: all three now call the same guard and return cleanly when refused |

Its remaining minor notes: the helper's `-OperationId` parameter is unused (all call sites use the
runspace id - harmless); the wiring assertions are source-order drift guards, not proof the guard ran;
and there is still no "refusal ⇒ zero remote calls" fake-effect test or per-injection negative control.

**Verified after these fixes:** 18 suites, 17 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0;
`Test-WorkerTwinFence` 108 assertions; sources PS5.1-safe.

### Shutdown Wires the Pool Teardown (D15 follow-up)

**Defect.** `Close-WuuWorkerPool` had **no application call site**, so the lazily-created shared worker
pool was never closed by the app and leaked its runspaces.

**Fix.** Both shutdown paths now tear it down with the bounded close: `$eventWindowClose` (UI-thread
`Add_Closed`, 5 s) and the tail `finally` cleanup (10 s), the latter warning if the teardown times out.
Idempotent, so the two paths cannot double-close incorrectly, and `Get-WuuWorkerPool` still re-opens
lazily if something needs the pool afterwards.

**Evidence** (`tests/Test-WorkerPool.ps1` assertion 8): a probe against the **captured** pool object
reports failure after close (in-flight payloads abort cleanly, never silently reuse a closed pool); the
tail teardown is asserted to appear **after** the per-computer runspace teardown; and both shutdown paths
wire a bounded close.

### Reviewer Claims Verified — Three Were False Positives (2026-10-09)

A code review reported three "pre-existing defects" in the remote helpers. Each was **checked against the
source and found false** - recorded so they are not "fixed" into real breakage:

| Claim | Finding |
|---|---|
| `Wuu.Network` returns `Output` but Core reads `.Output` (contract break) | **False.** `Invoke-RemoteComWithTimeout` returns `@{Success=$true; Output=...}` and all three Core readers read `.Output`/`.Success`/`.Error` consistently; a grep for `.Result` finds none. |
| Core's inlined CIM twin reads the wrong envelope level | **False.** Core's payload twin does `if ($cimResult.Success) { $inner = $cimResult.Result; if ($inner -and $inner.Success) { return @{Success=$true; Result=$inner.Result} } }` - the correct nested unwrap. |
| `Wuu.Credentials` calls the broken Core `Invoke-CimWithTimeout` | **False.** The Core twin is a `function` defined **inside the worker payload scriptblock** (module-scope, callable by main-session Core handlers), not a module export - `Wuu.Credentials` cannot resolve it. The module function of that name lives in `Wuu.Remote` and is correct. |

**Pinned instead of "fixed"** (`tests/Test-RemoteHelpers.ps1` sections 6/7): a failed probe reports
`Success=$false` with **no** `Result` (reading only the always-true pool wrapper cannot report a false
success); and both CIM copies are asserted to inspect the nested inner result and return the same
`@{Success;Result}` shape. The envelope contract is now enforced against future flattening.

**Verified:** 18 suites, 17 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0.

### Payload Writer Inventory and Ratchet Guard (G1 / T007.11, 2026-10-09)

**What was wrong with the earlier inventory.** The broad candidate scan left 935 records as
`NeedsReview` and could not answer the conversion's only question: which ROW fields each injected
PAYLOAD writes, and whether the write is inside a Dispatcher envelope. Measured cause of a first
attempt's failure: a payload `$X = { ... }` parses its right side as a `CommandExpressionAst`
**wrapping** the scriptblock, so a `ScriptBlockExpressionAst` type test matched nothing and every write
was mis-attributed to the enclosing function.

**Delivered:**
- `Scripts/Get-PayloadWriterInventory.ps1` - AST inventory attributing every row write to its owning
  payload chain, with `Set`/`Compound`/`Increment` kind and envelope detection.
- Result: **106 row writes**, **79 payload-owned** across eight conversion targets: `$GetUpdates` 31,
  `$InstallUpdates` 14, `$DownloadUpdates` 13, `$RestartComputer` 9, `$RemoveOfflineComputer` 6,
  `$WUServiceAction` 4, two `$onProgress` callbacks 1 each. **All 79 are inside a Dispatcher envelope.**
  The remaining 27 are the two twins, the scheduler, the module fallback helpers and one UI handler.
- `tests/Test-PayloadWriterGuard.ps1` - per-payload ceilings that fail on a new or unclassified payload
  write. 10 assertions; **mutation-proved** (lowering a ceiling produced a failure naming the payload,
  then byte-exact restore).

**Honest limits:** the guard counts DIRECT assignments on the row parameter; alias, dynamic-member and
string-created-scriptblock writes still need the manual review recorded in the inventory. Envelope
detection does not prove the write is fenced - only the conversion does that. No conversion has been
performed yet.

### G1 Writer Disposition Table (2026-10-09)

Every owner the inventory found, with its disposition. This is the artifact G1 requires ("every writer
has an owner AND a disposition"); the ratchet ceilings are the machine-checked half.

| Owner | Writes | Disposition | Rationale |
|---|---|---|---|
| `$GetUpdates` | 31 | **Routed** | 27 to the fenced multi-field writer; 4 queue/retry writes to `SetPendingOpScript` + the writer |
| `$InstallUpdates` | 14 | **Routed** | all to the fenced writer (incl. `InstallErrors`/`RebootRequired`/counters) |
| `$DownloadUpdates` | 13 | **Routed** | incl. the `Downloaded` read-modify-write folded into the patch; 2 queue writes via `SetPendingOpScript` |
| `$RestartComputer` | 9 | **Routed** | incl. refusal notices, which are themselves fenced |
| `$RemoveOfflineComputer` | 6 | **Routed** | |
| `$WUServiceAction` | 4 | **Routed** | |
| 2 x `$onProgress` | 2 | **Routed** | progress text only |
| cleanup loop (job-cleanup runspace) | 3 | **Routed** | new `SetCleanupTimeoutScript`; identity captured BEFORE the release so a superseded pass cannot repaint a new operation |
| `Set-ComputerState` / `Set-ComputerTimeout` (module helpers) | 7 | **Construction/fence** | these ARE fence implementations; extended with the multi-field writer |
| `SetComputerStateScript` / `SetComputerTimeoutScript` (twins) | 6 | **Construction/fence** | worker-side fence implementations |
| `SetComputerFencedFieldsScript` / `Set-WuuComputerFencedFields` | 4 | **Construction/fence** | the fenced writer itself |
| `SetCleanupTimeoutScript` | 3 | **Construction/fence** | the cleanup fence |
| `Start-PendingUpdateCheck` (scheduler) | 8 | **Exempt** | the scheduler CONSUMES `Pending`; it is the consumer of the queue, not a writer of it, and `-IgnorePending` exists for exactly this |
| `New-ComputerRunspace` | 8 | **Exempt** | row construction during runspace setup, before any operation exists |
| `Start-WuuApplication` (add/load sites) | 3 | **Exempt (construction)** | row construction/backfill at add, and the atomic `Set-WuuComputerRows` commit |
| `$eventShowUpdateHistory` | 1 | **Exempt (presentation)** | UI-only field write in a menu handler |

**Rule applied:** *Route* anything that writes operation/display state during an operation; *Exempt* only
construction (no operation exists yet), the scheduler consuming the queue it owns, and presentation. Any
future owner not in this table fails `Test-PayloadWriterGuard` until it is classified deliberately.

**Plan amended** with the independent validation's 8 binding rules (CommitEdit-always/Refresh-conditional;
gate-inside-envelope; extend both twin copies; classify Pending/PendingOp/Retry*; refusal display
convention; cleanup-runspace injection; guard-first). Operator `ComputerList.config` backed up
hash-verified before the smoke test; confirmed gitignored by name and excluded from the package.

**Verified:** 19 suites, 18 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0; new files PS5.1-safe.

### Multi-Field Fenced Writer (T007.8 design + implementation, 2026-10-09)

**Why it was needed.** The payloads set several row fields **together** (`State` + `Status` +
`UpdatesStatus` + `RebootRequired` + counters). Calling the single-field state writer once per field
would expose half-written rows to any reader, and the module funnel has no parameters for
`Available`/`Downloaded`/`InstallErrors`/`RebootRequired`/`RetryCount`/`RetryAt` at all.

**Delivered - one atomic, allow-listed patch, on both copies:**
- `SetComputerFencedFieldsScript` (injected twin, `Wuu.WindowsUpdate.psm1`) and
  `Set-WuuComputerFencedFields` (module copy, `Wuu.State.psm1`, exported) apply the whole field bag in
  one step under the shared store gate, with the same identity / reset / terminal / live-row rules as
  the funnel.
- **Allow-list refuses `Pending`/`PendingOp`** (the scheduler's one-slot queue, whose precedence rule is
  inlined in payloads - writing it here would bypass that policy) and **`OperationId`/`OpState`**
  (funnel-owned identity), so a display patch cannot smuggle a queue or ownership change.
- A **rejected field rejects the whole patch** (no silent partial apply), and a refused write leaves
  **every** field untouched.

**Evidence** (`tests/Test-WorkerTwinFence.ps1` section 8, 125 assertions total): a multi-field patch
lands all fields; the twin and the module copy **agree** on the same patch; a superseded writer is
refused with **no partial write**; the queue and identity fields are rejected; a settled row is not
rewritten by a bare patch.

**Design rules this satisfies** (from the adversarial validation): the writer takes the gate *inside*
the caller's envelope; it is single-source-of-truth across both copies; and it cannot contradict the
scheduler queue policy.

**Still to do (T007.8-T007.10):** the actual conversion of the 79 payload call sites to this writer,
keeping the `CommitEdit`-always / `Refresh`-conditional envelope, lowering the ratchet ceilings per
payload. The writer is the prerequisite; no call site has been converted yet.

### Payload Conversions Landed (T007.8-T007.10, 2026-10-09)

All eight payloads converted. The ratchet ceilings are the proof: each dropped to its floor, which
shows writes were **removed**, not merely wrapped in a fence.

| Payload | Writes before | after |
|---|---|---|
| `$GetUpdates` | 31 | **4** (deliberate exemptions) |
| `$InstallUpdates` | 14 | **0** |
| `$DownloadUpdates` | 13 | **2** (deliberate exemptions) |
| `$RestartComputer` | 9 | **0** |
| `$RemoveOfflineComputer` | 6 | **0** |
| `$WUServiceAction` | 4 | **0** |
| 2 x `$onProgress` | 1 each | **0** |
| **Payload total** | **79** | **6** |

The 6 remaining are the **deliberately exempt** scheduler fields: `Pending`/`PendingOp` (the one-slot
queue) and `RetryCount`/`RetryAt` (retry bookkeeping). The fenced writer refuses those by design because
the queue precedence rule is inlined in the payloads; routing them requires deciding how to reproduce
`Set-WuuPendingOperation`'s policy - an **open decision**, recorded in the guard's ceiling comments.

**Pattern at every site:** the `Dispatcher.Invoke` envelope is kept; `EditItem` opens the transaction;
multi-field patches are applied in ONE fenced call; **`CommitEdit` always runs in-line before the
conditional `Refresh`**, so a refusal cannot leave an edit transaction open (which would break every
later envelope). Writes pass `-OperationId $WuuOperationId` so a resubmission stays legal while a
superseded writer is refused. Refusal notices are themselves fenced, so a stale operation cannot
clobber a new owner's display. Compound counters are read-modify-written into the patch.

**Honest limits:** the ceilings prove removal by static count, not runtime behaviour; no site has been
observed repainting on a real desktop; the cleanup-loop writes (below) are still direct.

### List Completion Pass - all payloads at 0 (2026-10-09)

Every payload is now **0 direct row writes**. The previously "exempt" queue/retry fields were not all
exempt after all, and the remaining list items were worked through:

| # | Item | Outcome |
|---|---|---|
| 1 | Cleanup-loop writes | `SetCleanupTimeoutScript` injected into the job-cleanup runspace; the identity is captured **before** the release, so a superseded pass cannot repaint a newly adopted operation. Ceiling 3 -> 0. |
| 2 | Pending/Retry "exemption" | **Reversed on evidence.** `RetryCount`/`RetryAt` carry no policy, so they were added to the fenced writer's allow-list. `PendingOp` DOES carry a policy (SS16), so a **precedence-respecting queue twin** (`SetPendingOpScript`) was injected and all four queue sites routed through it - a raw write could have **downgraded** an `AutoFlow` the operator had queued. |
| 3 | G1 disposition table | Written (above): every inventoried owner classified Routed / Construction / Exempt, with the rule stated. |
| 4 | Plan checkboxes | Synced to reality (T007.1-T007.10, T011.1, T011.3 now `[x]`). |
| 5 | Operator config | Restored from backup, hash-verified (`F6484FE0...`). |
| 6 | T006.1 selection | `Resolve-WuuSelectedRows` resolves the selection to **store rows by key**; 7 handler call sites migrated; tested against a deliberately stale view object to prove the store row - not the view snapshot - is used. |
| 7 | T008.1 revision gate | `Get-WuuViewSnapshot` (rows + revision, coherent under the gate); `Sync-WuuViewCollection -Revision -AppliedRevision` refuses a superseded snapshot, so a stale tick cannot resurrect removed state. |
| 8 | T006.2 desktop fixture | Real WPF `ListView`: renders; **keeps selection across a sort** (measured - WPF preserves the item objects); restores it **by key after a rebuild**; repaints without rebuilding; survives a 25-update burst. |
| 9 | T009.1 credential epoch | The documented mechanism was **never implemented** - `Start-UpdateCheckJob` neither stamped nor compared the epoch. It now stamps the row's epoch when the runspace is built and **rebuilds a stale runspace**, so an operation runs under the identity configured at submission. |

Also fixed in passing: `Wuu.Gui.psm1` and `Test-GuiProjection.ps1` contained non-ASCII (an em-dash) with
**no BOM** - the same defect class that produced the `'` mojibake; both now carry a BOM, content
byte-identical and verified to decode.

**Verified:** 19 suites, 18 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0.
`Test-GuiProjection` 74 assertions, `Test-WorkerTwinFence` 149, `Test-CredentialDeterminism` 38,
`Test-PayloadWriterGuard` 10.

### Repaint Tick - the repaint gap closed (T008.2 groundwork, 2026-10-09)

**Defect.** Some writers signal a redraw ONLY through `$stateStore.Touch()` and sit **outside** any
dispatcher envelope - the timeout twins, the cleanup loop, the funnel. **Nothing consumed `Revision`**,
so those changes never reached the grid: a row could sit on stale text indefinitely (a final-retry
timeout write was the concrete case).

**Fix.** The scheduler tick now compares the store's `Revision` with the last one rendered and calls
`Items.Refresh()` only when it moved, so a `Touch`-only write repaints and an idle fleet costs nothing.
Guarded against a shut-down dispatcher, and a repaint failure cannot kill the scheduler tick.

**Honest scope:** the ListView currently holds the **engine row objects** (the store mirrors by
reference), so `Items.Refresh()` is sufficient for a `Touch`-only write. Under a fully **decoupled**
projection the tick must re-project through `Sync-WuuViewCollection` instead - that is the remaining half
of T006.1 and is recorded here rather than assumed. The fixture asserts the current behaviour (a
Touch-only write repaints once the revision is consumed).

**RESOLVED (2026-10-09, same session):** that "remaining half of T006.1" is now DONE - see the Production
Projection entry below. The tick calls `Update-WuuProjection`, which reconciles detached view rows from a
coherent snapshot, so the fixture was rewritten to prove the detached path rather than the aliased one.

**Fixture fix in passing:** the WPF fixture added columns to `$ListView.Columns`, which is **null** on a
bare ListView (columns belong to the `GridView`), so the bindings never applied and an
`InvokeMethodOnNull` error was printed while the assertions still passed by reading the objects directly.
Corrected to build a `GridView` and assign `$list.View`; the suite now runs clean.

**Verified:** 19 suites, 18 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0; sources PS5.1-safe.

### Production Projection - the ListView is now a real projection (T006.1 / T008.1 / T006.2, 2026-10-09)

**Defect.** The ListView held the ENGINE row objects BY REFERENCE (the store mirrored the same objects), so
there was no projection at all: the grid WAS the state. That is why a worker had to own a Dispatcher and
why `SafeUpdateListViewItem`/`Set-ComputerState`/`Set-ComputerTimeout` wrote the item.

**Fix.** A new Core helper `Update-WuuProjection` reconciles the `clientObservable` against a coherent
`Get-WuuViewSnapshot` through `Sync-WuuViewCollection`, revision-gated. The ListView now holds DETACHED
`ConvertTo-WuuViewRow` view rows. Everything that used to write the VIEW or add/remove engine rows to the
view collection was converted: add / remove / clear / load register in the STORE and project; the phase
writer, the selection reads, `SafeUpdateListViewItem` (module copy AND injected twin),
`Set-ComputerState`/`Set-ComputerTimeout` and the update-history error path write the ENGINE row through
the fenced writer. Row colour moved to XAML `DataTrigger`s bound to the projected `Color` field, because
the imperative `ItemContainerGenerator.ContainerFromItem(...).Background` path is dead once the grid holds
view rows. `Phase` was added to the fenced writer's allow-list (a display/scheduling field, not queue or
identity) so the operator's phase assignment routes through the fence.

**A measured non-finding that shaped the design:** `ListView.Items.EditItem($engineRow)` /
`CommitEdit()` on a row that is NOT in the view collection is HARMLESS (a bare WPF probe confirmed no
throw), and mutating an engine row does not change the view. So the existing `EditItem`/`CommitEdit`
envelope call sites needed no change - only the field writes did. This is why the conversion is low-risk
and why `Refresh`-on-`Applied` sites still work.

**Evidence** (`tests/Test-GuiProjection.ps1`, 83 assertions): section 8 proves DECOUPLING - the view row is
a distinct object from the engine row; a direct engine write does not reach the view until the projection
runs; a view write does not reach the engine. Section 9's repaint fixture now drives the real
`Update-WuuProjection` (extracted from Core's AST, as section 6 does for `Resolve-WuuSelectedRows`) and
asserts a Touch-only engine write reaches the detached view only after the projection. `Test-StateStoreMirror`
section 8 was updated to the decoupled clear-list contract and made DISCRIMINATING: its view is deliberately
EMPTY, so a body that still read `$uiHash.Listview.Items` would delegate zero rows.

**Honest limits.** No site has been observed repainting on a real desktop (the elevated interactive smoke
test is still the operator's to run). The desktop fixture proves the reconcile path, not a live WPF render
pass in the app. T008.2 (close/prompt responsiveness while jobs and projection work are pending) remains
open.

**Verified:** 19 suites, 18 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0;
`Test-GuiProjection` 83, `Test-WorkerTwinFence` 149, `Test-StateStoreMirror` 51.

### Responsiveness and Headless Boundary (T008.2, 2026-10-09)

**Defects closed.** (1) The cleanup loop's 10-minute timeout paint marshalled to the UI thread
(`Dispatcher.Invoke`) to find the ListView item - so a busy or wedged UI blocked the cleanup loop, and
the write depended on the grid holding the engine rows. It now resolves the STORE row BY KEY and writes
it under the shared state gate through `SetCleanupTimeoutScript` (which also sets `Color='Timeout'` for
the projection); no Dispatcher hop, no imperative `ContainerFromItem(...).Background`. (2) Application
shutdown called `.Stop()`/`.Dispose()`/`.Close()` **unbounded** on the jobs, the per-computer runspaces
and the job-cleanup runspace - each joins a thread that may be wedged in an uninterruptible native call,
hanging exit. (3) The shutdown and window-close paths counted live workers by iterating
`$uiHash.Listview.Items` and reading `.Runspace` - which the detached view rows do not carry, so every
runspace would have been reported dead and none closed.

**Fix.** New `Close-WuuBoundedTeardown` (Wuu.Workers, exported) runs a teardown in a dedicated helper
runspace and ABANDONS it on timeout (same proven pattern as `Close-WuuWorkerPool`), never throwing and
never blocking. The tail shutdown and the window-close path now route jobs, per-computer runspaces and
the cleanup runspace through it, and the runspace inventory is sourced from `$global:stateStore.Rows`.

**Headless boundary.** `Wuu.Gui`'s header claimed "THIS IS THE ONLY MODULE ALLOWED TO TOUCH WPF", which
`docs/tasks/validation.md` (Phase 1 correction 2) explicitly overrides: Core event wiring and the
credential/OU dialogs legitimately hold WPF on the owning dispatcher. The header now states the
asymmetric requirement - Wuu.Gui owns the pure projection, ENGINE modules and INJECTED WORKER TWINS must
be headless. `Test-WorkerTwinFence` asserts it: (a) no injected twin references
`uiHash`/`ListView`/`Dispatcher`/`System.Windows`/`ContainerFromItem`; (b) `Wuu.State` and
`Wuu.Configuration` are WPF-free; (c) `Wuu.Gui` confines WPF to `Get-WuuColorBrush`. Checked on
comment-stripped source, so a doc mention cannot trip it.

**Evidence.** `Test-WorkerPool` section 9 drives `Close-WuuBoundedTeardown` headlessly: a quick teardown
reports success, and a WEDGED teardown (`Start-Sleep 60`, 2s deadline) RETURNS in ~2s reporting failure -
"it returned" is the property under test, so this is timed. It also asserts the shutdown routes through
the helper (`>= 3` call sites). `Test-WorkerTwinFence` section 1 carries the headless-boundary guard.

**Honest limits.** The bounded-teardown test proves the helper (a real abandoned pipeline); it does not
prove a wedged *payload* in the live app (the elevated interactive smoke test is still the operator's).
UI-thread prompt responsiveness during a password dialog under concurrent projection is not exercised -
the projection tick is one bounded, gate-guarded compare-and-reconcile, and a busy gate SKIPS the tick.

**Verified:** 19 suites, 18 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0;
`Test-WorkerPool` (bounded teardown section), `Test-WorkerTwinFence` 153.

### Submission Completeness - the scheduler stops reading the ListView (T011.2, 2026-10-09)

**Defect.** `Start-PendingUpdateCheck`, `Test-PhaseCompletion` and their dependent phase helpers read and
wrote `$uiHash.Listview.Items` for ENGINE fields (`Pending`, `PendingOp`, `RetryAt`, `Phase`, `Status`,
`State`). That was correct only while the ListView held the engine rows by reference. After the T006.1
decoupling (grid holds detached view rows) the scheduler would silently stop working: a Phase-E retry
would never be promoted, a queued operation would never be submitted, and `Test-PhaseCompletion` would
find zero computers in every phase and report it complete - **auto-flow would simply stop,** with no
error.

**Fix.** The scheduler sources its input queue from the ENGINE STORE (`$ctx.StateStore`, falling back to
`$global:stateStore`, exactly as the funnel resolves it) and `Touch()`es on every write so the projection
repaints the change. `Test-PhaseCompletion` sources the phase set from the store. The runspace-failure
catch now paints the ENGINE row (resolved from the store by key) instead of the dead
`EditItem`/`CommitEdit`/`ContainerFromItem` path.

**Evidence.** `Test-PendingDrain` gained a discriminating guard: a job is registered ONLY in the store,
the ListView is deliberately EMPTY, and the scheduler must still drain it - a ListView-reading scheduler
would drain nothing. `Test-AutoFlowChain` now registers its queued rows in the store (the scheduler reads
the store) and still proves each chain executes exactly once, the re-arm on refusal, and the cap/busy/
empty-owner refusals. `Test-CrossModuleResolution` still passes (its context omits `StateStore`, and the
global fallback keeps `New-ComputerRunspace` working).

**Honest limits.** The cap/busy refusals are argued from the contract (they remain the cases that fail if
the busy gate is dropped); a live concurrent-cap race is not reproduced. No site has been observed
draining on a real desktop - the elevated interactive smoke test is still the operator's.

**Verified:** 19 suites, 18 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0.

### Install Outcomes and Retirement Policy (T010 / T012 / T013, 2026-10-09)

**Install outcome (T010).** `tests/Test-InstallOutcome.ps1` drives the REAL `$InstallUpdates` payload with
the remote seam (`InvokeRemoteTaskScript`) MOCKED, so the payload's actual result-handling code runs
unchanged. The result's independent facts are proven separately: `Count` -> `InstallErrors` and
`Get-WuuTargetOutcome` = Failed even when `State`='Complete' (errors are NOT masked by a settled state);
`RebootRequired` true/false independent of the error count; a `Success=$false` install settling to
`Error`/`UpdatesStatus=Error`. Three cases (errors / reboot / fail).

**Why it runs as a CHILD PROCESS.** Two facts made an in-process harness unsound, both worth recording:
1. The payload's catch calls `exit`, which would abort a suite. But `exit` still runs a `finally` block -
   measured - so the child captures the settled row there.
2. A faithful dispatcher envelope runs the action on the UI thread (a SEPARATE thread). A stub that
   invokes `$action` INLINE on the worker's own busy-pipeline thread DEADLOCKS the moment the action calls
   a module function - the worker's engine is busy. So the payload is driven in the MAIN session (one
   runspace), exactly like the UI thread, not in a worker runspace.

**A live crash vector found and fixed by this test.** The payload error paths still called
`$uiHash.Listview.ItemContainerGenerator.ContainerFromItem($Computer)`. That is a `.NET`
**ItemContainerGenerator**, NOT the ListView - and it is a DIFFERENT object on the main session than the
one in the worker's mirrored `$uiHash`. Under the decoupled projection it is also dead (the grid holds
detached view rows, so a container no longer maps to the row). It threw "You cannot call a method on a
null-valued expression" on the ENVELOPE thread, which on a worker would be swallowed and silently stop
the update. All six such blocks were removed; error colour comes from the projected `Color` field.

**Retirement policy (T012/T013) - documented and asserted.** IDLE-REUSE: a normal settle releases the
IDENTITY but RETAINS the runspace (`Start-UpdateCheckJob` reuses a non-null `Runspace`), so operations do
not churn runspaces. RETIRE: `ClearOperation` retires the identity and DETACHES the runspace but does NOT
close it - `Close()` can block on a busy pipeline and must not run under the state gate, so the CALLER
owns retirement after capturing the reference (capture-before-detach, or the close is dead code). Both
are asserted in `Test-OperationIdentityLifecycle` section 6 (a fake runspace records Close/Dispose).

**Honest limits.** The install test mocks the remote seam - it proves the mapping, not a live SYSTEM task.
An authorized already-dispatched remote effect may continue after local cancellation; local disposal does
not prove a SYSTEM task stopped. The elevated interactive smoke test remains the operator's to run.

**Verified:** 20 suites, 19 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0;
`Test-InstallOutcome` 13, `Test-OperationIdentityLifecycle` 39.

### Package Path Separators - a real shipping defect found by INSPECTING the archive (2026-10-10)

**Defect.** `Scripts/Package-WUU2.ps1` built the zip with `[IO.Compression.ZipFile]::CreateFromDirectory`,
which on Windows writes **platform separators**. Re-reading the built archive showed **22 of 27 entries**
using `\` (e.g. `Scripts\Install-Patches.ps1`, `src\Wuu.Core.psm1`, `ui\MainWindow.xaml`). The ZIP spec
requires `/`, and non-Windows extractors take the name literally - they create FILES named `src\Wuu.Core.psm1`
in the extraction root instead of a `src/` folder, so the package would not run when unpacked off Windows.
This was invisible from the build's own success message (it still reported a valid entry count) and from
the unit suites - only reading the archive's entry names exposed it.

**Fix.** Entries are now created one at a time from the relative path with `/`
(`ZipFileExtensions::CreateEntryFromFile`), and the freshly built archive is re-read and **THROWS** if any
`\` survives. Verified: rebuilt package = 27 entries, **0 backslash entries**; extracting it yields the
expected `Scripts/`, `src/`, `ui/` folder tree; every module parses and `Wuu.State`/`Wuu.Workers`/
`Wuu.WindowsUpdate` import headlessly from the unpacked tree.

### Independent Review (T025.1) and Disposition (2026-10-10)

**Tool/model.** Agent `copilot-reviewer` (an independent adversarial reviewer), 2026-10-10. Supplied
source visibility: it read `Wuu.Core.psm1`, `Wuu.WindowsUpdate.psm1`, `Wuu.State.psm1`, `Wuu.Gui.psm1`,
`Wuu.Workers.psm1` and `ui/MainWindow.xaml` in full; it had **no shell** (nothing executed) and no
pre-remediation diff. A review does not replace G1-G6 execution. Verdict: **FIX REQUIRED**.

**Findings it RAISED, and the disposition of each.** (Every claim was re-checked against the source
before acting; line numbers below are where the reviewer found them.)

| # | Finding | Verified | Disposition |
|---|---|---|---|
| C-1 | `Set-WuuPendingOperation` and the twin `SetPendingOpScript` write `Pending`/`PendingOp` with NO gate, racing the scheduler's consume of the one-slot queue (a lost update can strand/replace a queued install). | Yes - neither took the gate. | **FIXED.** Both copies now take the shared store gate (bounded 5 s, fail-closed) around the read-modify-write. `Test-PendingPolicy` does not exist in this edition (that reviewer reference was to `WUU2-CLI`); `Test-AutoFlowChain`/`Test-PendingDrain` cover the paths and stay green. |
| C-2 | `$eventRemoveOfflineComputer` enumerates the VIEW and passes view rows as `-ComputerItem`; the live-row check then refuses every one, the sweep is inert, and each row leaks a runspace (created on the view object, which no shutdown/load sweep visits). | Yes. | **FIXED.** The sweep now sources `$global:stateStore.Rows`. |
| C-3 | `Start-UpdateCheckJob`'s admission-refusal path writes `$ComputerItem.Status` directly, clobbering a BUSY row's live progress - contradicting its own fast pre-check rule. | Yes. | **FIXED.** The refusal Status write is skipped when the row is busy (the running op's status IS the visible state). |
| M-1 | `Start-PendingUpdateCheck` mutates engine rows without the gate. | Yes. | **FIXED.** The scheduler now takes the shared store gate (`Enter/Exit-WuuStateLock`) around the RetryAt promotion, the phase-wait display write, and - the load-bearing one - the read-and-clear of the one-slot queue (`Pending`/`PendingOp`), released before `Start-UpdateCheckJob` so the submission lock and state gate are never nested. `Test-StateFencing` section 3b proves it DETERMINISTICALLY (a worker holds the gate past the writer's budget, so the main-session queue write is REFUSED and leaves the slot untouched; accepted once free). |
| M-2 | `Update-WuuProjection` advanced `$script:lastRenderedRevision` unconditionally, so a refused snapshot would freeze the fleet. | Yes (the refusal is not reachable today, but the watermark logic is wrong). | **FIXED.** The watermark advances only when the snapshot was applied (`-Force` or `Revision -gt Last`). |
| M-3 | The per-operation deadline machinery (`Set-WuuOperationDeadline`/`Get-WuuOperationTimeoutSeconds`/`Test-WuuOperationExpired`) is exported but called from nowhere in `src/`; the cleanup loop hard-codes a flat 10 minutes, so an `AutoFlow` with a declared 4-hour budget is force-stopped at 10 minutes. | Yes - exported, zero call sites. | **FIXED.** `Start-UpdateCheckJob` now STAMPS the per-op deadline at submission (`Set-WuuOperationDeadline`), and the cleanup loop ENFORCES it through an injected `TestJobExpiredScript` (row deadline preferred; start time + the injected default budget as fallback). The flat `TotalMinutes -gt 10` is gone. `Test-OperationIdentityLifecycle` section 7 proves the rule (AutoFlow ~4 h, past-deadline expired, fallback basis) and the wiring. |
| M-4 | `Test-PhaseCompletion` hard-codes `ContinueOnFailure`; the store's `PhaseFailurePolicy` and `Test-WuuPhaseFailureBlocks` are consulted nowhere. | Yes. | **FIXED.** `Test-PhaseCompletion` now reads `$store.Settings['PhaseFailurePolicy']` and defers to `Test-WuuPhaseFailureBlocks` per settled-failure row; an unknown policy blocks (fails safe). New `tests/Test-PhasePolicy.ps1` drives the real gate for all three policies, pending rows, a clean row and an unknown policy (14 assertions). |
| M-5 | `Update-WuuConnectivityState` is extracted but never called; the live payload still evicts on ONE lost ICMP packet, AND its store removal cannot resolve in a worker runspace. | Yes. | **FIXED.** The `$RemoveOfflineComputer` payload now counts CONSECUTIVE failures (`ConnectivityFailures`) and evicts only at the injected `ConnectivityFailuresBeforeRemoval`; below threshold it KEEPS the row and records the count. Eviction goes through a new injected `RemoveComputerRowScript` twin (gate + identity + live-row guarded) because the module `Remove-WuuComputerRow` and `$global:stateStore` are unreachable in a worker. `Test-StateFencing` section 2b asserts the wiring. |
| M-6 | `Resolve-WuuSelectedRows` fell back to the VIEW object when the store was present but the key was gone - handing the engine a row it must refuse. | Yes. | **FIXED.** The fallback now applies only when there is NO store; a missing key resolves to nothing. |
| m-1 | `ColorBrush` is produced as `$null` and never filled; `Get-WuuColorBrush` has no caller. The live colour path is the XAML `DataTrigger` on `Color`. | Yes - the trigger works; the field is unvalidated. | **FIXED (validation).** The fenced writer (both copies) now rejects an unknown `Color` name (`Default`/`Error`/`Timeout`/`Success` only) instead of letting it render as no fill silently; `Test-WorkerTwinFence` asserts accept/reject. `Get-WuuColorBrush`/`ColorBrush` remain an unused WPF helper - harmless (colour is bound in XAML), left as-is. |
| m-2 | Terminal-state list redeclared in 6 places despite "one list" doc. | Yes. | **DOC CORRECTED.** The copies are intentional: an injected worker twin cannot call the module's `Get-WuuTerminalStates`, so each twin inlines the three states. The invariant's doc now says so instead of claiming a single list. |
| m-3 | `Close-WuuWorkerPool` returns `$null` (falsy) on a virgin process, producing a spurious shutdown warning. | Yes. | **FIXED.** Return `[bool]$script:WorkerPoolCloseOk` coerced through a typed `[bool]` - a virgin process now reports success, not a timeout. |
| m-4 | Abandoned-helper list appended without synchronization. | Suspected, not reachable concurrently. | **NOTED.** |

**NEW finding raised by the review, confirmed and fixed:** the `$RemoveOfflineComputer` payload calls
`Remove-WuuComputerRow -Store $global:stateStore`, but that MODULE function is NOT injected into the
worker runspace and `$global:stateStore` is not reachable there - so the removal path silently no-ops
(swallowed by the surrounding `try/catch`) while the `$clientObservable.Remove` write lands on the view.
The eviction therefore never reaches the authoritative store. Recorded here as the concrete half of M-5;
it is the reason M-5 must be fixed by wiring `Update-WuuConnectivityState` + an INJECTED store-removal
twin, not by a one-line change.

**Claims that HELD (evidence):** pre-`BeginInvoke` ownership and the rollback guard; the scheduler/phase
gating now reading the store (T011.2); `Get-WuuViewSnapshot` taking the gate; `Close-WuuBoundedTeardown`
being genuinely bounded; the G6 effect-authorization twins failing closed and returning rather than
throwing; no lock held across a `Dispatcher.Invoke`/remote call/prompt/I-O; no lock-order inversion
between the submission lock and the store gate; no injected twin referencing WPF.

**Honest limits of the review.** No shell, so no command was run; every "the tests do not cover X" is
from reading assertions. No baseline diff, so it could not separate new from retained no-op
`EditItem`/`CommitEdit` sites (which this plan already records as deliberately harmless and re-verified
by probe). The concurrency interleavings in its counterexample are constructed from source, not
reproduced.

**Verified after the fixes:** 20 suites, 19 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0.

### Desktop Smoke Test - Blocked, Handed Over (2026-10-09)

**The strongest headless evidence available was added before handing over:** the converted payloads
`CALL` the fenced writer at every site, so its ABSENCE inside a worker runspace would throw into each
payload's `catch` and the grid would silently stop updating. `Test-WorkerTwinFence` now drives
`SetComputerFencedFieldsScript` **in a real factory runspace** (not the module copy) and asserts it
applies - the same proof section 6 gives for the state twin. Suite total 126 assertions.

**Why the interactive test could not be run here:** `WUU.ps1` requires an elevated host, this session is
**not elevated** (`IsInRole(Administrator) = False`), and it is an interactive WPF window. It must be run
by the operator. Preconditions verified: `ComputerList.config` backup is intact and hash-matches the
live file (`F6484FE0...`).

Procedure (elevated PowerShell, from the repo root):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1
```

1. Add `localhost`, right-click → Check for Updates; watch that the **row repaints** through the new
   fenced path (Status/State change and the grid refreshes).
2. Confirm no `EditItem`/"edit transaction" exception appears (a dangling transaction would break every
   later envelope - the critical risk the writer's `CommitEdit`-always rule guards).
3. Save the encrypted list, then load it back; confirm the fleet swaps in one step.
4. Close the window; confirm it exits without hanging.

**Known-expected finding:** a final-retry timeout write has no repaint path (the twin call sites sit
outside any envelope and nothing consumes `Revision`), so a row can display stale progress text. That is
recorded, not fixed.

**Verified headless:** 19 suites, 18 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0.

### FIELD DEFECT D17 - second Check while one runs painted the row Error (2026-10-09)

**Found by the operator's desktop smoke test** - the check itself worked, but the row said Error. The
debug log (obtained with `$env:WUU_DEBUG='1'`) showed the exact cause:

```
[09:17:36] [localhost] Started GetUpdates for localhost          <- check A running
[09:17:41] [ERROR] Runspace creation failed for localhost:
    Exception calling "SetVariable" ... "A pipeline is already running.
    Concurrent SessionStateProxy method calls are not allowed."
[09:17:52] Update search completed successfully                    <- A was fine all along
```

**Root cause - mine.** In the D14 reorder I moved admission before `BeginInvoke` but deliberately kept
runspace creation and `SessionStateProxy.SetVariable('WuuOperationId', ...)` outside the critical
section ("keep expensive work out of the lock"). `SetVariable` on a **busy** runspace throws, so the
operator clicking Check while a check was still running hit that throw, which the catch reported as
"Runspace creation failed" and painted `State`/`UpdatesStatus` = `Error`. A false failure, on a row whose
real operation was working.

**Fix:**
1. `Start-UpdateCheckJob` now runs a **fast busy pre-check before any runspace work** - if the row is
   busy it refuses cleanly (`return $false`), no runspace created, no `SetVariable`, no Error.
2. The identity is stamped **inside** the admission section, after the busy re-test has proven the
   runspace idle, so the `SetVariable` can no longer race a live pipeline.
3. The fast-refusal path does **not** write `Status` - the row is busy, so a refusal message would
   overwrite the running operation's live progress text.

**Regression test** (`tests/Test-AutoFlowChain.ps1` §2a-ii, the operator's exact double-click): a second
Check while one is `Running`, against a real idle runspace, is refused with `$false`, leaves
`State`/`UpdatesStatus` **not** Error, and preserves the running operation's progress text and owner.
**Mutation-proved:** disabling the pre-check reproduces the failure (`FAIL [doubleclick]`), then restored
byte-exact.

**Operator re-test (2026-10-09 13:38) - FIX CONFIRMED.** The double-click no longer produces
`[ERROR] Runspace creation failed`. The log now shows a clean refusal, and the running check completing
normally with no `State`/`UpdatesStatus` = Error and its progress preserved:

```
[13:38:03] Submission for localhost refused: computer is already running an operation (localhost:81624:1:...)
[13:38:17] Update search completed successfully
[13:38:19] Final Status: 1 update(s) found.
```

One wording inaccuracy was corrected: the manual-check refusal message said *"it will be retried"* - true
of the scheduler, not of a manual click - so it now states that the running/queued operation continues and
to click again once the row is idle.

**Verified:** 19 suites, 18 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0; sources PS5.1-safe.

**Verified:** 19 suites, 18 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0; all touched files PS5.1-safe.

**Verified:** 19 suites, 18 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0; sources PS5.1-safe.

**Independent review of this change** (agent `copilot-reviewer`, 2026-10-08) found the first version
closed the pool on the window-close path **before** the per-computer runspaces were stopped, stranding
in-flight payloads' pooled probes (they hold the captured pool object); and that the text-only assertion
proved nothing. Both fixed:

| Finding | Disposition |
|---|---|
| Window-close closed the pool first, violating the change's own children-before-pool ordering | fixed: window-close now closes the pool only when no per-computer runspace is still open; otherwise the tail `finally` owns the correctly-ordered teardown |
| A second no-op close returned `$true` even after the first close **abandoned** a wedged pool, hiding it | fixed: the last real outcome is recorded and returned for the no-pool path |
| The assertion was a bare text match | fixed: replaced with a behavioural captured-pool failure check plus an ordering index check |

Its remaining notes (accepted): helper-runspace **creation** is outside the deadline (only the close
pipeline is bounded); the window-close close swallows failure without logging; abandoned helpers are
stored in a heterogeneous list shape. Also reported as pre-existing and **not** part of this change, and
left untouched: `Wuu.Network` returns `Output` while Core reads `.Output`; Core's inlined CIM/service twins
read the wrong envelope level; `Wuu.Credentials` calls the broken Core twin.

**Verified:** 18 suites, 17 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0; sources PS5.1-safe.

**Verified after this change:** 18 suites, 17 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; gate exit 0;
`Wuu.State`/`Wuu.WindowsUpdate`/`Test-StateFencing` PS5.1-safe.

### Clear-list Binding (D11)

Added an AST binding-count regression to the existing store suite. Before repair: FAIL, expected one
case-insensitive binding but found two. Removed only the legacy case-only alias from Core.
After repair: the actual production clear-list body executes against two synthetic rows and delegates
the complete snapshot to a fake removal delegate. The existing release gate still finds the menu/control
wiring. This is not a live full-window removal/resource-retirement test.

### Obsolete Same-name Row (D12)

Before repair, both injected helpers accepted the old object when another row occupied the same name:
state changed to Installing, timeout was set, and revision advanced from 25 to 27. Each helper now
requires `ReferenceEquals(store.ByName[key], suppliedRow)`. Focused checks then pass for both helpers.
The check is still separate from mutation: concurrent replacement between check and write remains G3.

### Observable Helper Contract (D13)

Helpers return `{Applied; Refused; Reason}` for accepted updates and expected refusals. Missing required
row properties are detected before assignments; unexpected errors are rethrown, not silently swallowed.
The two production injected-timeout callers consume the verdict, stop follow-up work on refusal and
reject an absent verdict rather than emitting an incidental result object into the pipeline.
Literal `-Status` overrides canned status, including an explicit empty string; `-StatusDetail` retains
its appended semantics. Exact literal and detail behavior is exercised. This is not complete parity
with every parameter and state rule in the module funnel; T007.4/T007.5 remain partially complete.

### Actual Runspace Injection

The extended existing twin suite invokes `New-ComputerRunspace`, rather than reconstructing a function
declaration. It checks the factory's injected scriptblock, store and row reference identity, captures
the writer ID before its barrier, and asserts pipeline errors and explicit helper verdicts.

`ManualResetEventSlim` barriers order A/B, reset, remove and replace scenarios without sleeps. A retires
before B adopts via the module funnel; B writes through its real injected helper, then delayed A runs.
Acceptance advances revision; refusal changes neither protected state nor revision. Both state and
timeout replacement cases run through real workers. A malformed-row actual-worker probe must produce
a visible failure before changing State, so a swallowed exception is not accepted as a refusal.

Stop/drain waits and runspace close/disposal each have 10-second bounds. Close/disposal uses a .NET
task, not a PowerShell scriptblock on an arbitrary thread. The suite runner bounds the entire child
at 120 seconds. On exceptional cleanup, outstanding EndInvoke/error output is collected where possible.

Limitations: this tests factory injection, not a successful Start-UpdateCheckJob admission transaction
or the five live Core payloads. It does not force replacement inside the validation/write interval,
prove immutable snapshots, cancel already-started remote effects or certify the operational GUI.

## Independent Review

Tool: `functions.runSubagent`; agent: `copilot-reviewer`; date: 2026-10-08.
Underlying model identifier was not supplied and is not asserted. This was an independent read-only
agent review, not validation of the external peer-model MCP transport. Supplied scope: remediation
plan and current named runtime/test/inventory files; reviewer did not run tests or audit every dirty diff.

| Finding | Disposition |
|---|---|
| Swallowed helper errors could masquerade as refusal | fixed with explicit outcomes and visible malformed-row failure |
| Writer marker was read after the barrier | captured before barrier and checked unchanged before helper invocation |
| No runtime accepted-revision positive control | added; accepted B advances revision |
| Synchronous test stop/close unbounded | async stop/drain and bounded .NET close/disposal added |
| Existing production Close-WuuWorkerPool still synchronous/unbounded | confirmed source concern; deferred to T012/T013; no production shutdown guarantee claimed |

Follow-up reviewer found no critical finding in the repaired helper/fence paths, but returned an overall
FIX_REQUIRED verdict because production pool shutdown remains unbounded. That residual is not waived;
G6 and production responsiveness/release approval remain blocked by applicable lifecycle evidence.

## Next Gate Work

1. Complete the semantic inventory and source-created helper dependency disposition (G1).
2. Decide and prove one headless contract/dependency closure and observable failure handling (G2).
3. Share a short atomic validation/mutation/identity/snapshot protocol; reserve ownership before
   BeginInvoke and test refusal/rollback through actual submission (G3).
4. Only then convert writer groups and independent production projection (G4/G5).
5. Close effect authorization, credential epoch, shutdown and required lab/audit gates (G6).

No claim of all defects closed, complete T006/T007, safe global submission, or release readiness is made.