#Requires -Version 5.1
<#
.SYNOPSIS
Regression test for the pool migration of Wuu.Remote.psm1 helpers.
.DESCRIPTION
Mirrors the app's import topology. Verifies against localhost:
  1. Invoke-CimWithTimeout returns real CIM data (Win32_ComputerSystem)
  2. Invoke-ServiceWithTimeout checks wuauserv status
  3. Test-SystemDependencies probes localhost successfully
  4. Hard timeout path still fires (unreachable IP with short timeout)
  5. Pool reuse across helpers (sequential calls share one pool)
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

# Import in app order: Logging first (log functions), then Remote (uses pool),
# then Workers (pool provider) - Workers must precede any module calling it.
Import-Module (Join-Path $RepoRoot "src\Wuu.Logging.psm1") -Global -ErrorAction Stop
Import-Module (Join-Path $RepoRoot "src\Wuu.Workers.psm1") -Global -ErrorAction Stop
Import-Module (Join-Path $RepoRoot "src\Wuu.Remote.psm1") -Global -ErrorAction Stop

# 1. CIM helper with real data
$cim = Invoke-CimWithTimeout -ComputerName localhost -ClassName Win32_ComputerSystem -TimeoutSeconds 15
Assert-True ($cim.Success -and $cim.Result) "CIM helper returns Win32_ComputerSystem data ($($cim.Result.Name))"

# 2. Service helper
$svc = Invoke-ServiceWithTimeout -ComputerName localhost -ServiceName wuauserv -Action Check -TimeoutSeconds 15
Assert-True ($svc.Success) "Service helper checks wuauserv (status: $($svc.Status))"

# 3. System dependencies probe
$deps = Test-SystemDependencies -ComputerName localhost
Assert-True ($deps['RPC']) 'dependency probe reports RPC reachable on localhost'

# 4. Hard timeout still fires (192.0.2.1 is TEST-NET, guaranteed non-routable)
$timeoutTest = Invoke-CimWithTimeout -ComputerName '192.0.2.1' -TimeoutSeconds 3
Assert-True ((-not $timeoutTest.Success) -and ($timeoutTest.Error -like '*timed out*')) "hard timeout fires on unreachable host ($($timeoutTest.Error))"

# 5. Pool reuse - all helpers share the single module pool
$pool1 = Get-WuuWorkerPool
$null = Invoke-CimWithTimeout -ComputerName localhost -ClassName Win32_OperatingSystem -TimeoutSeconds 15
$null = Invoke-ServiceWithTimeout -ComputerName localhost -ServiceName wuauserv -Action Check -TimeoutSeconds 15
$pool2 = Get-WuuWorkerPool
Assert-True ($pool1.InstanceId -eq $pool2.InstanceId) 'pool is reused across helpers (single instance)'

# 6. ENVELOPE CONTRACT (a review claim that turned out FALSE, pinned so it cannot rot into truth).
#    A reviewer asserted the Core-inlined CIM twin reads the wrong envelope level ($cimResult.Success
#    instead of the inner .Result.Success). That is NOT the case: the pool wrapper is Success=$true
#    whenever the scriptblock RAN, and the inner hashtable carries the real verdict - so a FAILED
#    probe is wrapper.Success=$true with inner.Success=$false. Reading only the wrapper WOULD report
#    every failure as success. Pin the real behaviour so a regression that flattens the envelope fails.
$failedProbe = Invoke-CimWithTimeout -ComputerName '192.0.2.1' -TimeoutSeconds 3
Assert-True (-not $failedProbe.Success) 'a FAILED probe reports Success=$false (the inner verdict, not the always-true pool wrapper)'
Assert-True (-not $failedProbe.PSObject.Properties['Result']) 'a failed probe exposes no Result payload (no false success object)'

# 7. THE TWO ENVELOPE SHAPES MUST AGREE. Wuu.Remote's Invoke-CimWithTimeout and Core's inlined copy
#    (defined INSIDE the $GetUpdates payload - it is not a module function) are independent copies of the
#    same unwrap; if one changes its shape the other callers break silently. The Core copy is extracted
#    from the payload source rather than resolved by name.
$remoteCopy = (Get-Command Invoke-CimWithTimeout -CommandType Function).ScriptBlock.ToString()
$corePayloadSrc = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'src\Wuu.Core.psm1'))
$twinMarker = 'function Invoke-CimWithTimeout {'
$twinStart = $corePayloadSrc.IndexOf($twinMarker)
Assert-True ($twinStart -ge 0) 'the Core payload defines its own inlined CIM twin'
$twinBody = ''
if ($twinStart -ge 0) {
    # Brace-walk to the matching close of the twin body.
    $depth = 1
    $i = $twinStart + $twinMarker.Length
    while ($i -lt $corePayloadSrc.Length -and $depth -gt 0) {
        $ch = $corePayloadSrc[$i]
        if ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { $depth-- }
        $i++
    }
    $twinBody = $corePayloadSrc.Substring($twinStart + $twinMarker.Length, $i - $twinStart - $twinMarker.Length - 1)
}
Assert-True ($twinBody -match '\.Result\b') 'the Core inlined twin inspects the nested inner result (does not trust the always-true pool wrapper)'
Assert-True ($twinBody -match 'Success\s*=\s*\$true;\s*Result\s*=\s*\$\w+\.Result') 'the Core inlined twin returns the SAME @{Success;Result} shape as the Wuu.Remote helper'
Assert-True ($remoteCopy -match 'Success\s*=\s*\$true;\s*Result\s*=\s*\$\w+\.Result') 'the Wuu.Remote helper returns the same nested result shape (only the local variable name differs)'

Close-WuuWorkerPool
if ($failures.Count -eq 0) {
    Write-Host 'ALL PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failures.Count) FAILURE(S)" -ForegroundColor Red
    exit 1
}