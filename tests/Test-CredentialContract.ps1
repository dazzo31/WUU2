# Contract test: the credential handling rules that matter for R04 (identity safety).
#
# REPLACES the former Test-CredentialTyping.ps1, whose three probes asserted almost nothing and
# whose stated premise was factually WRONG. Recorded here so the replacement is not "simplified"
# back into the same shape:
#
#   * The old Test A/B asserted only "the call failed and the message is not a binding error".
#     Since the target is a non-existent host, a hard-coded $false would also pass. It proved the
#     call did not throw; it could not distinguish success from failure.
#   * The old Test C claimed "a plain STRING must NOT silently become a credential" and treated
#     "no exception was thrown" as a pass. Measured: [pscredential]$x binding converts a string to
#     $null (it does not throw and does not use it as a password), so the string was never a
#     credential and the assertion could not fail either way. The comment in the old test also
#     claimed the conversion "fails (no prompt available)" - PowerShell does not prompt here.
#   * Net effect: ~11s of network round trips for two assertions that could not fail.
#
# What is worth testing is the INVARIANT those probes were circling: a custom credential that
# cannot authenticate must be reported as unverified and must NOT be silently replaced by the
# process identity. That is enforced in Resolve-WuuOperationCredential / Get-RemoteCredentials and
# is asserted below against a REAL failing probe (an unresolvable name), not a mock.
#
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Test-CredentialContract.ps1

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

# Import through the SAME path the app uses, so the helpers are reached exactly as in production
# (Wuu.Remote depends on Wuu.Workers' Invoke-WithPoolTimeout).
Import-Module (Join-Path $repo 'src\Wuu.Core.psm1') -ErrorAction Stop
Import-WuuModules -WuuRoot $repo | Out-Null

# A host that cannot resolve: the probe fails for a REAL reason (RPC unavailable / name not
# resolvable) in ~3s, which is what makes the no-fallback assertions meaningful.
$DeadHost = 'WUU-NOTREAL-000000'

# ---------------------------------------------------------------------------------------------
# 1. The parameter type is what enforces credential handling (deterministic, no I/O).
# ---------------------------------------------------------------------------------------------
'=== 1. declared parameter types ==='
$cimCmd = Get-Command Invoke-CimWithTimeout -ErrorAction SilentlyContinue
Assert-True ($null -ne $cimCmd) 'Invoke-CimWithTimeout is exported by Wuu.Remote'
if ($cimCmd) {
    Assert-True ($cimCmd.Parameters.ContainsKey('Credential')) 'Invoke-CimWithTimeout declares -Credential'
    if ($cimCmd.Parameters.ContainsKey('Credential')) {
        Assert-Equal $cimCmd.Parameters['Credential'].ParameterType.FullName `
            'System.Management.Automation.PSCredential' `
            'the declared type is [pscredential], so a bare string can never BE the credential value'
    }
}

# Measured behaviour, pinned so a future reader is not misled the way the old comment was:
# binding a string to [pscredential] yields $null (silently), it does NOT throw and does NOT use
# the string as a password. Asserting the real behaviour is the point; asserting the old claim
# would have required the code to be wrong.
''
'=== 2. a string bound to [pscredential] becomes $null, never a usable credential ==='
$bound = $null
$boundWasString = $false
try {
    $bound = [pscredential]'PlainTextPassword'
} catch {
    $boundWasString = $true   # conversion refused: equally safe
}
if ($boundWasString) {
    Assert-True $true 'a string cast to [pscredential] is refused outright (safe)'
} else {
    Assert-True ($null -eq $bound) 'a string bound to [pscredential] is $null, not a credential made from the literal'
    Assert-True ($bound -isnot [System.Management.Automation.PSCredential]) 'the literal was never adopted as an identity'
}

# ---------------------------------------------------------------------------------------------
# 3. A real PSCredential crosses the pool runspace boundary intact.
#    This is the marshalling property the old Test B gestured at but never actually checked.
# ---------------------------------------------------------------------------------------------
''
'=== 3. PSCredential survives marshalling into a worker runspace ==='
$sec = ConvertTo-SecureString 'NotARealPassword!23' -AsPlainText -Force
$probeCred = New-Object System.Management.Automation.PSCredential('.\contract_probe_user', $sec)
$marshalled = Invoke-WithPoolTimeout -ScriptBlock {
    param($c)
    [pscustomobject]@{
        IsCred = ($c -is [System.Management.Automation.PSCredential])
        User   = if ($c) { [string]$c.UserName } else { '' }
        Secret = try { $c.GetNetworkCredential().Password } catch { '' }
    }
} -ArgumentList @($probeCred) -TimeoutSeconds 20 -OperationName 'credential marshalling contract'

Assert-True $marshalled.Success 'the marshalling probe ran on the pool'
if ($marshalled.Success -and $marshalled.Result) {
    Assert-True $marshalled.Result.IsCred 'the object arrives typed as [pscredential], not a string or a deserialised bag'
    Assert-Equal $marshalled.Result.User '.\contract_probe_user' 'the username arrives intact'
    Assert-Equal $marshalled.Result.Secret 'NotARealPassword!23' 'the secret arrives readable in the worker (so authentication can actually happen)'
} else {
    Assert-True $false "the marshalling probe returned no result: $($marshalled.Error)"
}

# ---------------------------------------------------------------------------------------------
# 4. THE SECURITY INVARIANT (R04): a configured custom credential that cannot authenticate is
#    reported as UNVERIFIED and is never silently swapped for the process identity.
#
#    Driven with a REAL failing probe against an unresolvable host, so no mocking is involved and
#    the failure path is genuine.
# ---------------------------------------------------------------------------------------------
''
'=== 4. no silent fallback: a failing custom credential is reported, not replaced ==='
$savedUse = $global:UseCustomCredentials
$savedCred = $global:CustomCredentials
try {
    $global:UseCustomCredentials = $true
    $global:CustomCredentials = $probeCred

    $res = Resolve-WuuOperationCredential -ComputerName $DeadHost -Verify -TimeoutSeconds 5

    Assert-Equal $res.Mode 'Custom' 'with custom credentials enabled the resolver stays in Custom mode (it does not quietly downgrade)'
    Assert-Equal $res.Verified $false 'verification FAILS against an unreachable host (the probe result is not masked as success)'
    Assert-True ([bool]$res.Error) 'the failure reason is reported, not discarded'
    Assert-True ($res.Reason -match 'no fallback') 'the reason states that no fallback was attempted'
    Write-Host ("      reason: {0}" -f $res.Reason) -ForegroundColor DarkGray

    # Get-RemoteCredentials must THROW rather than return $null, because $null legitimately means
    # "use the process identity" - returning it here is exactly the silent-fallback defect.
    $threw = $false
    $thrownMessage = ''
    try {
        $null = Get-RemoteCredentials -ComputerName $DeadHost -Operation 'contract probe'
    } catch {
        $threw = $true
        $thrownMessage = $_.Exception.Message
    }
    Assert-True $threw 'Get-RemoteCredentials THROWS on an unverifiable custom credential instead of returning $null'
    Assert-True ($thrownMessage -match 'Configured custom credentials') 'the thrown message names the cause so the operator can act'
} finally {
    $global:UseCustomCredentials = $savedUse
    $global:CustomCredentials = $savedCred
}

# ---------------------------------------------------------------------------------------------
# 5. $null legitimately means "process identity" - the distinction the old suite conflated.
# ---------------------------------------------------------------------------------------------
''
'=== 5. with no custom credential configured, the process identity is used deliberately ==='
$savedUse2 = $global:UseCustomCredentials
$savedCred2 = $global:CustomCredentials
try {
    $global:UseCustomCredentials = $false
    $global:CustomCredentials = $null

    $defaultRes = Resolve-WuuOperationCredential -ComputerName 'some-host'
    Assert-Equal $defaultRes.Mode 'Default' 'no custom credential configured resolves to Default mode'
    Assert-True ($null -eq $defaultRes.Credential) 'and the credential is $null, meaning the process identity'

    $noThrow = $true
    try { $null = Get-RemoteCredentials -ComputerName 'some-host' } catch { $noThrow = $false }
    Assert-True $noThrow 'Get-RemoteCredentials does NOT throw for the genuine process-identity case (it only throws for a failed custom credential)'
} finally {
    $global:UseCustomCredentials = $savedUse2
    $global:CustomCredentials = $savedCred2
}

''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
