# Phase 1 — State Foundation and WPF Bridge (T005-T008)

Binding validation corrections: read `docs/tasks/validation.md`, section 'Phase 1 Corrections', before execution. Those corrections supersede conflicting instructions below: state writes are fenced by OPERATION IDENTITY (not a coarse mutation lock), only immutable projections become asynchronous, Core/dialog WPF usage remains legitimate, and a fake coordinator validates the Phase 1 scheduler interface.

Status: **IN PROGRESS** (2026-10-06). T005 DONE, T007 state-layer DONE (worker twin pending), T006/T008 not started. Requirements covered: R01, R02, R03.

## Goal
Introduce a headless engine state core (donor `Wuu.State`/`Configuration` semantics) into WUU2 and add a WPF adapter module so engine truth and view rendering are separate. WPF controls stop being the source of truth.

## Inputs
Target (WUU2):
- `src\Wuu.Core.psm1` (Start-WuuApplication; `$uiHash`; `$global:jobs`; DispatcherTimer ~L4514; cleanup; action handlers)
- `src\Wuu.Models.psm1` (New-WuuState; New-WuuErrorSuggestions)
- `src\Wuu.WindowsUpdate.psm1` (New-ComputerRunspace; Start-UpdateCheckJob)
- `ui\MainWindow.xaml` (ListView binding; ObservableCollection usage referenced from Core)
Donor (read-only):
- `src\Wuu.State.psm1` (New-WuuComputerRow, Update-WuuOperationState, Test-WuuStateTransitionAllowed, New-WuuResetOperationContext, Get-WuuTerminalStates/OutcomeMap, Get-WuuTargetOutcome, Get-WuuAggregateOutcome, deadline/clear/heartbeat helpers, Test-WuuOperationStateInvariant, submission-lock helpers)
- `src\Wuu.Configuration.psm1` (Initialize-WuuConfiguration; per-op deadline table; concurrency default)
- `src\Wuu.Result.psm1` (result envelope helpers, if reused by audit/reporting)
- `tests\Test-WuuOperationState.ps1`, `Test-WorkerIdentityFence.ps1` (agreement-test pattern)

## Tasks

### T005 [R02] Add headless state/configuration core — DONE
- [x] Add `src\Wuu.State.psm1` transplanting the donor's row contract + funnel + transition guard + outcome classifiers + deadline helpers + reset context. Keep the SAME terminal set (Error, Timeout, Complete) and precedence. (Verbatim donor transplant, SHA-256 `3461D80A...`, 44 exported functions.)
- [x] Add `src\Wuu.Configuration.psm1` with a WUU2-specific `Initialize-WuuConfiguration`. Preserve WUU2's existing globals/defaults; introduce a TARGET version source (do NOT transplant `v1.5.0-rc.1-cli`). -> `$global:WuuVersion = 'v1.3.4'` (target-owned); resolver reports source `tag`.
- [x] Record a defaults table separating unchanged GUI settings from explicit safer policy changes (including BlockOnFailure default). -> in the `Wuu.Configuration.psm1` module header. The one deliberate change is `EnableDebugLogging` `$true` -> `$false` (`WUU_DEBUG=1` overrides).
- [x] Wire both into `Import-WuuModules` in dependency-safe order, resolved from actual dependencies. -> Logging, State, Models, Configuration, Remote, Network, Credentials, Workers, WindowsUpdate.
- [x] Keep the funnel PURE-ish: it mutates only the row (+ optional store.Touch) and performs no UI work.
Pass criteria: `Wuu.State` imports with zero WPF references. — VERIFIED (comment-stripped scan: no WPF in `Wuu.State` or `Wuu.Configuration` code). Core's inline config block replaced by the `Initialize-WuuConfiguration` call; no duplicate version assignment.

### T006 [R01,R02] Add the WPF adapter module (`src\Wuu.Gui.psm1`) — DONE
- [x] Create `src\Wuu.Gui.psm1` owning the engine→view projection: reads engine rows, builds/refreshes UI-thread-owned view rows/ObservableCollection and presentation brushes.
- [x] The engine store is authoritative for state; the view row is a snapshot for rendering. Engine code must never read ListView/Items.
- [x] Update Core handlers so selection resolves to a Computer KEY against the engine store, not a view row index (selection must survive sort/filter/refresh). — **DONE (2026-10-09)**: `Resolve-WuuSelectedRows` resolves the 7 handler selections to store rows by key; add/remove/clear/load register in the STORE and project; the phase writer, `SafeUpdateListViewItem` (module + injected twin), `Set-ComputerState`/`Set-ComputerTimeout` and the update-history error path write the engine row through the fenced writer; the JobTimer tick calls `Update-WuuProjection`. The ListView holds DETACHED view rows. See the Production Projection entry in phase-1-evidence.md.
Pass criteria: ENGINE modules (State/Configuration/Scheduler and injected workers) testable headless with no WPF load. Core and existing dialog code may retain WPF access on the owning dispatcher.

**Delivered:** `src\Wuu.Gui.psm1`, exported as `Get-WuuColorBrush`, `ConvertTo-WuuViewRow`,
`Get-WuuStatusToken`, `Sync-WuuViewCollection`, `Get-WuuSelectedKeys`, `Select-WuuRowKeys`; wired into
`Import-WuuModules` **last**, so that ordering failure is obvious rather than incidental. Importing
`Wuu.Gui` loads no WPF assembly (asserted); only `Get-WuuColorBrush` creates a Brush, lazily.

**Deliberate design choices, recorded so they are not "simplified" away:**
- The row→view mapping is **pure** and returns a colour *name*, not a Brush. Creating a brush needs
  PresentationCore, which would make the mapping untestable headlessly and would drag WPF into every
  test that only wanted to check projection rules.
- `Sync-WuuViewCollection` reconciles by **key** and updates view objects **in place** rather than
  rebuilding, because rebuilding discards selection and scroll position on every tick. Verified by
  reference-equality assertion.
- The view row deliberately does **not** carry `Runspace`/`PendingOp`/operation identity - putting
  engine mechanics on a bound object invites a handler to read them off the view instead of the engine.
- `Get-WuuStatusToken` returns `[?]` for anything unrecognised. A default of `[OK]` hides exactly the
  state worth noticing.

**Two real defects the new test caught (both in the new code):**
1. `Get-WuuStatusToken` preferred `UpdatesStatus` over `State`, so the row contract's default
   `UpdatesStatus='Initializing'` masked every terminal state - `Error`, `Timeout` and `Complete` all
   rendered `[WAIT]`. Fixed by reading terminal states from `State` **first**.
2. `Sync-WuuViewCollection -Collection` was declared `Mandatory` without `AllowEmptyCollection`, so the
   **first** reconcile of an empty view threw
   `ParameterArgumentValidationErrorEmptyCollectionNotAllowed`. An empty view is the normal starting
   state, so this would have failed on every first load.

**Verified:** `tests\Test-GuiProjection.ps1`, 45 assertions, exit 0 - headless import, mapping
correctness, unknown-never-OK, reconcile add/update-in-place/remove, and key-based selection surviving
a refresh that replaces every view object. Full suite **14 PASS / 1 SKIP / 0 FAIL**; gate exit 0.

**Known coupling (for the Core-wiring step):** the worker runspaces do **not** receive the state store
- `New-ComputerRunspace` injects `uiHash` and the row objects themselves, and never `SetVariable`s
`stateStore`. So the worker twin cannot be re-pointed at the store without also injecting the store and
the operation identity. Verified by grep: there is no `stateStore` reference anywhere in
`Wuu.WindowsUpdate.psm1`. This is the same edit as T007's remaining item.

---

## SCOPE FINDING (2026-10-06) — the engine is complete but NOT WIRED INTO PRODUCTION

Measured, not inferred. Grepping every `src\*.psm1` for the engine's entry points:

| Symbol | Defined in | Called from production? |
|--------|-----------|------------------------|
| `New-WuuStateStore` | `Wuu.State.psm1:209` | **No** — exports only; no caller outside `Wuu.State` |
| `Add-WuuComputerRow` | `Wuu.State.psm1:287` | **No** |
| `Update-WuuOperationState` | `Wuu.State.psm1:879` | **No** |
| `New-WuuOperationId` | `Wuu.State.psm1:1473` | **No** — called only by `tests\Test-StateFencing.ps1` |
| `stateStore` (the variable) | `Wuu.State.psm1` comments/tests | **No** reference in `Wuu.WindowsUpdate.psm1` |
| `Wuu.Gui` projection | `Wuu.Gui.psm1` (new) | Imported, but **no caller yet** |

So the position is: `Wuu.State` supplies a complete, tested engine — row contract, mutation funnel,
identity fencing, terminal guard, deadline/heartbeat, refusal records, phase policy — and the running
application uses **none of it**. Production still stores its state in `ListView.Items` and still mutates
it in place under `Dispatcher.Invoke`. `Start-UpdateCheckJob` does not stamp an operation id, so there is
no identity for a fence to compare even if one existed in the payload.

**What this means for T006/T007.** "Core wiring" is not a wiring job; it is the migration itself:
replace ListView-as-state-database with store-backed state across `Wuu.Core`'s ~150 direct
`Listview.Items.EditItem/CommitEdit/Refresh` sites, inject the store plus operation identity into every
per-computer runspace, port the funnel into the injected twin, and only then detach the ListView to a
read-only projection. Every one of those steps is inside the same call graph, so it cannot be done as
disjoint small edits.

**Proposed staging, each step leaving the app runnable and the suite green:**

- **A — additive store.** Create the store at startup and mirror each ListView item into it (rows added
  on add, removed on remove). No behaviour change; the store becomes truthful and observable. Prove it
  with a test that compares store contents against the ListView after a synthetic fleet load.
- **B — operation identity at submission.** In `Start-UpdateCheckJob`, mint an id via
  `New-WuuOperationId`, stamp `OperationId`/`OpState`/`OpStartedAt` on the row through the funnel, and
  inject `WuuOperationId` into the runspace. Still no guard enforcement, so no behaviour change; the
  identity now exists to compare.
- **C — the twin.** Replace `SetComputerStateScript`/`SetComputerTimeoutScript` with a single injected
  funnel twin carrying the identity fence, the reset fence and the terminal guard. This is the first
  step that CHANGES behaviour, and it is the T007 deliverable.
- **D — re-point the writers.** Move `Wuu.Core`'s row mutations onto the store funnel, deleting the
  ListView mutation at each site.
- **E — projection only.** Bind the ListView to `Sync-WuuViewCollection` and make selection key-based.

Steps A and B are safe and independently testable. Step C is the payload-visible change that needs the
twin agreement test. D and E are the bulk edit.

### Step A — DONE (2026-10-06)

Delivered:
- `$global:stateStore = New-WuuStateStore` at startup; the store is handed to the job layer as
  `WuuCtx.StateStore` and injected into **every** per-computer runspace as `stateStore`.
- All **three** ListView add sites (direct, dispatched, bulk config load) and **both** remove sites
  mirror into the store. Rows are registered **by reference**, so no second copy can drift.
- `tests\Test-StateStoreMirror.ps1` — 33 assertions, exit 0.

**Two findings this step produced, both worth knowing:**

1. **Production rows are not engine-conformant.** The ListView add sites build literal property bags
   that predate the engine. Measured: `$uiA.OperationId = 'x'` on such a row **throws**
   `The property 'OperationId' cannot be found on this object`. So the moment the store mirrored them,
   the identity fence, the colour helper and the heartbeat writer all had properties they could not
   write — inside a payload's `catch`, and therefore silently. **A fence that cannot run is not a
   fence.** Fixed with `Set-WuuRowEngineDefaults` (`Wuu.State`), an explicit, additive backfill that
   adds only missing properties and never overwrites a value, called at each mirror site *before*
   registration. It is deliberately NOT hidden inside `Add-WuuComputerRow`: registering a row and
   re-shaping it are different acts, and a side effect that rewrites the caller's object surprises
   readers later.
2. **A second copy cannot be allowed to drift.** The mirror's safety rests on reference identity, so
   the test asserts `ReferenceEquals` between the store row and the UI row rather than comparing
   fields. Field comparison would pass with a copy and fail only much later, in the fence.

Step B is next: `Start-UpdateCheckJob` must mint an identity and inject it, or step C's fence has
nothing to compare against.

### Step B — DONE (2026-10-06)

Delivered:
- `Start-UpdateCheckJob` mints an id via `New-WuuOperationId`, **injects it as `$WuuOperationId` into
  the per-computer runspace before `BeginInvoke`** (so payloads can attribute their writes), and
  carries it on the job record.
- The row is stamped through the **funnel** (`-OperationIdNew ... -OpState 'Running' -OpStartedAt
  (Get-Date) -OpName $Op`), not by direct assignment — the funnel is the only writer permitted to set
  those fields, and it clears stale `LastReset*` markers as part of taking the row.
- The **cleanup loop** now releases the identity on **both** completion and timeout, and the store is
  injected into the cleanup runspace so it can do so. The release is **identity-guarded**: a
  superseded job must not clear its replacement's id, which is the same stale-writer rule applied to
  the release path.
- `tests\Test-OperationIdentityLifecycle.ps1` — 30 assertions, exit 0.

**Why the release is not optional.** Stamping `OpState='Running'` and retiring it only at reset would
leave every row permanently busy, and `Test-WuuOperationStateInvariant` reports exactly that as
`settled row ('X') still holds the runspace lock`. A fence is only usable if the lock it takes is also
given back, so both halves are asserted.

**Behaviour neutrality, and the condition on it.** Nothing in production consults the admission gate
yet (`Test-WuuComputerBusy` is exported with no production caller — verified), so stamping changes
nothing observable. **Do not add an admission-gate caller before the release path is exercised in
anger**, or a finished job would strand its row.

**Four wrong API assumptions in my own test, corrected against the real contracts** (probed, not
guessed) — recorded because each is the kind of thing that makes a test assert the wrong thing:
1. `OpStartedAt` is passed by the CALLER; the funnel does not invent a start time. My test asserted it
   was recorded without passing it.
2. `Test-WuuOperationStateInvariant` takes `-Row` (singular). My test passed `-Rows`, the parameter
   binding error was counted as a violation, and a malformed call was reported as a finding — an
   assertion failing for the wrong reason.
3. `New-WuuResetOperationContext -Source` is a `ValidateSet`
   (`SubmissionFailure|PhaseWaitBookkeeping|OperatorReset`). My test passed `'Test'`.
4. `Test-WuuComputerBusy` consults **`Pending` as well as `OpState`**, and `Pending` is a *different*
   signal — the "a follow-up is queued" flag owned by T011, not by this step. The suite now uses
   `-IgnorePending` to isolate the `OpState` question, and the row keeps `Pending` untouched.

Step C is next: replace the two unfenced state helpers in the payload with a twin of the funnel.

### Step C — DONE (2026-10-07) — the first step that changes real behaviour

`SetComputerStateScript` and `SetComputerTimeoutScript` in `New-ComputerRunspace` are now **fenced twins
of the funnel**. Each carries, in the same order as `Update-WuuOperationState`:

1. **identity** — refuse only a proven staleness (the row names an operation and this runspace is
   running a different one); an unattributed write stays permitted, or row population would be discarded;
2. **reset fence** — a writer whose operation was reset is refused;
3. **terminal guard** — a settled `Error`/`Timeout`/`Complete` row is not rewritten by a bare
   transition. An explicit `-OperationId` argument *is* the new attribution, which keeps a retry legal;
4. **live-row check** — a row removed from the store is not written to (writing to a deleted row is a
   leak, not a write).

They also **no longer touch the ListView**: the old bodies mutated the row through
`Items.EditItem/CommitEdit` and set `$listViewItem.Background` directly. They now write the row and
signal a redraw via `$stateStore.Touch()`, which is the engine/view decoupling this uplift exists for.

`tests\Test-WorkerTwinFence.ps1` — **37 assertions**, exit 0. It extracts the twins from the **live
injection site** (brace-walked out of `Wuu.WindowsUpdate.psm1`) rather than accepting a copy pasted into
the test, and it asserts the copies **AGREE** with the module funnel on identical rows — stale write,
attributed retry, and adoption-over-Running. A test of one copy alone cannot notice a divergence, which
is exactly the C2 defect in the CLI edition.

**Finding: the retry required step B to exist.** Adopting over a row whose `OpState` is still `Running`
is refused — `cannot adopt 'op-NEW': the row is Running under 'op-OLD'` — by *both* copies. So the
permitted sequence is **settle → release → adopt**:

```
settle   State='Error',  OpState='Running', OperationId='op-A'
release  State='Error',  OpState='Idle',    OperationId=''      <- the cleanup loop, step B
adopt    State='Searching', OperationId='op-B'                  <- permitted
```

An earlier version of the test skipped the release and expected the retry to be allowed; both copies
refused, and *agreeing on the refusal* was the property that mattered. Recorded because it shows why the
staging order was not optional: without step B's release, no computer could ever be retried after a
failure, and `Test-WuuOperationStateInvariant` already flags the intermediate state as
`settled row ('Error') still holds the runspace lock`. The GUI now also has the main-vs-worker agreement
test the CLI has had since `Test-WorkerIdentityFence` — previously it had none.

Steps D/E remain: re-point `Wuu.Core`'s ~150 ListView mutation sites at the store funnel, then bind the
ListView to `Sync-WuuViewCollection` and make selection key-based.





### T007 [R02,R03] Identity-fenced state writes + one admission critical section — STATE LAYER DONE
- [x] State writes are fenced by OPERATION IDENTITY (refuse only PROVEN staleness; unattributed writes permitted), plus the terminal-transition guard, in ONE place (`Wuu.State`).
- [x] The injected worker twin in `src\Wuu.WindowsUpdate.psm1` must mirror the funnel exactly (identity incl. `LastResetOperationId`, terminal guard, ClearOperation). **DONE (2026-07..2026-10, verified 2026-10-10):** all seven injected twins (`SetComputerStateScript`, `SetComputerTimeoutScript`, `SetComputerFencedFieldsScript`, `SetPendingOpScript`, `SetCleanupTimeoutScript`, `SafeUpdateListViewItemScript`, `RemoveComputerRowScript`, plus `TestEffectAuthorizedScript`) carry the identity / reset / terminal / live-row rules, and `tests\Test-WorkerTwinFence.ps1` drives the REAL factory runspaces and asserts the module and twin copies AGREE (155 assertions).
- [x] Implement the ONE genuine critical section around ADMISSION CAPACITY (`Enter-`/`Exit-WuuSubmissionLock` with a capacity re-test before the slot append).
- [x] No second terminal-state list (single source: `Wuu.State`).
- [x] NEW `tests\Test-StateFencing.ps1` (29 assertions, PASS): identity fencing, adopt-over-running refusal, reset fencing, terminal protection, retry-by-new-operation, ClearOperation terminal protection, install-error masking, and REAL 4-runspace admission-lock exclusion (160 entries, max concurrency 1, 0 violations).
Pass criteria: real multi-runspace test proves cap exclusion — MET; stale/reset/terminal refusals proven in the main funnel — MET; the injected-twin agreement test is PENDING with the twin.

### T008 [R01,R03] DispatcherTimer as coordinator, not blocker - DONE (2026-10-10)
- [x] Keep the DispatcherTimer (UI thread) as a bounded coordinator driving scheduling reads/snapshots; it must never block the UI thread on remote calls. **DONE:** the tick runs `Start-PendingUpdateCheck` (bounded, no remote call) then `Update-WuuProjection` (one gate-guarded reconcile, skips on a busy gate) - never a remote call or a dispatcher wait.
- [x] Classify existing `Dispatcher.Invoke` callbacks first: move engine mutations/readback out of presentation callbacks, then make only IMMUTABLE projections asynchronous and coalesced (`BeginInvoke` at an appropriate priority). Include operation/revision checks so a late projection cannot display an old operation over a new one. **DONE:** the projection is revision-gated (`Test-GuiProjection` sections 7/8/9); the cleanup loop paints the STORE row with no Dispatcher hop (T008.2); engine mutations happen on the engine row and reach the view only through the reconcile.
- [x] Define the nonblocking scheduler interface here; production wiring completes in T011. Phase 1 tests may use a fake coordinator. **DONE:** `Start-PendingUpdateCheck` is the interface, wired through `Start-UpdateCheckJob`'s admitted path (T011.1/T011.2).
Pass criteria: simulated slow UI + busy workers shows workers continue and updates coalesce; no deadlock on close; prompts, drag/resize and row updates still work. - **bounded shutdown + no-dispatcher-hop cleanup proven (T008.2); headless suites green.**

## Phase 1 gate
1. Headless state import (no WPF) verified.
2. Main/worker funnel agreement test passes; the admission lock provably excludes across real runspaces.
3. No engine read of WPF controls; selection survives sort/filter.
4. Timer drives scheduling without blocking; no worker awaits UI.
Then Phases 2 and 3 may start.
