# Phase 0 Evidence — Baselines and Promotion Gate

Recorded: 2026-10-06. Target: `C:\Users\dazzo\OneDrive\GitHub\WUU2`. Donor (read-only): `C:\Users\dazzo\OneDrive\GitHub\WUU2-CLI`.

This file is the auditable record for T001–T004. Defects discovered while establishing this baseline
are written up in `docs\DEFECTS_FOUND_20261006.md` (D1 CIM success masking, D3 stale suites, D5 exit-code
capture, D6 instructions). No donor file and no unrelated target file was
modified. The only target changes are: the two `.github` instruction files (T004), the new
`Scripts\Invoke-TestSuites.ps1` (T004), the repaired import path in `tests\Test-CredentialTyping.ps1`
(see T003 note), and this `docs\tasks\` pack.

---

## T001 — Repository baselines and provenance

### Revisions

| Repo | Branch | HEAD | Dirty entries |
|------|--------|------|---------------|
| WUU2 (target) | master | `f1d5f97465d2301b331ded8655ee8e1b745e779e` | 8 |
| WUU2-CLI (donor) | master | `0566164bba3eb24d86121405bdbb39d58ff2c4ab` | 6 |

> **Donor has since advanced.** These hashes are the accepted promotion point for this phase. The
> donor has been independently developed to `v1.5.0-rc.2-cli` (HEAD `2ff4203`), which fixes the C1–C6
> defects raised from this side. Its code fixes were re-verified on 2026-10-06; its published test
> baseline did not reproduce (57 pass / 1 skip / 1 fail, not 58/1/0) — see
> `WUU2-CLI\docs\DEFECTS_AND_COVERAGE_20261006.md` §8. Re-baseline before promoting anything further
> from the donor.

### Dirty files (preserved, not touched)

Target:
```
 M LICENSE
 M README.md
 M Scripts/Package-WUU2.ps1
?? NOTICE
?? Scripts/_pack-beta3.ps1
?? docs/PROVENANCE.md
?? qwen3.5-32k-agentic.modelfile
?? qwen3.5-32k-agentic.modelfileGet-Content
```
Donor (all untracked community files):
```
?? .github/ISSUE_TEMPLATE/
?? .github/pull_request_template.md
?? CODE_OF_CONDUCT.md
?? CONTRIBUTING.md
?? SECURITY.md
?? SUPPORT.md
```

### Accepted donor payload hashes (SHA-256, donor revision above)

| File | SHA-256 | Bytes |
|------|---------|-------|
| `src\Wuu.State.psm1` | `3461D80A1EF5600D9A2D3D84AFE4E08A67F7BBD6032DA4A8A2B5A85BC6CB6DF1` | 116121 |
| `src\Wuu.Configuration.psm1` | `B5B42F9F8E7F52DB8F46821462A1DFE828D355DE4C4B7C68D0A59F8B321C9D19` | 11231 |
| `src\Wuu.Scheduler.psm1` | `DA3955161DE973B33E9CEC0357CA976B6D75539940912373BE86F9722FB98EF4` | 13938 |
| `src\Wuu.WindowsUpdate.psm1` | `080004D520BF4971BC5380AE1E86687B85AF22D1C5AF1498FC28ED33211603B6` | 67056 |
| `src\Wuu.Workers.psm1` | `086FF3E5ECBCB579E61AE0AC10447EECE8257EDFF1E794A9A08EC733850A03E1` | 45372 |
| `src\Wuu.Audit.psm1` | `E20D9F305C0E1FEE353F5D091B3FF9466D19EE3450E73E1B4DEAB7AD88ADBD4F` | 65059 |
| `src\Wuu.Reporting.psm1` | `D1F2FCE077DCCE89A1B7261EB44774ABB3590E6404A33BE3CAC488CC66C60561` | 38790 |
| `src\Wuu.Credentials.psm1` | `81704CB0ECE866C8763D7E333388D8B41CC89D97ED9D65E7AF503DC40216DC9E` | 47801 |
| `src\Wuu.Remote.psm1` | `026E8C0AD38338E5788D654003D7DCC9AE634416F199F5E4AB0340D92F5C315B` | 24948 |
| `src\Wuu.Network.psm1` | `51E38AB719D97DB1880AEACF51CB9574B81984829B4EB528EEAB1472B18EBCE6` | 5913 |
| `src\Wuu.Result.psm1` | `E0988753F62EFF46BDD2DCBCF64E858DF02CD038B93D09EFBA109749BFEE1BD5` | 15188 |
| `Scripts\Download-Patches.ps1` | `F0723410A751D73E2403870267A183F2DCA0647FA5090B5097B5E9F8CF248B42` | 1700 |
| `Scripts\Install-Patches.ps1` | `8C8B5D4BB195CCFB044EC1BD09B3ED8B26495F5A4836A6A88F25145348A3A2C7` | 2315 |

### Version sources

- **Donor**: single-sourced `$global:WuuVersion = 'v1.5.0-rc.1-cli'` in `src\Wuu.Configuration.psm1`.
- **Target**: **no application version constant exists.** `WUU2` has only `#Requires -Version 5.1`
  headers and a "Enhanced Version - 2025-07-08" changelog comment. T005 must introduce a target-owned
  version source; the CLI literal must **not** be transplanted.

---

## T002 — Donor failure-path validation (read-only)

Run through `Scripts\Invoke-TestSuites.ps1` against `WUU2-CLI\tests` (donor never modified).

| Probe suite | Verdict | Notes |
|-------------|---------|-------|
| `Test-InstallOutcome` | PASS | install-error masking / classifier |
| `Test-WorkerIdentityFence` | PASS | main-vs-worker reset fence |
| `Test-PendingPolicy` | PASS | refusal-safe queue |
| `Test-CleanupIdentityRetire` | PASS | cleanup retires identity |
| `Test-TerminalStates` | PASS | terminal protection |
| `Test-TargetOutcomes` | PASS | outcome classifiers |
| `Test-ConcurrencyCap` | PASS | cap enforcement |
| `Test-SubmissionAtomicity` | PASS | real shared-gate exclusion |
| `Test-OperationTimeouts` | PASS | deadline/budget |
| `Test-OperationIdentity` | PASS | operation identity |
| `Test-PhaseFailurePolicy` | PASS | BlockOnFailure/ContinueOn* |
| `Test-RefusalSemantics` | PASS | refusal vs failure |
| `Test-CredentialDeterminism` | PASS | resolver / epoch |

**14/14 PASS.** Donor release gate `WUU2-CLI\Scripts\Validate-Release.ps1` also exits **0**
("All validation checks passed"), including the no-silent-fallback, terminal-set single-source,
anchor-separation and versioned-envelope gates.

**Verdict: no blocked transplant.** All six reviewed failure paths plus the concurrency and
credential-identity contracts behave correctly at the accepted donor revision.

---

## T003 — Target (WUU2) test baseline

### Release gate

`powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1`
→ **exit 0**, "All validation checks passed" (MainWindow.xaml loads; all 37 wired controls resolve;
OUSelector.xaml and CredentialDialog.xaml parse).

### Suite baseline (bounded child process per suite, 120s timeout)

**At the time of T003 (superseded — kept as the historical baseline):**

| Suite | Verdict | Exit | Seconds |
|-------|---------|------|---------|
| Test-AutoFlowChain | PASS | 0 | 1.1 |
| Test-ColumnResize | STALE | – | – |
| Test-CredentialTyping | STALE | – | – |
| Test-CrossModuleResolution | PASS | 0 | 0.5 |
| Test-DragResize | STALE | – | – |
| Test-LogFaultTolerance | PASS | 0 | 0.7 |
| Test-ModuleImport | PASS | 0 | 0.4 |
| Test-PendingDrain | PASS | 0 | 0.5 |
| Test-RemoteHelpers | PASS | 0 | 3.6 |
| Test-RemoteTask | SKIP | 1 | 0.3 |
| Test-WorkerPool | PASS | 0 | 2.1 |

**Totals at T003: PASS 7 · SKIP 1 · STALE 3 · FAIL 0 · TIMEOUT 0.** Machine-readable copy:
`docs\tasks\phase-0-baseline-suites.json`.

### Suite classification at T003 (historical)

- **Headless / runnable then (7 PASS):** AutoFlowChain, CrossModuleResolution, LogFaultTolerance,
  ModuleImport, PendingDrain, RemoteHelpers, WorkerPool.
- **Elevated only (1 SKIP):** `Test-RemoteTask` — registers a SYSTEM scheduled task; exits 1 with a
  `SKIP:` marker by design when not elevated. A SKIP is not coverage.
- **STALE (3) — fixture removed by the module split:** `Test-ColumnResize`, `Test-DragResize`,
  `Test-CredentialTyping`.

### T025/T027 resolution — CURRENT baseline

All three stale suites were dealt with, and the runner's stale list was **removed** (a stale list is
where a suite that has stopped testing anything can hide while still counting toward the total).

| Suite | Verdict now | Assertions | Note |
|-------|-------------|-----------|------|
| Test-ColumnResize | **PASS** | 6 | retargeted to `ui\MainWindow.xaml` + `src\Wuu.Core.psm1` |
| Test-DragResize | **PASS** | 5 | retargeted **and converted from a narrative log into assertions** — it previously always exited 0 |
| Test-CredentialContract | **PASS** | 17 | **replaces** `Test-CredentialTyping`, which was deleted — see below |
| Test-RemoteTask | SKIP | – | still elevation-gated; a skip is not coverage |

**Current totals: PASS 12 · SKIP 1 · FAIL 0 · TIMEOUT 0** (13 suites, exit 0).

Two recorded reasons were **wrong** and are corrected here:

1. `Test-CredentialTyping` was marked STALE for exceeding "180s wall-clock". Measured: **10.9s**. The
   performance claim was never tested. Its real defect was vacuity, not duration — two of its three
   assertions could not fail (one asserted "the call returned false and is not a binding error"
   against a permanently non-existent host; the other counted *not throwing* as a pass for a string
   that PowerShell silently binds to `$null`). Replaced by `Test-CredentialContract.ps1`, which
   asserts the actual R04 rule (a failing custom credential is reported unverified and is never
   swapped for the process identity) against a real failing probe — 17 assertions, 5.8s, no mocks.
2. `Test-DragResize`'s "drag simulation also blocks without an interactive desktop" was untested
   reasoning. It runs fine in an interactive session; the real problem was that it only *printed*
   its findings. It now asserts, and its interactive-desktop requirement is stated in the file.

### Tooling finding (recorded because it affects every future runner)

Child-process **exit codes are unreliable in this environment**. `Start-Process -PassThru` and the
`cmd /c ... %ERRORLEVEL%` wrapper both silently reported `0` for a script that `exit 7`; a first
baseline run therefore reported ten false PASSes. The `System.Diagnostics.Process` class is the only
capture that reflects the true exit code (verified against `exit 7`, an unhandled `throw`, and
`exit 0`). `Invoke-TestSuites.ps1` uses it.

### Retained capability inventory (from `ui\MainWindow.xaml`)

Wired controls confirmed by the gate: AddADContext, AddADMenu, AddComputerContext, AddComputerMenu,
AddFileContext, BrowseFileMenu, CheckUpdatesContext, ClearComputerListMenu, CopyCellContext,
DownloadUpdatesContext, ExitMenu, ExportListMenu, InstallUpdatesContext, LoadConfigMenu,
OfflineHostsMenu, Phase1–5Menu, RemoteDesktopContext, RemoveComputerContext, RestartContext,
SaveConfigMenu, SelectAllMenu, SetDomainCredentialsContext, ShowInstalledContext, ShowUpdatesContext,
TestADConnectionMenu, UpdateHistoryMenu, ViewErrorMenu, ViewUpdateLogContext, WSUSAuditContext,
WURestartServiceMenu, WUStartServiceMenu, WUStopServiceMenu.

Grid columns: Computer, Phase, Available, Downloaded, Install Errors, Status, Reboot Required,
Updates Status. These must all remain reachable in the Phase 5 redesign.

### Measurement budgets

Suites run fast (≤3.6s each) and the gate is sub-second, so the meaningful budgets for T029 are the
GUI interaction numbers (startup, filter/sort, detail-pane latency, memory/handle stability on
100/1000/5000-row fleets) against synthetic data. Baseline screenshots and the numeric budget table
are recorded when the Phase 1/5 UI actually changes; no "no regression" claim may be made before then.

---

## T004 — Instruction reconciliation and the GUI runner

- `.github\copilot-instructions.md` reconciled: `src\*.psm1` is the code home, `WUU.ps1` is a thin
  launcher, the real module list and import order are stated, UI paths corrected to `ui\*.xaml`, the
  false "no test suite" claim removed, and the runner added to the packaging/verification section.
- `.github\instructions\powershell.instructions.md` reconciled: added a Layout section; WPF/XAML and
  wiring paths corrected; validation section points at the suite runner and warns that SKIP/STALE are
  never coverage.
- `Scripts\Invoke-TestSuites.ps1` added: per-suite bounded child process, reliable process exit code,
  PASS/FAIL/SKIP/TIMEOUT/STALE classification, `-SuiteDirectory`/`-TimeoutSec`/`-Include`/`-Exclude`/
  `-IncludeStale`/`-OutputJson`, delimited-string filter support (PowerShell arrays cannot survive
  `-File` argument passing), and exit 1 on any FAIL or TIMEOUT.
- **Runner proven to fail**: against a disposable probe directory it reported FAIL (exit 1),
  TIMEOUT (killed at the limit) and SKIP distinctly, then exited 1. The real suites were never mutated.

---

## Phase 0 gate

| # | Gate item | Status |
|---|-----------|--------|
| 1 | Evidence records HEADs, hashes, donor probe verdicts, target baseline | PASS |
| 2 | Donor fixtures accepted at a recorded revision; blocked transplants named | PASS (none blocked) |
| 3 | Instructions reconciled; runner proven to fail on a failing suite | PASS |
| 4 | No donor or unrelated dirty target file modified | PASS |

**Gate verdict: PASS.** Phase 1 may start.

Note: Phase 1 T005 must add a target-owned version constant, since the target currently has none.
