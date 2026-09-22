# WUU2 v1.3.1-beta.2 — Fault-Tolerant Logging (Beta)

**Pre-release for testing.** Second beta of the 1.3.1 line: adds the logging-crash fix on top of the worker-pool architecture from beta.1.

## Fixes in this beta

### "Stream was not readable" crash (Logging.psm1)
A transient error thrown from the debug-logging write could kill timer ticks and computer-runspace creation:

- **Root cause**: debug logs were written into the repo folder. When the repo lives under **OneDrive**, the sync engine transiently locks log files mid-write (Files-On-Demand placeholder hydration), and PowerShell 5.1's `Add-Content` opens files with restrictive sharing — so the write threw "Stream was not readable". With no error handling on those writes, the failure propagated into callers: every job-timer tick and every "Creating runspace for computer: ..." could die from a background sync hiccup.
- **Fix, layer 1 — logs moved out of the cloud**: the debug log now goes to `%TEMP%` (with an automatic fallback to `%LOCALAPPDATA%\WUU2\Logs` if your TEMP is redirected somewhere synced). Log files are no longer OneDrive placeholders at all.
- **Fix, layer 2 — logging can never crash an operation**: every log write is now fault-tolerant (shared lock + up to 3 attempts with backoff, then silently gives up). This covers the main-session writer, the per-computer worker runspaces, and the job-cleanup loop. A locked or unreadable log file now costs you at most one log line — never an operation.

## Also included (from v1.3.1-beta.1)

- Worker-pool architecture: all bounded remote operations (WMI/CIM probes, service checks, credential tests, reboot online-probes) now run on a shared in-process runspace pool (2–8 workers) instead of spawning a child PowerShell process per probe. Zero `Start-Job` calls remain.

## Testing focus

1. **Long-running sessions** — run a full scan against a large list with debug logging on; watch for any stall or crash that used to correlate with OneDrive activity.
2. **Check the new log location** — status messages report the log path at startup; confirm it now points to `%TEMP%\WUU_Debug_*.log`, and that the "View Update Log" context menu (remote machines' windowsupdate.log) still works.
3. **Regressions from beta.1** — large lists, reboot flow, custom credentials, remote service actions.

## Verification already performed

- `tests/Test-LogFaultTolerance.ps1` — holds an exclusive lock on the log file and proves raw `Add-Content` throws while the new fault-tolerant writer survives and then recovers
- All 6 regression tests pass (module import, cross-module resolution, pending drain, worker pool, remote helpers, log fault tolerance)
- 39/39 `Validate-Release.ps1` checks pass
- Parser clean on all 9 files

## Compatibility

- Windows PowerShell 5.1, elevated, STA (unchanged)
- No configuration changes; drop-in replacement for beta.1