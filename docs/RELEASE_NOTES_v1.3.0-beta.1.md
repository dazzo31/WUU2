# Beta Release v1.3.0-beta.1 — Modular architecture

> **This is a beta.** The monolithic script was split into a module
> architecture. Core flows (update check / download / install) are verified by
> automated tests, but the refactor is broad — please test against a non-critical
> machine first and report issues.

## What changed

### Architecture: `WUU.ps1` split into modules

The 6,000-line monolith is now a ~25-line entry point plus focused modules:

```
WUU2/
├── WUU.ps1                 # tiny application entry point
├── src/
│   ├── Wuu.Core.psm1           # startup, environment validation, event wiring, GUI loop
│   ├── Wuu.Credentials.psm1    # credential dialogs, DPAPI helpers, encrypted list configs
│   ├── Wuu.Logging.psm1         # thread-safe debug logging
│   ├── Wuu.Models.psm1         # synchronized state factories, error-suggestion catalog
│   ├── Wuu.Network.psm1        # remote COM operations, performance sampling
│   ├── Wuu.Remote.psm1         # bounded WMI/CIM + service operations
│   └── Wuu.WindowsUpdate.psm1  # worker runspaces, job scheduling, phase gating
├── ui/
│   ├── MainWindow.xaml         # was WUU.xaml
│   ├── CredentialDialog.xaml   # extracted from inline XAML (single source of truth)
│   └── OUSelector.xaml         # was OUPicker.xaml
├── tests/                      # regression harnesses (see below)
└── docs/
```

### Fixes included in this beta

1. **Items stuck at "Initializing..."** (two split regressions, both fixed):
   - `Initialize-WuuWindowsUpdateContext` was never called, so the job
     scheduler silently no-oped (`$script:WuuCtx` stayed null).
   - **Module session-state isolation**: modules imported into Wuu.Core's
     session state were invisible to each other — `New-ComputerRunspace`
     calling `Write-InfoLog` threw "not recognized", killing every timer
     tick and crashing `ShowDialog`. All modules now import with `-Global`
     via a shared `Import-WuuModules` function (single import path used by
     both the app and the tests).
2. **Runtime credential state**: `New-ComputerRunspace` now reads
   `UseCustomCredentials`/`CustomCredentials`/`CredentialCache` from global
   scope at creation time, so reconfiguring credentials mid-session reaches
   runspaces created afterward (the startup snapshot would have been stale).
3. **Defensive dispatcher guard** in `Start-UpdateCheckJob`'s error path
   (dispatcher can be absent during shutdown).

### New regression tests (tests/)

- `Test-PendingDrain.ps1` — the job-scheduler drain path (timer →
  `Start-PendingUpdateCheck` → `Start-UpdateCheckJob`), imported through the
  real module topology. Asserts two consecutive pending drains.
- `Test-CrossModuleResolution.ps1` — proves cross-module command resolution
  (the round-2 bug): calls the real `New-ComputerRunspace` and asserts the
  cross-module logging call executes and lands in the debug log.
- `Test-ModuleImport.ps1` — import smoke test for all seven modules.

> Testing lesson baked in: the first regression test **false-passed** because
> it imported modules directly into the test session, bypassing the app's
> real import path and masking the visibility bug. Tests now import through
> `Import-WuuModules` exactly like the app.

## Known issues / notes

- **OneDrive placeholder warning**: running the tool from a OneDrive-synced
  folder with Files-On-Demand can fail on `psexec.exe` ("The cloud file
  provider exited unexpectedly") when OneDrive isn't running — the binary
  gets dehydrated to an online-only placeholder. Pin the runtime files
  locally or run from a non-synced path.
- `psexec.exe` remains unbundled (Sysinternals license) — download per README.
- Debug logging still ships enabled (`$global:EnableDebugLogging = $true` in
  `src\Wuu.Core.psm1`) for the beta period. Expect large log files; flip to
  `$false` for production use.

## Upgrade notes

Drop-in replacement for v1.2.x — same UI, same workflow. The zip now includes
`src\` and `ui\`; extract the whole archive and run `WUU.ps1` from the root
as before. Do not run from inside `src\`.