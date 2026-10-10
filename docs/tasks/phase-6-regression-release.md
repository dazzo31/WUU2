# Phase 6 — Regression, Packaging and Rollout (T025-T030)

Binding validation corrections: read `docs/tasks/validation.md`, section 'Phase 6 Corrections', before execution. Those corrections supersede conflicting instructions below: test each change in its owning phase, use risk-scoped isolated failure probes, apply the correct WPF boundary, compare measured budgets and treat unverified critical behaviour as blocking unless explicitly waived.

Status: proposed. Depends on all earlier phase gates PASS. Requirements covered: R01-R08.

## Goal
Prove the uplifted GUI, package a release candidate without leaked operator data, and document what was and was not verified.

## Inputs
Target: all modules modified in Phases 0-5; `Scripts\Validate-Release.ps1`; `Scripts\Package-WUU2.ps1`; `Scripts\Invoke-TestSuites.ps1` (from Phase 0 T004); `README.md`; `docs\`.
Donor (read-only): `tests\Test-WuuOperationState.ps1`, `Test-OperationIdentity.ps1`, `Test-WorkerIdentityFence.ps1`, `Test-ConcurrencyCap.ps1`, `Test-PendingPolicy.ps1`, `Test-OperationTimeouts.ps1`, `Test-PhaseWorkflowState.ps1`, `Test-CredentialDeterminism.ps1`, `Test-InstallOutcome.ps1`, `Test-AuditAnchoring.ps1`, `Test-AuditTrail.ps1`, `Test-AuditConcurrency.ps1`, `Test-Reporting.ps1` (adapt patterns, don't assume complete coverage).

## Tasks

### T025 [R01-R08] Expand the target test suite
- [ ] Port the relevant donor suites with GUI-adapted fixtures, keeping each suite's failure-driving property (assertion lines, not symbol mentions).
- [ ] Fill demonstrated gaps with behavioural/race/fault tests for the highest-risk boundaries; add only NEW tests for parts with no donor analogue (Wuu.Gui projection/selection, theme switching, deployment-review gating, shared-config interop, audit GUI verbs).
- [ ] Where feasible prove a suite can fail via an isolated reversible fixture (mutate -> fail -> restore -> pass); 'mutation-proof every suite' is NOT a blanket requirement and must not edit unrelated user code.
Pass criteria: per-suite child-process run reports PASS/SKIP/FAIL + assertion counts; skips are not quoted as coverage.

### T026 [R01][R08] Extend the target release gate
- [ ] Parse/import/PS 5.1 checks; non-ASCII sources carry UTF-8 BOM; interchange/audit artefacts stay BOM-less.
- [ ] Headless-state-import check (engine modules — State/Configuration/Scheduler — load no WPF); `Wuu.Gui` is the WPF-adapter module.
- [ ] Validate interactive controls' x:Name resolves with intended event/command wiring; no accidental duplicate subscriptions (shared commands allowed).
- [ ] Canonical terminal/outcome contracts single-sourced (no second terminal list); funnel reached by main/worker/cleanup paths (structural + behaviour checks).
- [ ] Donor-source provenance block: the transplanted revision (from Phase 0 evidence) is recorded.
- [ ] Package/runtime dependency check: no new binary/package required at runtime.
Pass criteria: gate exit 0; critical gates have a tautology-proof (breaking the protected pattern makes it fail).

### T027 [R01][R08] Safe packaging
- [ ] `Scripts\Package-WUU2.ps1`: REMOVE `ComputerList.config` (operator data) from `$include`; exclude real inventories, credentials, debug logs and historical snapshots (`WUU_backup*`, `WUU_debug*.log`, `WUU_perplexity*`, `WUU_v1.1*`); INCLUDE new runtime modules, theme dictionaries and docs.
- [ ] Package into a clean disposable staging dir; INSPECT the zip entries; unpack elsewhere and launch the unpacked app (without `.git`).
- [ ] Keep LICENSE/NOTICE attribution intact (upstream PoshPAIG->WUU->WUU2 lineage).
Pass criteria: zip contains no `ComputerList.config`/logs/snapshots; unpacked copy starts and reaches the main window; entry count asserted.

### T028 [R01-R08] Lab validation (disposable targets only)
- [ ] On disposable Windows hosts: check/download/install/reboot/recheck; selected-vs-all; phase failure policies; custom-cred rejection (no fallback); service actions; target dropout mid-run; partial install error with RebootRequired; remote SYSTEM task cleanup.
- [ ] No production machines. State elevation/environment requirements case by case; Headless unit/config tests are NOT globally administrator-only. An Event Log anchoring roundtrip needs one-time elevation — if not elevated, record as SKIPPED (not verified).
- [ ] Record per-case evidence (expected vs observed, audit records produced).
Pass criteria: failures surface as failures; audit intent/outcome pairs exist per mutation; tasks cleaned up. Unverified CRITICAL remote/audit behaviour is a release blocker unless explicitly waived by the user.

### T029 [R01][R02][R03][R07] Desktop WPF verification
- [ ] Use UI Automation (System.Windows.Automation) + screenshots (NOT Playwright — this is WPF) for: window at supported minimum; 100/150/200 % scaling; light/dark/HighContrast; keyboard-only flows; Narrator; column resize/drag.
- [ ] Synthetic fleets 100 / 1000 / 5000 rows: startup time, filter/sort latency, detail-pane latency, memory/handle stability across a soak + window open/close cycles.
- [ ] Modal review while operations continue; selection survives refresh; window close during slow remote calls — no freeze/deadlock/leak.
Pass criteria: documented screenshots + measured numbers compared against the Phase 0 numerical budgets; no unmeasured 'no regression' claim; disclose any excluded legacy GUI test and substitute equivalent desktop evidence.

### T030 [R01-R08] Documentation + release candidate
- [ ] Update `README.md`, `docs\DEVELOPMENT.md`, `docs\TESTING.md`, state-machine/audit/config docs and release notes for the TARGET's own version (do not transplant the CLI version; WUU2 keeps its own versioning).
- [ ] Document: transplant revision(s) and source modules; config wire format + non-concurrency caveat + honest crypto description; audit tamper-evidence limitation; what was tested vs skipped (elevation-dependent suites).
- [ ] Rollback plan: restore prior package; the protected config backup (Phase 3) restores saved lists; audit evidence is retained and never rewritten/deleted by rollback.
- [ ] Release an RC only after every gate passes and with explicit user approval; no tag/push by the agent.
Pass criteria: the docs match the shipped tree; the RC is reproducible; skip/limitation list is explicit.

## Phase 6 gate (release-blocking)
Phases 0-5 gates recorded PASS; Phase 6 gate exit 0; suite runner all-applicable green with skips named; package verified clean and launchable; lab + desktop evidence on file; docs honest. THEN the user decides on release.
