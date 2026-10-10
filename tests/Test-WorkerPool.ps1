#Requires -Version 5.1
<#
.SYNOPSIS
Regression test for src/Wuu.Workers.psm1 (runspace pool).
.DESCRIPTION
Mirrors the app's import topology (Import-Module -Global, like
Import-WuuModules). Verifies:
  1. Pool self-check (bounded success + bounded timeout)
  2. Live CIM-style probe (returns real data)
  3. Multi-positional argument binding (Start-Job -ArgumentList semantics)
  4. $null single argument is still bound (not swallowed)
  5. Concurrent submissions do not interfere (pool reuse)
  6. New-PooledInvokeScript works in an isolated runspace
     (the exact environment per-computer workers use)
Exit code 0 = all pass, 1 = failure.
#>
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$failures = @()
function Assert-True([bool]$Condition, [string]$Name) {
    if ($Condition) {
        Write-Host "PASS: $Name" -ForegroundColor Green
    } else {
        Write-Host "FAIL: $Name" -ForegroundColor Red
        $script:failures += $Name
    }
}

Import-Module (Join-Path $RepoRoot "src\Wuu.Workers.psm1") -Global -ErrorAction Stop

# 1. Self-check: bounded success + bounded timeout
Assert-True (Test-WuuWorkerPool) 'pool self-check (success + timeout paths)'

# 2. Live probe returning real data
$r = Invoke-WithPoolTimeout -ScriptBlock { param($c)
    $d = Get-Date -Format 'HH:mm:ss.fff'
    $d } -ArgumentList 'localhost' -TimeoutSeconds 8 -OperationName 'live probe'
Assert-True ($r.Success -and $r.Result) "live probe returns data ($($r.Result))"

# 3. Multi-positional binding
$multi = Invoke-WithPoolTimeout -ScriptBlock { param($a, $b) "$a::$b" } `
    -ArgumentList @('x', 'y') -TimeoutSeconds 8
Assert-True ($multi.Success -and $multi.Result -eq 'x::y') 'multi-argument binding'

# 4. $null argument must bind as a parameter, not be swallowed
$nullArg = Invoke-WithPoolTimeout -ScriptBlock { param($n)
    if ($null -eq $n) { 'null-bound-ok' } else { 'not-null' } } `
    -ArgumentList $null -TimeoutSeconds 8
Assert-True ($nullArg.Success -and $nullArg.Result -eq 'null-bound-ok') '$null argument binds as parameter'

# 5. Concurrent submissions (fire 4 short jobs, all must return their own value)
$results = 1..4 | ForEach-Object {
    Invoke-WithPoolTimeout -ScriptBlock { param($i) Start-Sleep -Milliseconds (50 * $i); "done-$i" } `
        -ArgumentList $_ -TimeoutSeconds 10 -OperationName "concurrent-$_"
}
$concurrentOk = ($results | Where-Object { -not $_.Success -or $_.Result -notlike 'done-*' }).Count -eq 0
Assert-True $concurrentOk '4 concurrent submissions all return own results'

# 6. New-PooledInvokeScript inside an ISOLATED runspace (mirrors per-computer workers)
$pool = Get-WuuWorkerPool
$invokeScript = New-PooledInvokeScript
$iso = [runspacefactory]::CreateRunspace([System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault())
$iso.ApartmentState = 'STA'
$iso.Open()
$iso.SessionStateProxy.SetVariable('WuuWorkerPool', $pool)
$iso.SessionStateProxy.SetVariable('InvokePooledScript', $invokeScript)
$isoPs = [powershell]::Create()
$isoPs.Runspace = $iso
[void]$isoPs.AddScript({
    # This body CANNOT see module functions - only injected variables.
    & $InvokePooledScript -Pool $WuuWorkerPool `
        -ScriptBlock { param($n) "iso-$($n * 2)" } `
        -ArgumentList 21 -TimeoutSeconds 8 -OperationName 'iso probe'
})
$isoHandle = $isoPs.BeginInvoke()
if ($isoHandle.AsyncWaitHandle.WaitOne([System.TimeSpan]::FromSeconds(15))) {
    $isoResult = $isoPs.EndInvoke($isoHandle)
    $isoOk = ($isoResult -and $isoResult.Count -gt 0 -and $isoResult[0].Success -and $isoResult[0].Result -eq 'iso-42')
} else { $isoOk = $false }
Assert-True $isoOk 'isolated runspace + injected script resolves pool (worker topology)'
try { $isoPs.Dispose() } catch { }
try { $iso.Close(); $iso.Dispose() } catch { }

# 7. Close-WuuWorkerPool is BOUNDED and idempotent. Teardown must always return within its deadline
#    (a pool can hold a pipeline wedged in an uninterruptible native probe), and a second call must be
#    a safe no-op. The pool then re-opens LAZILY, so a close is not permanent for the process.
$swClose = [Diagnostics.Stopwatch]::StartNew()
$closeResult = Close-WuuWorkerPool -TimeoutSeconds 15
$swClose.Stop()
Assert-True ($closeResult) 'the pool closes within its deadline (returns $true when it closed)'
Assert-True ($swClose.Elapsed.TotalSeconds -lt 20) "the close returned promptly ($([math]::Round($swClose.Elapsed.TotalSeconds,1))s, bound 15s + margin)"
Assert-True (Close-WuuWorkerPool -TimeoutSeconds 5) 'a second close is a safe no-op (idempotent)'

$reopenedPool = Get-WuuWorkerPool
Assert-True ($null -ne $reopenedPool -and $reopenedPool.RunspacePoolStateInfo.State -eq 'Opened') 'the pool re-opens lazily after being closed'
$afterReopen = Invoke-WithPoolTimeout -ScriptBlock { 'reopened-ok' } -TimeoutSeconds 8 -OperationName 'post-close probe'
Assert-True ($afterReopen.Success -and $afterReopen.Result -eq 'reopened-ok') 'a probe still runs after the pool was closed and lazily re-opened'
try { Close-WuuWorkerPool -TimeoutSeconds 15 | Out-Null } catch { }

# 8. APPLICATION SHUTDOWN TEARS THE POOL DOWN, and the teardown order preserves in-flight probes.
#    (a) BEHAVIOURAL: a payload that CAPTURED the pool object (as New-ComputerRunspace does) must get a
#    clean failure after close, not a silent reuse. Invoke-WithPoolTimeout itself re-opens lazily, so the
#    captured-pool path is exercised with the injected New-PooledInvokeScript - the exact mechanism a
#    payload uses.
$oldPool = Get-WuuWorkerPool
$capturedInvoke = New-PooledInvokeScript
$null = & $capturedInvoke -Pool $oldPool -ScriptBlock { 'pre-close' } -TimeoutSeconds 8 -OperationName 'pre-close'
Close-WuuWorkerPool -TimeoutSeconds 15 | Out-Null
$afterCloseCaptured = & $capturedInvoke -Pool $oldPool -ScriptBlock { 'should-not-run' } -TimeoutSeconds 5 -OperationName 'post-close-captured'
Assert-True (-not $afterCloseCaptured.Success) 'a probe against the CAPTURED pool object reports failure after close (in-flight payloads abort cleanly, never silently reuse a closed pool)'

#    (b) ORDERING: in the tail shutdown, the pool teardown must appear AFTER the per-computer runspace
#    teardown, or an in-flight payload that captured the pool object would have its pooled probes abort.
$coreShutdownSrc = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'src\Wuu.Core.psm1'))
$runspaceTeardownIdx = $coreShutdownSrc.IndexOf('Cleaning up $($runspacesToClose.Count) computer runspace(s)')
$poolTeardownIdx = $coreShutdownSrc.IndexOf('Close-WuuWorkerPool -TimeoutSeconds 10')
Assert-True ($runspaceTeardownIdx -ge 0) 'the shutdown closes per-computer runspaces'
Assert-True ($poolTeardownIdx -gt $runspaceTeardownIdx) 'the shutdown closes the shared pool AFTER the per-computer runspaces (in-flight probes are not stranded)'

#    (c) BOTH paths wire a bounded close: the tail (10s) and the window-close handler (5s).
$poolCloseCalls = ([regex]::Matches($coreShutdownSrc, 'Close-WuuWorkerPool\s+-TimeoutSeconds')).Count
Assert-True ($poolCloseCalls -ge 2) "both shutdown paths close the worker pool with a bounded timeout (found $poolCloseCalls of 2)"

# 9. BOUNDED TEARDOWN HELPER (T008.2). The application exit joins per-computer runspaces and the
#    job-cleanup runspace; a pipeline wedged in an uninterruptible native call would otherwise hang the
#    close for ever. Close-WuuBoundedTeardown must (a) run a quick teardown to completion and report
#    success, and (b) ABANDON a wedged one and REPORT the timeout rather than block. The second half is
#    timed, because "it returned" is the property under test.
'=== 9. Close-WuuBoundedTeardown is bounded and reports its outcome ==='

$quick = Close-WuuBoundedTeardown -ScriptBlock { param($x) $null = $x } -ArgumentList 'noop' -TimeoutSeconds 10
Assert-True $quick 'a quick teardown completes and reports success'

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$wedged = Close-WuuBoundedTeardown -ScriptBlock { Start-Sleep -Seconds 60 } -TimeoutSeconds 2
$sw.Stop()
Assert-True (-not $wedged) 'a WEDGED teardown reports failure (abandoned, not hung)'
Assert-True ($sw.Elapsed.TotalSeconds -lt 20) "the wedged teardown RETURNED promptly (took $([math]::Round($sw.Elapsed.TotalSeconds,1))s, deadline 2s) - an unbounded Dispose would hang for ever"

# WIRING: the application exit must USE the bounded helper for the jobs and the per-computer runspaces,
# not raw .Stop()/.Dispose(), or a wedged payload hangs shutdown.
$boundedUses = ([regex]::Matches($coreShutdownSrc, 'Close-WuuBoundedTeardown')).Count
Assert-True ($boundedUses -ge 3) "the shutdown routes its teardown through the bounded helper (found $boundedUses call sites)"

if ($failures.Count -eq 0) {
    Write-Host 'ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failures.Count) FAILURE(S)" -ForegroundColor Red
    exit 1
}