# WUU2 v1.3.1-beta.3 — Timeout state machine + PsExec removal (Beta)

**Pre-release for testing.** Third beta of the 1.3.1 line: adds recoverable timeouts, a State column, automatic search retries, and removes the PsExec dependency entirely.

## What's new

### Timeout is no longer failure
Windows Update operations are slow by nature. A timeout now marks a computer **Timeout** (yellow row) instead of **Error** (grey), and is treated as recoverable:

- WUA session-create and update-search timeouts **auto-retry up to 2 times, 60 seconds apart** — the row stays Timeout and re-queues itself via the scheduler. A manual Check For Updates resets the retry budget.
- A background job killed after 10 minutes now shows Timeout (yellow), matching the in-script timeout styling — it used to be grey.
- Phase gating treats timed-out computers as settled, so later phases are never blocked by one slow host.

### New State column in the main list
A canonical pipeline position alongside the free-text Status: `Queued → Connecting → Connected → Checking → Searching → UpdatesFound → Downloading → Installing → RebootRequired → Rebooting → Connected → Complete`, plus `Timeout` and `Error`. Status keeps the detail (counts, sizes, titles); State answers "where is it in the process" at a glance.

### PsExec removed — download/install via SYSTEM scheduled task
Remote download and install no longer copy a script to the target's C: drive and invoke `psexec.exe`. Instead:

- `Invoke-WuuRemoteTask` (new) registers a **one-off SYSTEM scheduled task** under `\WUU2\` on the target over the same **DCOM/WMI CIM session** used for everything else — no WinRM, no SMB admin share, no psexec.exe, no PSTools download prompt on first run.
- The script is delivered inline (`-EncodedCommand`), not copied via the admin share.
- The remote scripts report **live per-update progress** (`Installing 2/5: KB503…` in the Status column) through `HKLM\SOFTWARE\WUU2\Jobs\<RunId>`, read back over WMI.
- The separate PsExec reboot check is gone — the install result carries `RebootRequired` itself.
- **Configured custom credentials are now honored for download/install** (PsExec ignored them).
- Leftover `\WUU2\` tasks from interrupted runs (GUI closed mid-operation) are reaped on the next run; nothing is left behind (an empty `\WUU2` Task Scheduler folder may remain on targets).

**New target requirement:** Windows 8 / Server 2012 or later (Task Scheduler WMI provider). Windows 7 targets are no longer supported for download/install.

### Under the hood
- `Get-SystemPerformance` is now bounded (was the last unbounded CIM call).
- `Invoke-CimWithTimeout` retries once after auto-recovery on RPC-class errors (0x800706ba/0x800706be).
- Reboot flow: after the computer comes back online the row shows `Connected` instead of staying on "Waiting for computer to come online" for manual restarts.

## Testing focus

1. **Download/install on a real target VM** — the localhost test (`tests/Test-RemoteTask.ps1`, run elevated) covers the mechanism; only a real machine covers the DCOM connection, firewall, credentials, and a live WUA run. Watch the Status column for per-update progress, then confirm no `\WUU2` tasks or `HKLM\SOFTWARE\WUU2\Jobs` keys remain on the target.
2. **Timeout → retry flow** — point at an unresponsive host: Timeout (yellow) → 60s wait → auto-retry ×2 → stays Timeout (never Error). Manual retry still works.
3. **State column** — a full check/download/install/reboot cycle should walk the states in order; phases must still gate correctly around Timeout rows.
4. **Regressions** — auto download/install/reboot toggles, custom credentials, remote service Start/Stop/Restart menu actions (still use WinRM, unchanged).

## Verification already performed

- All syntax checks pass on every changed file
- 39/39 `Validate-Release.ps1` checks pass
- All regression tests pass: module import, cross-module resolution, pending drain, worker pool, remote helpers, log fault tolerance
- `tests/Test-RemoteTask.ps1` (new, elevated, localhost): registry result round-trip, progress callbacks, error surfacing, isolated-runspace injection, no leftover tasks/registry keys — 6/6 pass

## Compatibility

- Windows PowerShell 5.1, elevated, STA (unchanged)
- Controller needs: admin locally; targets need WMI/DCOM reachable + admin rights on the target (or configured custom credentials)
- No configuration changes; drop-in replacement for beta.2
- **Breaking**: Windows 7 / Server 2008 R2 targets can no longer be downloaded to or installed on (update checks still work)
