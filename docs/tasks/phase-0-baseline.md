# Phase 0 — Baselines and Promotion Gate (T001-T004)

Binding validation corrections: read `docs/tasks/validation.md`, section 'Phase 0 Corrections', before execution. Those corrections supersede conflicting instructions below, including current-version discovery, broader donor behavioural checks, successful runspace reuse, bounded baseline probes and measurable capability/performance evidence.

Status: **PASS** (2026-10-06). Evidence: `docs\tasks\phase-0-evidence.md`. Requirements covered: R01, R02, R03, R08.

## Goal
Establish reproducible baselines for BOTH repos, accept a specific donor revision, and reconcile WUU2's instructions with its real modular architecture. No production behaviour changes in this phase beyond instruction/test-runner documentation.

## Inputs (read these first)
Target (WUU2):
- `C:\Users\dazzo\OneDrive\GitHub\WUU2\.github\copilot-instructions.md`
- `C:\Users\dazzo\OneDrive\GitHub\WUU2\.github\instructions\powershell.instructions.md`
- `C:\Users\dazzo\OneDrive\GitHub\WUU2\src\Wuu.Core.psm1` (Import-WuuModules; Start-WuuApplication)
- `C:\Users\dazzo\OneDrive\GitHub\WUU2\Scripts\Validate-Release.ps1`
- `C:\Users\dazzo\OneDrive\GitHub\WUU2\tests\*` (Test-AutoFlowChain, Test-ColumnResize, Test-CredentialTyping, Test-CrossModuleResolution, Test-DragResize, Test-LogFaultTolerance, Test-ModuleImport, Test-PendingDrain, Test-RemoteHelpers, Test-RemoteTask, Test-WorkerPool)
Donor (WUU2-CLI, read-only):
- `C:\Users\dazzo\OneDrive\GitHub\WUU2-CLI\Scripts\Validate-Release.ps1`
- `C:\Users\dazzo\OneDrive\GitHub\WUU2-CLI\Scripts\Invoke-TestSuites.ps1`
- `C:\Users\dazzo\OneDrive\GitHub\WUU2-CLI\tests\Test-InstallOutcome.ps1`, `Test-WorkerIdentityFence.ps1`, `Test-WuuOperationState.ps1`

## Tasks

### T001 [R08] Record baselines without touching live config — DONE (evidence)
- [x] Capture `git rev-parse HEAD` and `git status --porcelain` for BOTH repos. Preserve all dirty files.
- [x] Hash donor candidate files to be copied (State, Credentials, Scheduler, WindowsUpdate, Workers, Audit, Reporting, Configuration, Remote, Network, Result, Download-Patches.ps1, Install-Patches.ps1).
- [x] Record donor version literal; confirm target's own version source. Do NOT transplant the CLI version string into the GUI.
- [x] Write evidence to `docs\tasks\phase-0-evidence.md`.
Pass criteria: donor files hashed; no donor or target file modified except new evidence doc.

### T002 [R02,R03] Behaviourally validate the six donor failure paths (read-only on donor)
Run each as a local probe under Windows PowerShell 5.1 STA. Confirm CURRENT donor behaviour.
- [x] Install errors not masked: donor `Test-InstallOutcome` / `Test-TargetOutcomes` PASS.
- [x] Main vs worker reset fencing: donor `Test-WorkerIdentityFence` PASS.
- [x] Refusal-safe queue: donor `Test-PendingPolicy` PASS.
- [x] Cleanup retires identity: donor `Test-CleanupIdentityRetire` PASS.
- [x] Implicit Phase transition: donor `Test-TerminalStates` / `Test-WuuOperationState` PASS.
- [x] ClearOperation + PendingOp on a terminal row: donor `Test-TerminalStates` PASS.
- [x] Concurrency cap: donor `Test-ConcurrencyCap` / `Test-SubmissionAtomicity` PASS.
Pass criteria: record actual outcome per probe in `phase-0-evidence.md`. Any failing behaviour BLOCKS the corresponding Phase-1/2 transplant until repaired in a separately scoped task or implemented correctly in the target.
Result: **14/14 donor probe suites PASS**; donor release gate exit 0. No blocked transplant.

### T003 [R01,R08] Establish the target (WUU2) test baseline
- [x] Run the target gate: `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1` from `C:\Users\dazzo\OneDrive\GitHub\WUU2`. Record PASS/FAIL/WARN/SKIP. -> exit 0, all checks passed.
- [x] Run each applicable target suite in a bounded child process (timeout per suite), capturing exit code and seconds. Do NOT blanket-exclude `Test-ColumnResize`/`Test-DragResize`; classify headless vs interactive-desktop vs elevated. -> PASS 7, SKIP 1, STALE 3.
- [x] Record results (suite, exit code, seconds, notes) in `phase-0-evidence.md`.
- [x] Record retained capability inventory from `ui\MainWindow.xaml` (37 wired controls + 8 grid columns) in `phase-0-evidence.md`.
- [ ] Record baseline screenshots with synthetic rows and the numerical regression budgets used by T029.
Pass criteria: a defensible "what is green today" list for WUU2; no historical counts reused.

### T004 [R01,R08] Reconcile instructions and add a GUI-specific runner
- [x] Update `.github\copilot-instructions.md` to the REAL architecture: modules, `ui\MainWindow.xaml` + dialogs, `tests\`, and the import path through `Import-WuuModules`. Remove claims that `WUU.ps1` is the sole editable code file or that root XAML files exist.
- [x] Update `.github\instructions\powershell.instructions.md` only where it is now wrong.
- [x] Add `Scripts\Invoke-TestSuites.ps1` to WUU2 modelled on the CLI runner: child-process per suite, exit-code capture, per-suite timeout, SKIP vs PASS classification, GUI-appropriate exclusions.
- [x] Prove the runner can FAIL using an isolated disposable probe suite; do not mutate user suites or real operator data.
Pass criteria: instructions match the tree; runner exists, aggregates, distinguishes skip, and can fail.

## Phase 0 gate (must all pass) — VERDICT: PASS (2026-10-06)
1. `phase-0-evidence.md` records HEADs, hashes, donor probe verdicts, target baseline results. — DONE
2. Donor fixtures accepted at a recorded revision; any blocked transplant explicitly named. — DONE (none blocked)
3. WUU2 instructions reconciled; new runner proven to fail on a failing suite. — DONE
4. No donor or unrelated dirty target file was modified. — DONE

## Reporting
Phase 0 outcome: gate PASS. Three suites are STALE (fixture removed by the module split) and must be
repaired in T025, not dropped. The target has no version constant — T005 must add one.
