# WUU2 — Copilot instructions

GUI tool (Windows Update Utility) for checking/downloading/installing Windows Updates on remote machines. Pure PowerShell + WPF/XAML; no build system, no package manager, no test suite.

## Canonical files
- [WUU.ps1](../WUU.ps1) is the ONLY main script to edit. `WUU_backup*.ps1`, `WUU_v1.1.ps1`, `WUU_debug.ps1`, `WUU_perplexity.ps1`, `WUU_git_version.ps1`, and `WUU_backup_*.xaml` are historical snapshots — never modify them and don't treat them as current behavior. `dist/` (including `dist/staging/`) is packaged output — never edit it and exclude it from searches when locating current code.
- UI layout lives in `WUU.xaml` (main window) and `OUPicker.xaml`, loaded at runtime via `[Windows.Markup.XamlReader]::Load`. Controls are resolved with `FindName` — keep `x:Name` values in XAML and lookups in WUU.ps1 in sync.

## Runtime constraints
- Target Windows PowerShell 5.1, elevated, STA mode (`powershell.exe -STA`); the script self-checks `$host.Runspace.ApartmentState`. Preserve PowerShell 7 compatibility patterns already in place: `Get-CimInstance` instead of `Get-WmiObject`, `Invoke-Command` instead of `-ComputerName` remoting parameters.
- Remote download/install runs `Scripts\Download-Patches.ps1` / `Install-Patches.ps1` on the target as a temporary SYSTEM scheduled task via `Invoke-WuuRemoteTask` (src/Wuu.Remote.psm1, DCOM CIM session; progress via `HKLM\SOFTWARE\WUU2\Jobs`), because Windows Update COM APIs refuse remote download/install. No PsExec. Worker runspaces get it as the injected `$InvokeRemoteTaskScript`.

## Concurrency conventions (critical)
- UI state is shared through the synchronized hashtable `$uiHash`; background work uses runspaces plus the synchronized `$jobs` ArrayList, throttled by `$MaxConcurrentJobs`.
- Any UI update from a background runspace MUST go through `$uiHash.<Control>.Dispatcher.Invoke(...)` — never touch WPF controls directly off the UI thread.
- Script-scoped toggles (`$script:EnableDebugLogging`, `$script:EnableEnhancedErrorHandling`, credential config) live in the `#region Configuration` block at the top of WUU.ps1; add new global settings there.

## Verification & packaging
- Smoke test: `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1` (needs admin for full function).
- Before releasing: `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File Scripts\Validate-Release.ps1` (XAML load + control/event-wiring checks).
- Package a release zip with `Scripts\Package-WUU2.ps1` — when adding new runtime files, also add them to its `$include` list.
- Keep the script clean under PSScriptAnalyzer (past fixes removed unused variables).
