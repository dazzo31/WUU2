# WUU2 GUI Uplift: Phase Validation and Binding Corrections

Status: phase structure appropriate; original task wording requires the corrections below before implementation. Application implementation has not started. No fresh runtime, lab or desktop tests were executed for this assessment.

This document overrides conflicting wording in the seven phase task files and the comprehensive plan. Read it before executing any task. Retain T001-T030 and R01-R08; do not invent replacement task IDs. Checkboxes remain proposed, not completed. This is a semantic plan/task review, not a formal modernization pipeline gate: no supplied constitution/spec/checkpoint package was certified.

## Evidence and Assessment

- Existing GUI ownership includes Core event wiring, credential/OU dialogs and dispatcher-driven projections. Requiring all WPF references to live in `Wuu.Gui` contradicts retained architecture.
- `Wuu.State` in the donor includes submission-lock helpers with an explicit `Gate` parameter. Its documentation warns that module imports in separate runspaces create separate module-local gates. A submission-cap lock is not automatically the state mutation lock.
- Shared persistence belongs to `Wuu.Credentials`; GUI prompts remain presentation code. Legacy SecureString encryption is not authenticated, so wrong password and corrupt ciphertext cannot always be distinguished reliably.
- The target has **no application version constant**; the donor single-sources `$global:WuuVersion = 'v1.5.0-rc.1-cli'` in `Wuu.Configuration`. The target must introduce its own version source (do not transplant the CLI literal).

## Phase 0 Corrections: T001-T004

1. T001: discover current versions rather than require a hard-coded CLI literal. Hash every selected donor payload and helper, including remote scripts, Remote/Network and any Result/export helpers actually reused. Dirty file hashes are part of provenance; HEAD alone is insufficient.
2. T002: run the current donor release gate and aggregate runner as specified in the comprehensive plan, plus focused behavioural probes. Add retry after old InstallErrors, clean outcome on new admission, follow-up enqueue during acceptance and real concurrent cap enforcement. Historical totals/source regexes alone do not establish promotion safety.
3. T002 cleanup criterion: successful completion may retain an idle reusable runspace. Require retired operation identity and no leaked retired handles; timeout/failure/removal/shutdown follow explicit disposal policy. Do not require `Runspace=$null` for every successful job.
4. T003: run suites in bounded child processes even before T004 exists, using a read-only harness. Classify headless, interactive desktop, elevated and remote/lab requirements; record timeouts and skips separately. Baseline may contain documented pre-existing failures, but selected donor contracts may not have unexplained failures.
5. T003: record retained capability inventory and baseline screenshots using synthetic rows. Record reproducible startup/render/filter/selection measurements, environment and numerical regression budgets before redesign; absent measurements block a claim of 'no regression'.
6. T004: test runner failure/timeout/skip behaviour through isolated disposable fixtures. Do not mutate user suites or real operator data.

Gate: reproducible provenance and test evidence, capability inventory, bounded runner and disposition of every selected transplant. An affected unsafe transplant blocks dependent work, not unrelated read-only research.

## Phase 1 Corrections: T005-T008

1. T005: retain GUI product identity. Record a defaults table separating unchanged GUI settings from explicit safer policy changes already in scope, including BlockOnFailure. Do not silently transplant CLI defaults. Resolve actual import dependencies before initialization rather than enforce an unverified fixed import order.
2. T006/T026: `State`, `Configuration`, `Scheduler` and headless engine/helper payloads must not load/access WPF. `Wuu.Gui` owns projections/themes; Core and existing presentation/dialog code may retain WPF access on the owning dispatcher. Never inject controls, brushes or UI collections into engine workers.
3. T007: state writes are fenced by OPERATION IDENTITY, not by a coarse lock. The donor rule (verified in `Wuu.State` + the injected worker twin) is: refuse only a PROVEN staleness - the row names an `OperationId`/`LastResetOperationId` and the writer names a different one - plus a terminal-transition guard. An unattributed write is permitted (row population has no operation). The rule must be IDENTICAL in the main funnel and the worker twin, proven by an AST/behaviour agreement test. Do NOT add a coarse state-mutation lock: it would have to be held across remote calls/UI dispatch, and a lock held by a blocked payload would freeze admission for the whole app. This corrects an earlier note in this document that wrongly demanded one shared mutation lock.
4. T007/T011: the ONE genuine shared critical section is the ADMISSION-CAP reservation (`Enter-WuuSubmissionLock`/`Exit-WuuSubmissionLock` around a capacity re-test immediately before the job-entry append). It must be reachable from every admission caller; module scope is acceptable only because the app imports modules `-Global` exactly once, and tests must pass a shared gate explicitly (module-scope state is per RUNSPACE - a test that imports the module N times proves nothing). Never hold it across remote calls, dispatcher waits, dialogs or durable audit I/O.
5. T008: classify existing dispatcher callbacks before changing them. Move engine mutations/readback out of presentation callbacks first; only immutable projections are asynchronously coalesced. Include operation/revision checks so late projections cannot display an old operation over a new one. Do not globally substitute `Invoke` with `BeginInvoke`.
6. T008: define the nonblocking scheduler interface here; production scheduler wiring completes in T011. Phase 1 tests can use a fake coordinator without requiring the Phase 2 module to exist.

Gate: headless boundary, identity-fencing agreement between main and worker writers, real shared-gate cap exclusion, coherent snapshots and revision-safe projection, bounded UI coordination, stable selection and close/prompt responsiveness.

## Phase 2 Corrections: T009-T013

1. T009 target is `WUU2\src\Wuu.Credentials.psm1`, not `Wuu.Credentials.ps1`.
2. T010: preserve `Result`/`ExitCode`/`InstallErrors` and `RebootRequired` independently; drive the real injected install result-handling path with mocks, not classifiers alone.
3. T011: unify all target operation/action submission paths that affect engine state, not unrelated AD discovery, UI infrastructure or read-only auxiliary runspaces merely because they call BeginInvoke. Each remaining auxiliary worker still has bounded cleanup and UI safety.
4. T011: accepted submission must not erase a newer pending request queued during admission. Queue requests have stable identity/revision; consume only the accepted request. Failed reservations roll back only their own claim.
5. T012/T013: document reusable-idle versus retired runspace policy. Shutdown stops scheduling, bounds drain, guards late writers and closes/disposes owned retired resources exactly once. Preserve uncertainty if remote SYSTEM tasks may continue; do not report local disposal as confirmed remote cancellation.
6. T013: refusal/stall detection does not convert capacity refusal into target failure. Phase policy and retry clearing stale outcome get focused behavioural tests during this phase.

Gate: real concurrency, reset/replacement, pending enqueue/refusal, install/reboot, credential, phase-policy and shutdown checks; not merely matching source patterns.

## Phase 3 Corrections: T014-T016

1. T014 ports headless storage/policy functions only. Do not transplant CLI console prompt workflows. T015 adapts existing WPF password/name/overwrite dialogs and calls those policies.
2. T014 owns validation, merge, encrypted temp-file write, protected legacy backup and safe same-volume replacement with rollback. GUI handlers must not implement a second writer. Fault injection proves the original survives encryption/write/replace failure; temporary artifacts are cleaned up safely.
3. Validate v2 `Schema` and document shape, list names, counts, row fields and credential metadata explicitly. Accept legacy only by its documented shape; reject unknown/malformed documents rather than treating `Lists` presence as valid v2. Match actual donor naming/case/default conventions.
4. Replace message-pattern certainty with an honest error contract: file access/busy, unknown schema/invalid structure, or decryption failure ('incorrect passphrase or damaged file') when those causes cannot be separated. Wrong-passphrase fixtures must fail without modification; do not claim reliable corruption-versus-password diagnosis from padding messages.
5. Stage an entire load before committing the engine inventory under the state protocol. Failure/cancel leaves disk and fleet unchanged; no partial import.
6. T016: separate-process bidirectional tests assert loaded module paths, real schema metadata, no secrets/transient fields, non-destructive migration and writer fault rollback. Shared wire format only; simultaneous cross-edition writers remain unsupported.

Gate: valid current schema in both directions, legacy read without rewrite, safe explicit migration and truthful failures.

## Phase 4 Corrections: T017-T019

1. T017 classifies each action: target mutation, local configuration/inventory mutation, read-only access, authorization denial and outcome. A cancelled/denied review does not imply a mutation was performed. Intent records precede effects; accepted/refused/outcome records retain stable request/operation correlation. Audit admission refusal is not machine failure.
2. T017 consumes a UI-independent confirmed-request/reason contract. T022 supplies the production dialog later; use a stub request provider for Phase 4 tests. This removes the apparent Phase 4-to-5 dependency cycle.
3. Pure audit work depends on Phases 1-2; auditing actual config actions additionally depends on Phase 3. Production integration gate must wait for both, while pure primitives can proceed earlier.
4. T018: `Wuu.Audit` owns headless verify/anchor/export services; `Wuu.Gui` owns WPF actions and rendering. Do not leave service ownership as 'Gui OR Audit'. Define the export schema/version contract here, either through selected headless Result helpers or an existing suitable utility; do not import CLI Command/console rendering.
5. GUI evidence export includes only evidence actually captured. WPF interactions are not recorded automatically by a terminal transcript; missing/optional diagnostic capture is explicit. Do not fabricate transcripts, target durations or compliance figures.
6. T019 returns plain report/view-model data, not WPF controls/brushes. Aggregation never changes source trail. Optional best-effort access logging belongs to the UI/service wrapper and is excluded from report outcome counts; therefore do not claim the entire report action performs no writes.

Gate: durable fail-closed intent before effects, correlated accepted/refused/outcomes, secret-negative fixtures, combined chain/anchor verdicts, correct manifests and accurate pure aggregations.

## Phase 5 Corrections: T020-T024

1. Layout/resources may parallel Phases 2-4 after Phase 1 interfaces are stable. Live mutation wiring waits for engine, config and audit integration gates. Preview remains non-mutating; confirmation revalidates the reviewed target snapshot and authorization before effects.
2. T020/T026: validate resolvable x:Names and intended event/command wiring for interactive controls; passive controls need no handler. Shared commands across toolbar/menu/context controls are valid. Detect accidental duplicate subscriptions, not multiple legitimate callers.
3. T021: stale telemetry is explicit and actions revalidate current engine state. Do not indiscriminately disable inspection or all interaction on a stale heartbeat.
4. T022: cancellation, refusal, queued/running and uncertain remote continuation must be distinct. Automated follow-ups inherit only the authorized scope, reason and correlation.
5. T023: use WPF system high-contrast resources, accessible text/names/focus and glyph assets available on supported Windows versions; source encoding must remain PS5.1-safe. Verify contrast and keyboard/Narrator behaviour, not palette names alone.

Gate: every retained capability reachable, no submission/audit bypass, stable selection and accurate outcomes, accessibility/DPI and desktop responsiveness evidence.

## Phase 6 Corrections: T025-T030

1. Tests are authored and run with each earlier behavioural change. T025 integrates coverage and fills demonstrated gaps; it is not the first testing phase.
2. T025/T026: prioritize behavioural/race/fault tests for the highest-risk boundaries. Prove runner and critical guards can fail using isolated reversible fixtures; 'mutation-proof every suite and every gate' is not a blanket requirement and must not cause edits to unrelated user code.
3. T026 follows the corrected engine-versus-presentation WPF boundary and event/command contract, not 'only Gui references WPF' or 'one handler for every control'.
4. T028: remote/lab and Event Log tests state elevation/environment requirements case by case. Headless unit/config tests are not globally administrator-only. Unverified critical remote/audit behaviour remains a release blocker unless explicitly waived by the user; naming a skip alone is not sign-off.
5. T029 compares reproducible measured scenarios against the Phase 0 numerical budgets. GUI-specific legacy tests are applicable only if their prerequisites and behaviour are meaningful; disclose exclusions and substitute equivalent desktop evidence. No unmeasured 'no regression' claim.
6. T027/T030: clean package inspection and unpacked startup are required. No automatic commit/tag/push/release; preserve protected config backups and audit evidence through rollback.

Gate: integrated suite/gate results, clean unpacked package, required disposable-host and WPF desktop evidence, honest skips/limitations and user-controlled release approval.

## Execution Dependencies

- Phase 0 blocks implementation. Phase 1 establishes headless contracts and projection.
- Phases 2 and 3 may parallel only with non-overlapping file ownership; serialize changes to `Wuu.Credentials` and `Wuu.Core`.
- Phase 4 pure services follow Phases 1-2; config-audit integration also waits for Phase 3. Phase 5 layout can parallel; production action wiring waits for Phases 2-4.
- Phase 6 integrates all prior evidence; focused checks are required in every phase.
- For each task record its phase/plan item, R requirement(s), full target/donor paths and source symbols, prerequisite task IDs, owned files, focused command/fixture and expected behaviour, evidence output, stop criteria and result.
- README exclusion of CLI shell modules means do not import/copy their presentation/parser. Reading `Wuu.Command`'s headless audit orchestration as a behaviour reference remains allowed.
