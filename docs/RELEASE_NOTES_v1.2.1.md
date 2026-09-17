# Release v1.2.1 — Remote connectivity fixes

## Fixes

### WMI probe protocol bug (remote computers)

All three remote WMI probes (`Invoke-CimWithTimeout` main helper, the
runspace-local copy inside `GetUpdates`, and the credential test probe)
used `Get-CimInstance -ComputerName` for the **default-credentials path**.
That parameter set connects over **WinRM/WSMAN (TCP 5985)** — not DCOM.

The alternate-credentials path already used a DCOM `New-CimSession`
(matching the legacy `Get-WmiObject` behavior), so hosts without a WinRM
listener — which previously worked fine in v1.1 — started failing the
"Testing WMI connectivity" step with a misleading
`WMI connectivity test timed out after 5 seconds` error.

**Fixed:** both credential paths now build a DCOM CIM session
(`New-CimSession -SessionOption (New-CimSessionOption -Protocol DCOM)`),
restoring the legacy DCOM/WMI transport for default credentials. No new
firewall ports are required; the standard WMI/DCOM rules
(TCP 135 + dynamic RPC ports) that older versions relied on are enough.

### Windows Update service pre-flight made non-fatal

The pre-update-check status query of the remote `wuauserv` service
ran through a nested background job with a 5-second cap. On slow or busy
hosts the query can exceed that cap, and the resulting `throw` aborted
the whole update check with:

    Error occurred: After 3 attempts: Unknown error.

**Fixed:**
- The `wuauserv` status check and the best-effort auto-start attempt are
  now **non-fatal** — failures are logged as warnings and the check
  continues. `wuauserv` is a demand-start service; the Windows Update COM
  search starts it automatically when needed, so the pre-flight is only
  a nicety. (Previous WUU versions never queried the service remotely at
  all.)
- The `Check` action of `Invoke-ServiceWithTimeout` now performs a direct
  remote SCM query (`Get-Service -ComputerName`) instead of spawning a
  nested PowerShell background job.

### "Unknown error" for timeouts

The error-suggestions map only contained the key `'timeout'`, which
does not match messages containing **"timed out"** (two words). Retries
and the final failure therefore reported `Unknown error` instead of
`Operation timed out` with actionable suggestions. A `'timed out'` key
was added to the map.

---

**Upgrade notes:** none — drop-in replacement for v1.2.0. If remote
computers previously failed at "Testing WMI connectivity" or
"Testing Windows Update service", re-run the check after upgrading.