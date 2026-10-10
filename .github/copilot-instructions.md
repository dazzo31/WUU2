# WUU2 — Copilot instructions

GUI tool (Windows Update Utility) for checking/downloading/installing Windows Updates on remote machines. Pure PowerShell + WPF/XAML; no build system and no package manager, but **there IS a test suite** (`tests\` + `Scripts\Invoke-TestSuites.ps1`).

## Canonical files
- **`src\*.psm1` is where the code lives.** `WUU.ps1` is a thin launcher: it validates the host, calls `Import-WuuModules`, then `Start-WuuApplication`. Do not put application logic back into `WUU.ps1`.
- Current modules (imported in this order by `Import-WuuModules` in `src\Wuu.Core.psm1`): `Wuu.Logging`, `Wuu.Models`, `Wuu.Remote`, `Wuu.Network`, `Wuu.Credentials`, `Wuu.Workers`, `Wuu.WindowsUpdate`; `Wuu.Core` is the entry module that owns `Start-WuuApplication`, event wiring, the dispatcher timer and cleanup.
- UI layouts live in `ui\MainWindow.xaml` (main window), `ui\CredentialDialog.xaml` and `ui\OUSelector.xaml`, loaded via `[Windows.Markup.XamlReader]::Load`. Controls are resolved with `FindName` — keep `x:Name` values in XAML and lookups in `src\Wuu.Core.psm1` in sync.
- `WUU_backup*.ps1`, `WUU_v1.1.ps1`, `WUU_debug.ps1`, `WUU_perplexity.ps1`, `WUU_git_version.ps1`, `WUU_updated_backup*.ps1` and `WUU_backup_*.xaml` are historical snapshots — never modify them and don't treat them as current behaviour. `dist\` (including `dist\staging\`) is packaged output — never edit it, and exclude it from searches when locating current code.

## Runtime constraints
- Target Windows PowerShell 5.1, elevated, STA mode (`powershell.exe -STA`); the script self-checks `$host.Runspace.ApartmentState`. Preserve PowerShell 7 compatibility patterns already in place: `Get-CimInstance` instead of `Get-WmiObject`, `Invoke-Command` instead of `-ComputerName` remoting parameters.
- Remote download/install runs `Scripts\Download-Patches.ps1` / `Install-Patches.ps1` on the target as a temporary SYSTEM scheduled task via `Invoke-WuuRemoteTask` (src/Wuu.Remote.psm1, DCOM CIM session; progress via `HKLM\SOFTWARE\WUU2\Jobs`), because Windows Update COM APIs refuse remote download/install. No PsExec. Worker runspaces get it as the injected `$InvokeRemoteTaskScript`.

## Concurrency conventions (critical)
- UI state is shared through the synchronized hashtable `$uiHash`; background work uses runspaces plus the synchronized `$jobs` ArrayList, throttled by `$MaxConcurrentJobs`.
- Any UI update from a background runspace MUST go through `$uiHash.<Control>.Dispatcher.Invoke(...)` — never touch WPF controls directly off the UI thread.
- Script-scoped toggles (`$script:EnableDebugLogging`, `$script:EnableEnhancedErrorHandling`, credential configuration) live in the modules that own them (see `#region Configuration` in `src\Wuu.Core.psm1`), not in the launcher.

## Verification & packaging
- Smoke test: `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1` (needs admin for full function).
- Run the suites: `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File Scripts\Invoke-TestSuites.ps1` — runs each `tests\Test-*.ps1` in its own bounded child process and reports PASS / FAIL / SKIP / TIMEOUT / STALE.
- Before releasing: `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File Scripts\Validate-Release.ps1` (XAML load + control/event-wiring checks).
- Package a release zip with `Scripts\Package-WUU2.ps1` — when adding new runtime files, also add them to its `$include` list.
- Keep the modules clean under PSScriptAnalyzer (past fixes removed unused variables).
