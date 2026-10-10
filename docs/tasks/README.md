# WUU2 Engine and GUI Uplift — LLM Task Index

## Validation Status
For the completed 2026-10-08 remediation, read [the remediation plan](remediation-plan-20261008.md)
(all items `[x]`) and its evidence in [phase-1-evidence.md](phase-1-evidence.md). It supersedes the earlier
Step D execution proposal and the blanket ban on short state-mutation critical sections. The remediation
is complete and headlessly green (20 suites, 20 PASS / 1 SKIP / 0 FAIL; gate exit 0), and an independent
adversarial review (T025.1) was run and dispositioned. Two release gates remain OPERATOR-ONLY (they need
elevation / a live desktop): the elevated interactive smoke test and the disposable-host lab. Run them
from [the operator handoff runbook](operator-handoff-20261010.md). No waiver is claimed for them.

The broader UPLIFT phases (shared-config v2, fleet workspace, audit trail, regression/release) are a
separate, largely-unstarted build (they require modules that do not exist yet: `Wuu.Config`, `Wuu.Audit`,
`Wuu.Scheduler`); their checkboxes are genuinely open, not stale.

The phase sequence is appropriate; execution must use the binding corrections in `docs/tasks/validation.md`. Read that document before the phase files: it supersedes conflicting task wording, adds dependency/gate details and corrects engine/WPF, synchronization, configuration and audit boundaries. No runtime baseline is certified. Elevation is required only for tasks whose environment demands it, not every headless test. CLI shell imports remain excluded, but headless audit orchestration in `Wuu.Command` may be read as a reference.

This task pack implements the WUU2 (GUI) uplift from the WUU2-CLI donor repository, derived from the approved plan (2026-10-05/06, user decisions: reliability+security+audit+reporting, GUI redesign to fleet workspace with deployment review, shared config format, system-aware accessible themes).

- Target repo: C:\Users\dazzo\OneDrive\GitHub\WUU2
- Donor repo (read-only): C:\Users\dazzo\OneDrive\GitHub\WUU2-CLI
- Defects found so far (severity, evidence, fixed/open status): `docs/DEFECTS_FOUND_20261006.md`.
  Still OPEN: D7 (no version constant) is now FIXED (`$global:WuuVersion` in `Wuu.Configuration`); D4
  (packaging ships operator data) is FIXED (the packager excludes it and fails closed on a leak). D1 (CIM success masking)
  is fixed in both editions, but read `docs/DEFECTS_FOUND_20261006.md` §D1a first: the first fix broke
  every probe and the incident shows why a live happy-path probe is required. The donor has advanced
  to `v1.5.0-rc.3-cli`, independently verified clean (58 PASS / 1 SKIP / 0 FAIL, gate exit 0) — see
  `WUU2-CLI/docs/DEFECTS_AND_COVERAGE_20261006.md` §8.5. Re-baseline against that tag before promoting
  anything further from the donor.

## How an implementing LLM uses a task file
1. Read `docs/tasks/validation.md` first (binding corrections).
2. Read the phase task file.
3. Read the Inputs listed there (target + donor files with symbols).
4. Execute tasks in order, check each `- [ ]`, record evidence in `docs/tasks/phase-N-evidence.md`.
5. Validate with the listed verification commands; do not proceed past a failed phase gate.

## Binding rules for every task
- Windows PowerShell 5.1, STA. PS7 compat patterns (Get-CimInstance, Invoke-Command). Elevation only where the task requires it.
- Background→UI updates only via the owning control's Dispatcher. Never touch WPF off the UI thread.
- Injected scriptblocks must be unbound: `[scriptblock]::Create($sb.ToString())`.
- WUA COM stays in-process; nested `[powershell]::Create()` + BeginInvoke polling; Dispose all paths; `Runspace.Close()`+`Dispose()` separately.
- Never edit snapshots/backup files (`WUU_backup*`, `WUU_debug*`, `WUU_perplexity*`, `WUU_git_version*`, `WUU_v1.1*`), `dist/`, real `ComputerList.config`, logs, inventories. No auto commit/branch/push/tag/release.
- Donor repo is read-only. CLI-only modules (Command/Console/Navigate/Presentation/Actions.Display) are never candidates for import; `Wuu.Command` headless audit logic may be read as a behavioural reference only.

## Phase task files
- 0: `phase-0-baseline.md` — Baselines and promotion gate (blocks all)
- 1: `phase-1-state-foundation.md` — State foundation + WPF bridge (needs P0)
- 2: `phase-2-engine-lifecycle.md` — Credentials, remote results, lifecycle (needs P1)
- 3: `phase-3-shared-config.md` — Shared computer-list config (needs P1; parallel w/ P2)
- 4: `phase-4-audit-reporting.md` — Audit + read-only reporting (needs P1+P2)
- 5: `phase-5-fleet-workspace.md` — Fleet workspace + deployment review redesign (needs P1; layout parallel w/ P2-P4)
- 6: `phase-6-regression-release.md` — Regression, packaging, rollout (all gates)
- `validation.md` — binding corrections that override conflicting task wording

## Requirement key
R01 GUI/runtime retention | R02 state/result correctness | R03 bounded lifecycle | R04 credential identity/secrets | R05 shared config | R06 audit | R07 GUI/report/accessibility | R08 verified release

## Traceability
R01: T003-T008,T020,T025-T030 | R02: T002,T005-T007,T010-T013,T021-T022,T025,T030 | R03: T002-T003,T007-T008,T010-T013,T025,T028-T029 | R04: T009,T014,T025,T028 | R05: T014-T016,T025,T030 | R06: T017-T018,T022,T025,T028,T030 | R07: T019-T024,T029-T030 | R08: T001,T003-T004,T025-T030
