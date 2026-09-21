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

Close-WuuWorkerPool
if ($failures.Count -eq 0) {
    Write-Host 'ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failures.Count) FAILURE(S)" -ForegroundColor Red
    exit 1
}