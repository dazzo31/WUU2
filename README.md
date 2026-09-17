# WUU2

Windows Update Utility (WUU) — GUI tool for checking/downloading/installing Windows Updates on remote machines.

This repo is a consolidated/fixed version of the original Windows Update Utility by Tyler Siegrist (PoshPIAG/TechNet) with additional reliability and compatibility improvements.

## How this fork differs from the original

The original WUU is a single-threaded-feeling WinForms-style WPF script whose remote checks can hang the UI indefinitely and whose remote operations assume a homogeneous domain. This fork keeps the same UI and workflow, but rebuilds the concurrency, transport, and credential layers. Highlights (full detail in `docs/`):

### Improvements

| Area | Original | This fork |
|------|----------|-----------|
| **GUI responsiveness** | UI could freeze permanently at "Validating connectivity..." — a worker runspace blocked inside `Dispatcher.Invoke` deadlocks against the UI thread when the dispatcher action uses pipeline cmdlets bound to that busy runspace | Dispatcher actions use only PowerShell language constructs (`foreach`/property sets); worker helpers are injected as *unbound* scriptblocks; regression-tested (headless deadlock harnesses in `Scripts\Test-*.ps1`) |
| **Hang protection** | Unbounded remote calls (WMI, service queries, update search) could stall a job forever, starving the job throttle | Every remote call is wrapped with a hard timeout (`Invoke-CimWithTimeout`, `Invoke-ServiceWithTimeout`, `Invoke-RemoteComWithTimeout`); stuck jobs are stopped after 10 minutes and greyed out |
| **WMI transport** | `Get-WmiObject -ComputerName` (DCOM) — worked without WinRM | **DCOM CIM sessions for both credential paths** (v1.2.1): default-credential probes were briefly routed over WinRM/WSMAN in the enhanced branch, which misreported WMI-reachable hosts as timeouts; now both paths use `New-CimSession -Protocol DCOM`, matching legacy behavior — **no WinRM listener required for update checks** |
| **Service pre-flight** | None | Best-effort `wuauserv` status check/auto-start that *cannot* abort the update check (it's demand-start; the COM search starts it when needed) |
| **Credentials** | Current user's domain credentials only, plain-string handling in places | All credential parameters typed `[pscredential]`; custom-credential configuration dialog with per-computer cache; PS 5.1 `Get-CimInstance` has no `-Credential` parameter — alternate credentials go through DCOM `New-CimSession` |
| **Scale & staging** | All computers checked at once | Job throttling (`$MaxConcurrentJobs`, default 10) plus a 5-phase staging system — later phases wait until earlier ones are fully patched (errored/timed-out hosts never block a phase) |
| **Saved lists** | Plain-text export | Optional encrypted computer-list config (AES, password-derived key) storing name + phase |
| **UI polish** | Fixed columns | Auto-fitting, drag-resizable columns with per-column proportions and a 40px minimum; fast WPF credential/password dialogs (no slow Windows credential prompt lag) |
| **Maintainability** | Duplicate variable names silently shadowing live code (`$RemoveEntry`, `$GetErrors`) | Duplicates removed; runspace-scoped helper injection documented; `Scripts\Validate-Release.ps1` gates releases |

### Drawbacks / trade-offs

- **Elevation + STA required** — same as the original; the tool is admin-only by design.
- **WinRM is still used by the service *actions*** — the Start/Stop/Restart `wuauserv` menu items and RPC auto-recovery go through `Invoke-Command` (PS7-compatible remoting). *Update checks themselves are WinRM-free*; only those optional actions need a WinRM listener.
- **`psexec.exe` still required** for remote download/install (not bundled — Sysinternals license); the script offers to download it on first run.
- **Debug logging ships enabled** (`$script:EnableDebugLogging = $true`) to aid diagnosis — it writes large log files and costs performance. Flip it to `$false` at the top of `WUU.ps1` for production use.
- **Heavier failure paths** — retry logic with 5-second backoffs and bounded timeouts means a genuinely unreachable host takes longer to report than the original's fast fail (in exchange for never hanging).
- **The update search must run in-process** — WUA COM objects can't be serialized across a `Start-Job` boundary (deserialized update collections can't be downloaded/installed), so search concurrency is bounded by design.
- **MSRT not counted** — a WUA API limitation; Windows Settings may show one more update than WUU when a Malicious Software Removal Tool release is pending.
- **PS 7 support is best-effort** — WPF/AD assemblies may be limited depending on the PowerShell 7 install; Windows PowerShell 5.1 remains the recommended host.

## Prerequisites

- Windows PowerShell 5.1 (recommended for best WPF compatibility). PowerShell 7+ may work but WPF/AD features can be more limited depending on system components.
- Run as Administrator (required for full functionality).
- PowerShell must run in STA mode (required for WPF): `powershell.exe -STA`.
- PsExec must be available in the repo folder as `psexec.exe`.
	- Download: https://docs.microsoft.com/en-us/sysinternals/downloads/psexec
	- If missing, the script can prompt to download PsTools automatically.

## Run

From an elevated PowerShell prompt in the repo folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1
```

## Key files

- `WUU.ps1` — main script
- `WUU.xaml` — main UI layout
- `OUPicker.xaml` — OU picker UI
- `ComputerList.config` — saved computer lists (if used)
- `Exempt.txt` — host exemptions (if used)
- `Scripts\` — helper scripts

## Packaging (zip)

Use `Scripts\Package-WUU2.ps1` to generate a zip containing the runnable files + docs.

## Credits / upstream

- Original project: https://gallery.technet.microsoft.com/scriptcenter/Windows-Update-Utility-WUU-1d72e520
