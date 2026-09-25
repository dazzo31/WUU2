# WUU2 Implementation Plan — Timeout Handling & State Machine Visibility

**Date**: 2026-09-24
**Status**: APPROVED — Ready for phased implementation
**Supersedes**: WUU2 Auto-Toggle Functionality Analysis (2026-09-23 — investigation only, code confirmed functional)

---

## Executive Summary

Auto Download / Auto Install / Auto Reboot toggles are **functionally correct** (verified in prior analysis). The user's "not reliable" complaint is actually **state visibility** and **timeout classification**:

1. **No visible state machine** — user can't tell "still working" from "hung"
2. **Timeout collapses to Error** — grey row says "failed" when actually "still going, just slow"
3. **One unbounded hang exists** — `Get-SystemPerformance` has no timeout wrapper

**User directive**: *"Don't make timeout mean failure. This is particularly important for Windows Update."*
**User directive**: *"state visibility is probably more valuable than another 20 features"*

---

## Implementation Approach

5 phases (A–E), each independently testable. No refactoring, only additive changes.
All timeouts use **linear backoff**, **no performance gain targets**, **default auto-recovery budget = 1 attempt**.

---

## Phase A — Make Timeout a First-Class Status (groundwork)

**Goal**: Distinguish `Timeout` from `Error` at every callsite. Recovery still possible on Timeout.

### A.1 — Add global timeout configuration
**File**: `src/Wuu.Core.psm1`, `#region Configuration` (around line 89)

Insert AFTER existing `$global:sessionTimeout/searchTimeout/rebootCheckTimeout` block:

```powershell
# Timeout settings for remote probes and bounded operations (seconds)
# Increased from previous hardcoded values to handle slow networks
$global:CimTimeoutSeconds         = 10   # was hardcoded 5 in Remote/Credentials probes
$global:ServiceTimeoutSeconds     = 10   # was hardcoded 5
$global:PerformanceTimeoutSeconds = 60   # was unbounded raw CIM - now bounded
$global:CredProbeTimeoutSeconds   = 10   # was hardcoded 5 in WindowsUpdate runspace
$global:RebootProbeTimeoutSeconds = 10   # online probe inside reboot wait (unchanged)
$global:OfflineWaitSeconds        = 600  # was hardcoded inline
$global:OnlineWaitSeconds         = 1800 # was hardcoded inline
```

**Verification**: `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1` — module loads without syntax errors.

### A.2 — Add context injection for new timeout values
**File**: `src/Wuu.Core.psm1`, function `Initialize-WuuWindowsUpdateContext` (around line 4326)

```powershell
$ctx = @{
    # ...existing properties...
    SearchTimeout               = $global:searchTimeout
    SessionTimeout              = $global:sessionTimeout
    RebootCheckTimeout          = $global:rebootCheckTimeout
    # NEW
    CimTimeoutSeconds           = $global:CimTimeoutSeconds
    ServiceTimeoutSeconds       = $global:ServiceTimeoutSeconds
    PerformanceTimeoutSeconds   = $global:PerformanceTimeoutSeconds
    CredProbeTimeoutSeconds     = $global:CredProbeTimeoutSeconds
    RebootProbeTimeoutSeconds   = $global:RebootProbeTimeoutSeconds
    OfflineWaitSeconds          = $global:OfflineWaitSeconds
    OnlineWaitSeconds           = $global:OnlineWaitSeconds
}
```

### A.3 — Inject values into per-computer runspaces
**File**: `src/Wuu.WindowsUpdate.psm1`, function `New-ComputerRunspace` (around line 50)

Update the runspace `$initScript` parameters and assignment to include the seven new timeout values from `$ctx`.

**Verification**: PSScriptAnalyzer clean on both files.

### A.4 — Create `Set-ComputerTimeout` helper
**File**: `src/Wuu.Core.psm1` (add as new function near other `Set-Computer*` helpers)

```powershell
function Set-ComputerTimeout {
    <#
    .SYNOPSIS
    Marks a computer's operation as timed out WITHOUT marking it as error.
    Distinguishes recoverable timeouts from terminal errors in the UI.
    .PARAMETER Computer - ListView row object to update
    .PARAMETER Phase - What operation timed out (e.g., 'WUA Session', 'Update Search', 'Reboot Wait')
    .PARAMETER TimeoutSec - The timeout duration that was exceeded
    .PARAMETER Detail - Additional context (optional)
    #>
    param(
        [Parameter(Mandatory)][object]$Computer,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][int]$TimeoutSec,
        [Parameter(Mandatory=$false)][string]$Detail = ''
    )

    $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
        $uiHash.Listview.Items.EditItem($Computer)
        $Computer.TimeoutExpiresAt = [DateTime]::Now.AddSeconds($TimeoutSec)
        $Computer.TimeoutSource = $Phase
        $Computer.UpdatesStatus = 'Timeout'
        $detailSuffix = if($Detail){ " $Detail" } else { '' }
        $Computer.Status = "Timeout during $Phase after ${TimeoutSec}s — continuing to monitor.$detailSuffix"
        $uiHash.Listview.Items.CommitEdit()
    })
}
```

Export via `Export-ModuleMember` at the end of Wuu.Core.psm1.

### A.5 — Wire timeout detection at existing catch sites
Search for `throw ".*timed out.*"` in:
- `src/Wuu.Core.psm1` (~lines 1707, 1784, 1808, 1857, 2216)
- `src/Wuu.WindowsUpdate.psm1` (~line 462 — `Start-UpdateCheckJob` catch)

At each throw site OR its upstream catch:
- Where `$_.Exception.Message -match 'timed out|timeout'` → call `Set-ComputerTimeout` instead of setting Error status
- Keep the throw if it's needed for flow control, but ensure the caller's catch block calls `Set-ComputerTimeout`

**Key principle**: Timeout ≠ Error. Timeout → yellowish "still recoverable" UI state.

**Verification**: Run smoke test — `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1`

---

## Phase B — Fix Unbounded `Get-SystemPerformance` Hang

**Goal**: Wrap the last unbounded CIM call in a pool-bounded timeout.

**File**: `src/Wuu.Network.psm1`, function `Get-SystemPerformance` (lines 41-97)

**Changes**:
1. Wrap the two `Get-CimInstance -CimSession $cimSession` blocks (~lines 59-66 and 73-80) in `Invoke-WithPoolTimeout`
2. Use `TimeoutSeconds = $ctx.PerformanceTimeoutSeconds`
3. Return `Status = 'Timeout: Perf queries timed out after X seconds'` on timeout (NOT `Error:...`)
4. Preserve existing `finally { Remove-CimSession }` pattern

**Verification**:
- Run `tests/Test-RemoteHelpers.ps1`
- Manual smoke: launch app, add a slow/unreachable host, observe `PerformanceHash` shows 'Timeout', not 'Error'

---

## Phase C — Auto-Recovery Hook on RPC Timeouts

**Goal**: When `Invoke-CimWithTimeout` fails with RPC errors (`0x800706ba`, `0x800706be`), attempt existing `Invoke-AutoRecovery` once before giving up.

**File**: `src/Wuu.Remote.psm1`, function `Invoke-CimWithTimeout` (around line 7)

**Changes**:
- In the error handling block:
  ```powershell
  if ($_.Exception.HResult -in 0x800706ba, 0x800706be) {
      Write-DebugLog "RPC timeout detected for $ComputerName, attempting auto-recovery" -Level 'WARN'
      try {
          & $InvokeAutoRecoveryScript -ComputerName $ComputerName
      } catch {
          # Recovery failed, fall through
      }
  }
  ```

**Budget**: 1 attempt (per "no performance gain" directive).

**File**: `src/Wuu.WindowsUpdate.psm1`, `GetRemoteCredentialsScript` (around line 280)
- If both custom and default credential probes time out, call `$InvokeAutoRecoveryScript` (already injected) once, then retry default credential probe once
- Keep existing fallback logic intact

**Verification**: `tests/Test-RemoteHelpers.ps1` still passes.

---

## Phase D — State Machine Visibility (THE USER-FACING VALUE)

**Goal**: Add a `State` column to ListView showing progression through the Windows Update pipeline.

States (in order):
`Queued → Connecting → Connected → Checking → Searching → UpdatesFound → Downloading → Installing → RebootRequired → Rebooting → Verifying → Complete`
Plus: `Timeout` (recoverable), `Error` (terminal)

### D.1 — Add `State` property to ListView rows + XAML column
**File**: `src/Wuu.Core.psm1` — find where ListView row PSCustomObject is created (near `Add-Computer` wiring), add `State = 'Queued'` to the properties.

**File**: `ui/MainWindow.xaml` — add a `State` GridViewColumn between `Status` and `UpdatesStatus`:

```xml
<GridViewColumn Header="State" Width="100" DisplayMemberBinding="{Binding State}"/>
```

### D.2 — Create `Set-ComputerState` helper
**File**: `src/Wuu.Core.psm1`

```powershell
function Set-ComputerState {
    <#
    .SYNOPSIS
    Updates a computer's State and Status consistently.
    #>
    param(
        [Parameter(Mandatory)][object]$Computer,
        [Parameter(Mandatory)][ValidateSet('Queued','Connecting','Connected','Checking','Searching','UpdatesFound','Downloading','Installing','RebootRequired','Rebooting','Verifying','Complete','Timeout','Error')][string]$State,
        [Parameter(Mandatory=$false)][string]$StatusDetail = ''
    )

    $stateToStatus = @{
        'Queued'          = 'Waiting to start...'
        'Connecting'      = 'Testing Connectivity.'
        'Connected'       = 'Online.'
        'Checking'        = 'Initializing update session...'
        'Searching'       = 'Checking for updates...'
        'UpdatesFound'    = 'Updates found.'
        'Downloading'     = 'Downloading updates...'
        'Installing'      = 'Installing updates...'
        'RebootRequired'  = 'Reboot required.'
        'Rebooting'       = 'Restarting...'
        'Verifying'       = 'Verifying post-reboot state...'
        'Complete'        = 'All updates installed.'
        'Timeout'         = 'Operation timed out (recoverable).'
        'Error'           = 'Error occurred.'
    }

    $statusString = $stateToStatus[$State]
    if ($StatusDetail) {
        $statusString += " $StatusDetail"
    }

    $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
        $uiHash.Listview.Items.EditItem($Computer)
        $Computer.State = $State
        $Computer.Status = $statusString
        $uiHash.Listview.Items.CommitEdit()
    })

    Write-DebugLog "[$($Computer.Computer)] State -> $State : $statusString" -Level 'DEBUG'
}
```

Export via `Export-ModuleMember`.

### D.3 — Replace ~25 `$Computer.Status = '...'` callsites with `Set-ComputerState` calls

**File**: `src/Wuu.Core.psm1`

Use the mapping table:

| Existing status literal | New State | StatusDetail |
|---|---|---|
| "Testing Connectivity." | Connecting | (none) |
| "Online." | Connected | (none) |
| "Checking for Updates." / "Initializing update session..." | Checking | (none) |
| "Searching for Updates." / "Checking for updates..." | Searching | (none) |
| "N update(s) found." | UpdatesFound | "($N)" |
| "Auto-downloading..." / "Downloading..." | Downloading | Count if available |
| "Auto-installing..." / "Installing..." | Installing | Count if available |
| "Reboot required." / "N of M update(s) downloaded. Reboot required." | RebootRequired | "($N of $M)" |
| "Restarting... Waiting for computer to shutdown." | Rebooting | "(offline wait)" |
| "Restarting... Waiting for computer to come online." | Rebooting | "(online wait)" |
| "Waiting for previous phase to complete..." | Queued | (none) |
| "All updates installed" | Complete | (none) |
| Timeout throws (from Phase A) | Timeout | (auto via Set-ComputerTimeout) |
| Exception catch sets | Error | Error message |

**Verification**: Launch GUI, watch State column populate through a check cycle.

### D.4 — Update `Test-PhaseCompletion` to accept `State -eq 'Timeout'` as settled
**File**: `src/Wuu.WindowsUpdate.psm1`, `Test-PhaseCompletion` (~line 445)

Add `State -eq 'Timeout'` to the settle-check condition so a timed-out computer doesn't block the next phase indefinitely.

---

## Phase E — Timeout Means "Keep Watching" (Retry)

**Goal**: WUA search and session-create timeouts get up to 2 retries, 60s linear backoff.

**File**: `src/Wuu.Core.psm1`, `$GetUpdates` ScriptBlock + job cleanup loop

After `Set-ComputerTimeout` fires for WUA session-create or search:

```powershell
if ($Computer.RetryCount -lt 2) {
    $Computer.RetryCount += 1
    $retryJob = [PSCustomObject]@{
        Type        = 'RetrySearch'
        Computer    = $Computer
        DelaySec    = 60
        ScheduledAt = [DateTime]::Now
        Attempt     = $Computer.RetryCount
    }
    # Append to $jobs (job cleanup loop picks it up)
    [void]$jobs.Add($retryJob)
}
```

In the job cleanup runspace (~lines 2200-2250), add a handler for `Type -eq 'RetrySearch'`:
- If `([DateTime]::Now - $retryJob.ScheduledAt).TotalSeconds -ge $retryJob.DelaySec`, re-queue the search for that computer
- Otherwise skip this iteration

**Cap**: Max 2 retries. Row stays in `Timeout` state if both fail. Manual retry still available.

**Reboot waits do NOT retry** — already have 600s/1800s horizons built in.

**Verification**: Manual test with unresponsive host — observe Timeout → 60s wait → auto-retry → Timeout again → row stays Timeout (not Error).

---

## Files Modified Summary

| File | Phases | Nature of changes |
|---|---|---|
| `src/Wuu.Core.psm1` | A.1, A.2, A.4, A.5, D.1, D.2, D.3, E | Config, context, helpers, ~25 callsites, retry logic |
| `src/Wuu.WindowsUpdate.psm1` | A.3, A.5, C, D.4 | Runspace injection, catch wiring, phase completion |
| `src/Wuu.Network.psm1` | B | Pool-bounded performance queries |
| `src/Wuu.Remote.psm1` | C | Auto-recovery hook on RPC errors |
| `ui/MainWindow.xaml` | D.1 | Add State column |

---

## Files NOT to Modify

Per [.github/copilot-instructions.md](../.github/copilot-instructions.md):

- All `WUU_backup*.ps1`, `WUU_v1.1.ps1`, `WUU_debug.ps1`, `WUU_perplexity.ps1`, `WUU_git_version.ps1`, `WUU_backup_*.xaml` — historical snapshots
- `dist/` and `dist/staging/` — packaged output
- New helper script files (recovery uses existing `Invoke-AutoRecovery`)

---

## Success Criteria

- [ ] All 39 validation checks pass: `Scripts\Validate-Release.ps1`
- [ ] Module loads without syntax errors: `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1`
- [ ] Module import test passes: `tests\Test-ModuleImport.ps1`
- [ ] PSScriptAnalyzer clean on edited files
- [ ] GUI launches, new State column visible
- [ ] Unreachable host shows `State=Timeout` (NOT Error grey)
- [ ] Successful cycle ends at `State=Complete`
- [ ] Performance queries bounded (no indefinite hang)
- [ ] `Test-PhaseCompletion` advances when a row is Timeout
- [ ] WUA search timeout auto-retries once after 60s

---

## Out of Scope (This Round)

- Formal state machine refactor of runspaces
- Progress bars / percentages
- Toggle persistence, notifications, export/import (future enhancements — see future-implementations.md)

---

## Implementation Order

| Step | Phase | Verification |
|---|---|---|
| 1 | A.1 config block | Module loads |
| 2 | A.2 context injection | No behavior change |
| 3 | A.3 runspace injection | No syntax errors |
| 4 | A.4 Set-ComputerTimeout helper | Function exists, no callers yet |
| 5 | A.5 Wire catch sites | Smoke test passes |
| 6 | B — Get-SystemPerformance | Test-RemoteHelpers passes |
| 7 | C — Auto-recovery hook | Test-RemoteHelpers passes |
| 8 | D.1 — Add State property + XAML | GUI shows State column |
| 9 | D.2 — Set-ComputerState helper | Function exists |
| 10 | D.3 — Replace ~25 callsites | State column populates |
| 11 | D.4 — Test-PhaseCompletion | Phase advances on Timeout |
| 12 | E — Retry logic | Manual test with slow host |

After all phases:
- `Scripts\Validate-Release.ps1` (must be 39/39)
- Full manual smoke: AutoDownload + AutoInstall + AutoReboot on 2+ computers

---

## Current State — Handoff to qwen3.5 (as of 2026-09-24)

### Completed by Copilot (kimi-k3:cloud)

| Phase | What changed | Files touched |
|---|---|---|
| A.1 | Added 7 `$global:*TimeoutSeconds` config vars | `src/Wuu.Core.psm1` |
| A.2 | Added the 7 vars to `$wuuContext` hash | `src/Wuu.Core.psm1` |
| A.3 | Injected them via `SessionStateProxy.SetVariable` in runspaces | `src/Wuu.WindowsUpdate.psm1` |
| A.4 | `Set-ComputerState` + `Set-ComputerTimeout` module functions + runspace scriptblock twins (`SetComputerStateScript`, `SetComputerTimeoutScript`) | `src/Wuu.Core.psm1`, `src/Wuu.WindowsUpdate.psm1` |
| A.5 partial | Routed timeouts through `SetComputerTimeoutScript` in `$GetUpdates` and `$RestartComputer` outermost catches | `src/Wuu.Core.psm1` |
| B | `Get-SystemPerformance` now pool-bounded via `Invoke-WithPoolTimeout` with `$global:PerformanceTimeoutSeconds` guard | `src/Wuu.Network.psm1` |
| C | `Invoke-CimWithTimeout` retries once after `Invoke-AutoRecovery` on HResult 0x800706ba/0x800706be | `src/Wuu.Remote.psm1` |
| D.1 | `State` GridViewColumn added to XAML; `State = 'Queued'` in all three PSCustomObject row creation sites | `ui/MainWindow.xaml`, `src/Wuu.Core.psm1` |

Plus `scripts/_syntax-check.ps1` for quick per-file parse verification.

### Remaining for qwen3.5 (in order)

1. **Phase D.3 sweep** — replace direct `$Computer.Status = '...'` assignments in `src/Wuu.Core.psm1` with `& $SetComputerStateScript` calls (worker) or `Set-ComputerState` calls (UI thread). See mapping table in this doc (section D.3). ~24 sites total. Excluded: catch blocks that already use Set-ComputerTimeout, lines that set `$computer.State = 'Error'`.
2. **Phase D.4** — `Test-PhaseCompletion` already treats `UpdatesStatus -in 'Error','Timeout'` as settled (verified at line ~574 of `src/Wuu.WindowsUpdate.psm1`). No change needed — just confirm by reading the function.
3. **Phase E** — Add the `'RetrySearch'` retry scheduling in `$GetUpdates`'s catch (the one already calling `SetComputerTimeoutScript`), then handle `'RetrySearch'` in the job-cleanup runspace (~line 2400 of `src/Wuu.Core.psm1`).
4. **Validation** — after every edit run `scripts\_syntax-check.ps1 -Path <file>`; at the end run `Scripts\Validate-Release.ps1` (must be 39/39).

### Critical runspace gotcha (already correct in code — don't regress)

`$GetUpdates` / `$InstallUpdates` / `$DownloadUpdates` / `$RestartComputer` run in **isolated runspaces**. Module functions like `Set-ComputerTimeout` do NOT resolve there. Always call the injected scriptblock:

```powershell
if ($SetComputerTimeoutScript) {
    & $SetComputerTimeoutScript -Computer $Computer -Phase $Phase -TimeoutSec $T
} else {
    Set-ComputerTimeout -Computer $Computer -Phase $Phase -TimeoutSec $T
}
```

Same pattern for `SetComputerStateScript`.

---

## Q&A Resolved

- **Retry backoff**: Linear 60s (NOT exponential) — per user "Linear backoff, no performance gain"
- **PerformanceHash gets State?**: No — State applies only to main ListView rows; PerformanceHash stays as raw metrics
- **Auto-recovery retry budget**: 1 attempt (default, per user "keep the default auto-recovery budget")
