# WUU2

Windows Update Utility (WUU) — GUI tool for checking/downloading/installing Windows Updates on remote machines.

This repo is a consolidated/fixed version of the original Windows Update Utility by Tyler Siegrist (PoshPIAG/TechNet) with additional reliability and compatibility improvements.

## How this fork differs from the original

The original WUU (Tyler Siegrist, 2016) is a WPF script whose remote checks can hang the UI indefinitely and which only ever used the current user's domain credentials. This fork keeps the same UI and workflow, but adds substantial new capability and rebuilds the concurrency, transport, and credential layers. Full detail in `docs/`.

### New features (not in the original)

- **Phased deployment** — assign computers to up to 5 deployment phases (Action menu or right-click > *Assign Phase*). A phase's checks don't start until every computer in the previous phase is fully patched and reboot-clean, so you can wave updates across an estate instead of hitting everything at once. Errored/timed-out hosts never block later phases, and phase assignments persist in saved computer lists.
- **Full automation workflow** — the original only offered auto-reboot after install. New *Auto-download* and *Auto-install* checkboxes enable the complete pipeline per computer: check → download → install → reboot (if required) → re-check.
- **WSUS audit** — right-click any computer to compare WSUS-assigned updates against the standard Windows Update count, with download states, WSUS server detection, and reboot status (uses `Scripts\Audit-WSUSUpdates.ps1`).
- **Custom remote credentials** — configure alternate credentials (username/domain/password dialog) for WMI/DCOM queries against non-domain or restricted hosts, with a per-computer credential cache to avoid repeated prompts. Credentials are held as `SecureString` end-to-end.
- **Encrypted computer-list configs** — save and load computer lists (including phase assignments) protected by a password-derived AES key, replacing the original's plain-text export.
- **Clipboard list management** — copy full computer details or just status messages; paste a list of computer names straight from the clipboard into the grid.
- **Active Directory diagnostics** — built-in AD connectivity test (domain join, LDAP, computer search, prerequisites) with actionable results when the AD import fails.
- **Performance monitoring & job throttling** — CPU/memory/latency thresholds warn before operating on overloaded systems; concurrent update checks are capped (default 10, configurable) so large estates stay responsive.
- **Resizable, auto-fitting columns** — drag any column grip; the header always spans the window, user-dragged widths are respected, and columns can't be dragged to zero width.
- **Operator tooling** — stuck-process killer (`Kill-WUU-Processes.ps1`), a release validation script (`Scripts\Validate-Release.ps1`), and headless regression harnesses for the deadlock fixes (`Scripts\Test-*.ps1`).

### Reliability & platform improvements

| Area | Original | This fork |
|------|----------|-----------|
| **GUI responsiveness** | UI could freeze permanently at "Validating connectivity..." — a worker runspace blocked inside `Dispatcher.Invoke` deadlocks against the UI thread when the dispatcher action uses pipeline cmdlets bound to that busy runspace | Dispatcher actions use only PowerShell language constructs (`foreach`/property sets); worker helpers are injected as *unbound* scriptblocks; regression-tested (headless deadlock harnesses in `Scripts\Test-*.ps1`) |
| **Hang protection** | Unbounded remote calls (WMI, service queries, update search) could stall a job forever, starving the job throttle | Every remote call is wrapped with a hard timeout (`Invoke-CimWithTimeout`, `Invoke-ServiceWithTimeout`, `Invoke-RemoteComWithTimeout`); stuck jobs are stopped after 10 minutes and greyed out |
| **WMI transport** | `Get-WmiObject -ComputerName` (DCOM) — worked without WinRM | **DCOM CIM sessions for both credential paths** (v1.2.1): default-credential probes were briefly routed over WinRM/WSMAN in the enhanced branch, which misreported WMI-reachable hosts as timeouts; now both paths use `New-CimSession -Protocol DCOM`, matching legacy behavior — **no WinRM listener required for update checks** |
| **Service pre-flight** | None | Best-effort `wuauserv` status check/auto-start that *cannot* abort the update check (it's demand-start; the COM search starts it when needed) |
| **Credential safety** | Plain-string password handling in places | All credential parameters typed `[pscredential]`; PS 5.1 `Get-CimInstance` has no `-Credential` parameter — alternate credentials flow through DCOM `New-CimSession` |
| **Maintainability** | Duplicate variable names silently shadowing live code (`$RemoveEntry`, `$GetErrors`) | Duplicates removed; runspace-scoped helper injection documented; `Scripts\Validate-Release.ps1` gates releases |

### Drawbacks / trade-offs

- **Elevation + STA required** — same as the original; the tool is admin-only by design.
- **WinRM is still used by the service *actions*** — the Start/Stop/Restart `wuauserv` menu items and RPC auto-recovery go through `Invoke-Command` (PS7-compatible remoting). *Update checks themselves are WinRM-free*; only those optional actions need a WinRM listener.
- **Download/install run as a temporary SYSTEM scheduled task on the target** (no PsExec). The task is created over the same DCOM/WMI connection used for update checks, reports per-update progress through `HKLM\SOFTWARE\WUU2\Jobs`, and is removed when it finishes. Requires Windows 8 / Server 2012 or later on the target (Task Scheduler WMI provider); Windows 7 targets are not supported for download/install.
- **Debug logging ships enabled** (`$script:EnableDebugLogging = $true`) to aid diagnosis — it writes large log files and costs performance. Flip it to `$false` at the top of `WUU.ps1` for production use.
- **Heavier failure paths** — retry logic with 5-second backoffs and bounded timeouts means a genuinely unreachable host takes longer to report than the original's fast fail (in exchange for never hanging).
- **The update search must run in-process** — WUA COM objects can't be serialized across a `Start-Job` boundary (deserialized update collections can't be downloaded/installed), so search concurrency is bounded by design.
- **MSRT not counted** — a WUA API limitation; Windows Settings may show one more update than WUU when a Malicious Software Removal Tool release is pending.
- **PS 7 support is best-effort** — WPF/AD assemblies may be limited depending on the PowerShell 7 install; Windows PowerShell 5.1 remains the recommended host.

## Prerequisites

- Windows PowerShell 5.1 (recommended for best WPF compatibility). PowerShell 7+ may work but WPF/AD features can be more limited depending on system components.
- Run as Administrator (required for full functionality).
- PowerShell must run in STA mode (required for WPF): `powershell.exe -STA`.
- Target computers: admin rights for the account running WUU (or the configured custom credentials), and WMI/DCOM reachable through the firewall. No PsExec, SMB admin share, or WinRM listener is needed for check/download/install.

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
