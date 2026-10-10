# Test: D10 — the RPC-recovery path must be reachable and its input must be machine-readable.
#
# WHY THIS SUITE EXISTS
# ---------------------
# `Invoke-CimWithTimeout` has an RPC-recovery branch (0x800706ba / 0x800706be) that restarts RpcSs on
# the target and retries once. It had TWO independent defects, and either alone was enough to make it
# dead code:
#
#   1. RESOLUTION. It called `Invoke-AutoRecovery` unqualified, but that function lives in Wuu.Core
#      (private) and Wuu.Remote did not export or define one. Module scope does not see another
#      module's privates, so the call could never resolve - and `-ErrorAction SilentlyContinue` hid it.
#   2. CODE EXTRACTION. It matched an `0x…` HRESULT out of the error MESSAGE. Measured on a genuine
#      failure, the message is the localized sentence 'The RPC server is unavailable.' with no hex
#      code in it, so `$hresult` stayed $null and the branch was skipped even had it resolved.
#
# The assertions below pin BOTH halves, because fixing either one alone leaves the branch dead - which
# is exactly how it survived review the first time.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-RecoveryPath.ps1

$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$ErrorActionPreference = 'Continue'

$script:pass = 0
$script:fail = 0
function Assert-True($Condition, $Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "FAIL: $Name" -ForegroundColor Red; $script:fail++ }
}
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host ("FAIL: {0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:fail++ }
}

Import-Module (Join-Path $repo 'src\Wuu.Core.psm1') -ErrorAction Stop
Import-WuuModules -WuuRoot $repo | Out-Null

# ---------------------------------------------------------------------------------------------
# 1. RESOLUTION (defect 1). The function must be visible from the module that actually calls it.
# ---------------------------------------------------------------------------------------------
'=== 1. Invoke-AutoRecovery is resolvable from Wuu.Remote ==='

$exported = Get-Command -Module Wuu.Remote -Name Invoke-AutoRecovery -ErrorAction SilentlyContinue
Assert-True ($null -ne $exported) 'Wuu.Remote exports Invoke-AutoRecovery'

# The real test: resolve it INSIDE the Wuu.Remote module scope, which is where the call is made.
# A function in the global session would not help if the module scope cannot see it.
$remoteModule = Get-Module Wuu.Remote
Assert-True ($null -ne $remoteModule) 'Wuu.Remote is loaded'
if ($remoteModule) {
    $inScope = & $remoteModule { Get-Command Invoke-AutoRecovery -ErrorAction SilentlyContinue }
    Assert-True ($null -ne $inScope) 'Invoke-AutoRecovery resolves in the Wuu.Remote module scope (not merely in the session)'
}

# ---------------------------------------------------------------------------------------------
# 2. INPUT NORMALIZATION. The switch patterns are bare hex; a prefixed or sentence-form input must
#    still reach them. This is the half the CLI edition got wrong on its first attempt.
# ---------------------------------------------------------------------------------------------
''
'=== 2. the error code is normalized before the switch ==='

# 800706be is the branch that returns $true WITHOUT mutating any service (it only waits), so it is
# safe to drive on the local machine. 800706ba restarts RpcSs and is deliberately NOT exercised.
$fromBare  = Invoke-AutoRecovery -ComputerName 'localhost' -ErrorCode '800706be'
$fromHex   = Invoke-AutoRecovery -ComputerName 'localhost' -ErrorCode '0x800706BE'
$fromText  = Invoke-AutoRecovery -ComputerName 'localhost' -ErrorCode 'The RPC server failed'

Assert-True ([bool]$fromBare) "bare hex '800706be' is recognized (returned $fromBare)"
Assert-True ([bool]$fromHex)  "prefixed hex '0x800706BE' is recognized (returned $fromHex)"
Assert-True ([bool]$fromText) "a sentence form reaches the switch via normalization (returned $fromText)"

# ---------------------------------------------------------------------------------------------
# 3. REFUSAL. Non-RPC failures must NOT trigger a service restart. This is the safety property: a
#    credentials problem must not be 'fixed' by restarting RpcSs on a production host.
# ---------------------------------------------------------------------------------------------
''
'=== 3. non-recoverable errors are refused without touching the target ==='

$accessDenied = Invoke-AutoRecovery -ComputerName 'localhost' -ErrorCode '80070005'
$unknown      = Invoke-AutoRecovery -ComputerName 'localhost' -ErrorCode 'completely unknown error'

Assert-True (-not $accessDenied) 'Access Denied (80070005) is NOT auto-recovered'
Assert-True (-not $unknown) 'an unknown error is NOT auto-recovered'

# An empty code is REFUSED AT BINDING, not treated as an error to fix. Assert both that it throws and
# that nothing was recovered. (An earlier version of this test wrapped the call in a bare assignment;
# the throw aborted the line, $empty stayed $null, and `-not $empty` then PASSED - an assertion that
# was green because the call never completed. Asserting the throw explicitly is the difference.)
$emptyThrew = $false
$emptyResult = $null
try { $emptyResult = Invoke-AutoRecovery -ComputerName 'localhost' -ErrorCode '' }
catch { $emptyThrew = $true }
Assert-True $emptyThrew 'an empty error code is refused at parameter binding (it is not "recovered")'
Assert-True (-not $emptyResult) 'and nothing was recovered as a result of the empty code'

# ---------------------------------------------------------------------------------------------
# 4. THE STRUCTURED CODE SURVIVES THE WORKER. This is the property that makes the branch work on a
#    localized system: HResult/ErrorId cross the runspace boundary, the message text does not.
# ---------------------------------------------------------------------------------------------
''
'=== 4. a failed probe carries a machine-readable code, not just a localized sentence ==='

$r = Invoke-CimWithTimeout -ComputerName 'WUU-NOTREAL-000000' -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 15
Assert-True (-not $r.Success) 'a probe against an unresolvable host reports failure'
Write-Host ("      observed error: {0}" -f $r.Error) -ForegroundColor DarkGray

# The result shape must expose the structured fields so a caller is not forced back onto message text.
Assert-True ($r -is [System.Collections.IDictionary]) 'the failure result is a dictionary'
Assert-True ($r.Contains('Error')) 'the failure result exposes Error'
Assert-True ($r.Contains('HResult')) 'the failure result exposes HResult (structured, localization-proof)'
Assert-True ($r.Contains('ErrorId')) 'the failure result exposes ErrorId (FullyQualifiedErrorId)'

# A successful probe must NOT carry the failure fields - otherwise callers cannot branch on presence.
$ok = Invoke-CimWithTimeout -ComputerName 'localhost' -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 15
Assert-True ($ok.Success) 'a successful probe still succeeds (the change did not break the happy path)'
Assert-True ($ok.Result) 'and returns real data'

# ---------------------------------------------------------------------------------------------
# 5. THE BRANCH IS WIRED TO THE STRUCTURED CODE. Asserted against the source, because triggering a
#    real RPC failure on demand is neither reliable nor safe here - but the wiring is deterministic.
# ---------------------------------------------------------------------------------------------
''
'=== 5. Invoke-CimWithTimeout derives the code from HResult/ErrorId, not only the message ==='

$source = [System.IO.File]::ReadAllText((Join-Path $repo 'src\Wuu.Remote.psm1'))
$bodyStart = $source.IndexOf('function Invoke-CimWithTimeout')
$bodyEnd   = $source.IndexOf('function Invoke-ServiceWithTimeout')
Assert-True ($bodyStart -ge 0 -and $bodyEnd -gt $bodyStart) 'located the Invoke-CimWithTimeout body'
if ($bodyStart -ge 0 -and $bodyEnd -gt $bodyStart) {
    $body = $source.Substring($bodyStart, $bodyEnd - $bodyStart)
    Assert-True ($body -match "Properties\['HResult'\]") 'the recovery branch reads the structured HResult'
    Assert-True ($body -match "Properties\['ErrorId'\]") 'the recovery branch reads the structured ErrorId'
    Assert-True ($body -match 'Invoke-AutoRecovery') 'the recovery function is still invoked'
    # The code handed to the recovery function must be the normalized bare code the switch expects.
    Assert-True ($body -match "\`$errCode\s*=") 'a normalized error code is passed to Invoke-AutoRecovery'
}

''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
