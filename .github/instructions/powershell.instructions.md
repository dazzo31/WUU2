---
applyTo: "**/*.ps1, **/*.psm1, **/*.psd1"
---

# PowerShell standards for WUU2

## Target runtime
- Windows PowerShell 5.1, elevated, STA (`powershell.exe -STA`). Keep PowerShell 7 compatibility: `Get-CimInstance` not `Get-WmiObject`, `Invoke-Command` not `-ComputerName` remoting parameters, nested `Join-Path` not 3-arg form.

## Naming and correctness
- Variable names are case-insensitive: never define two variables differing only by case (`$removeEntry` vs `$RemoveEntry` silently overwrite each other — this caused a real runspace leak). Never use `$host`, `$pid`, or other automatic-variable names as locals.
- PascalCase approved Verb-Noun for functions; only real, documented cmdlets and parameters.
- Single-quoted strings unless interpolating; here-strings for multi-line content (XAML); no unnecessary backticks.

## Runspace and threading rules (critical in WUU.ps1)
- UI updates from background runspaces MUST use `$uiHash.<Control>.Dispatcher.Invoke(...)`.
- Scriptblocks injected into runspaces via `SessionStateProxy.SetVariable` MUST be unbound: `[scriptblock]::Create($sb.ToString())`. A literal `{...}` stays bound to the creating runspace and resolves variables there (usually `$null`).
- Windows Update COM objects must stay in-process: never `Start-Job` (serialization strips COM methods). Use nested `[powershell]::Create()` + `BeginInvoke` polling for timeouts, and `Dispose()` on every path.
- `PowerShell.Dispose()` does NOT close an explicitly assigned runspace — call `Runspace.Close()` + `Dispose()` yourself or the runspace leaks.
- Snapshot synchronized collections before enumerating: `@($jobs)`.

## Windows Update Agent API
- Valid search criteria only: `IsInstalled`, `IsHidden`, `IsAssigned`, `Type`, etc. `Title like '...'` throws 0x80240032. MSRT is invisible to all WUA searches (delivered outside the WUA store).

## Errors and output
- `try`/`catch` only where handled or rethrown, referencing `$_.Exception.Message`; check `$LASTEXITCODE` after psexec/external tools.
- Output objects, not formatted text; `Write-Host` only for user-facing status in standalone diagnostic scripts.
- No hard-coded secrets; use `Get-Credential`, the existing credential-cache config, or parameters.

## Validation before release
- Parse check: `[System.Management.Automation.Language.Parser]::ParseFile(...)` must report zero errors.
- Run `Scripts\Validate-Release.ps1` (XAML load + FindName check for every control wired with `Add_*` in WUU.ps1).
- Keep PSScriptAnalyzer clean (no unused variables).
