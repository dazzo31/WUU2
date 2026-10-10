#Requires -Version 5.1
<#
.SYNOPSIS
Phase 2 T009: deterministic credential identity (no silent fallback).

.DESCRIPTION
The defect this suite locks down: the old resolver tried the custom credential, and on failure tried
the PROCESS identity and returned it on success. An administrator who configured alternate credentials
could therefore have an operation run as a different account - silently, with the operation SUCCEEDING.
That is both a security and an audit problem, and it is invisible in the result.

It also could not be told apart from "no custom credential configured", because both returned $null.

These assertions never touch the network: they drive the RESOLVER and the signature/epoch helpers
directly, and use a deliberately failing probe by pointing at a name that cannot resolve only where a
probe is genuinely required. Everything else is decided from configuration state alone.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-CredentialDeterminism.ps1
Exit code 0 = all pass, 1 = failure.
#>
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$script:failures = @()
$script:passes = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        Write-Host "PASS: $Name" -ForegroundColor Green
        $script:passes++
    } else {
        Write-Host "FAIL: $Name" -ForegroundColor Red
        $script:failures += $Name
    }
}

Import-Module (Join-Path $RepoRoot 'src\Wuu.Core.psm1') -ErrorAction Stop
Import-WuuModules -WuuRoot $RepoRoot
Initialize-WuuConfiguration -WuuRoot $RepoRoot

# =============================================================================================
# 1. RESOLVER: the configured mode is reported, and there is only ONE branch that can produce
#    a default identity.
# =============================================================================================
$global:UseCustomCredentials = $false
$global:CustomCredentials = $null

$r = Resolve-WuuOperationCredential -ComputerName 'SRV01'
Assert-True ($r.Mode -eq 'Default') 'no custom credentials -> Mode Default'
Assert-True ($null -eq $r.Credential) 'no custom credentials -> $null credential means the process identity'
Assert-True ($r.Username -eq '') 'the process identity has no username to record'
Assert-True ([string]::IsNullOrWhiteSpace($r.Error)) 'no verification was requested, so no error is reported'
Assert-True ($null -eq $r.Verified) 'Verified is $null when -Verify was not asked for (optional probe)'

# Configure custom credentials WITHOUT a probe (identity is cheap; probing is a round trip).
$sec = ConvertTo-SecureString 'NotARealPassword!23' -AsPlainText -Force
$global:CustomCredentials = New-Object System.Management.Automation.PSCredential('CONTOSO\svc_patch', $sec)
$global:UseCustomCredentials = $true

$r2 = Resolve-WuuOperationCredential -ComputerName 'SRV01'
Assert-True ($r2.Mode -eq 'Custom') 'custom credentials configured -> Mode Custom'
Assert-True ($r2.Credential.UserName -eq 'CONTOSO\svc_patch') 'the configured identity is the one offered'
Assert-True ($r2.Username -eq 'CONTOSO\svc_patch') 'the username is reported for audit'
Assert-True ($r2.Reason -match 'no fallback') 'the decision states explicitly that no fallback exists'

# A LOCAL target must resolve to the process identity even with custom credentials configured:
# local DCOM rejects explicit credentials.
$rLocal = Resolve-WuuOperationCredential -ComputerName $env:COMPUTERNAME -Local
Assert-True ($rLocal.Mode -eq 'Default') 'a local target resolves to the process identity even with custom credentials set'
Assert-True ($rLocal.Reason -match 'local machine') 'the reason explains WHY the local target uses the process identity'

# =============================================================================================
# 2. NO SILENT FALLBACK: a failing custom credential must FAIL, never return the default identity.
# =============================================================================================
# The probe targets a name that cannot resolve, so it fails fast and by the RIGHT reason.
$failing = Resolve-WuuOperationCredential -ComputerName 'WUU-NOTREAL-000000.invalid' -Verify -TimeoutSeconds 3
Assert-True ($failing.Mode -eq 'Custom') 'the failing resolution still DECLARES the configured mode'
Assert-True ($failing.Verified -eq $false) 'verification of an unusable credential reports Verified=$false'
Assert-True ($failing.Reason -match 'no fallback attempted') 'the failure states that NO fallback was attempted'
Assert-True (-not [string]::IsNullOrWhiteSpace($failing.Error)) 'the failure carries the reason it failed'

# Get-RemoteCredentials must THROW for that case, not return $null (which means "process identity").
$threw = $false
$threwMessage = ''
try {
    Get-RemoteCredentials -ComputerName 'WUU-NOTREAL-000000.invalid' -Operation 'test' | Out-Null
} catch {
    $threw = $true
    $threwMessage = $_.Exception.Message
}
Assert-True $threw 'Get-RemoteCredentials THROWS rather than silently falling back to the process identity'
Assert-True ($threwMessage -match 'cannot be used') 'the thrown message explains that the configured credential cannot be used'

# With NO custom credentials configured, it returns $null WITHOUT probing (no wasted round trip).
$global:UseCustomCredentials = $false
$global:CustomCredentials = $null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$defaultResult = Get-RemoteCredentials -ComputerName 'WUU-NOTREAL-000000.invalid' -Operation 'test'
$sw.Stop()
Assert-True ($null -eq $defaultResult) 'with no custom credentials, Get-RemoteCredentials returns $null'
Assert-True ($sw.Elapsed.TotalSeconds -lt 5) "the default path does NOT probe the network (took $([math]::Round($sw.Elapsed.TotalSeconds,2))s)"

# =============================================================================================
# 3. EPOCH: changing the credential configuration is recorded, so stale runspaces are rebuilt.
# =============================================================================================
$before = [int]$global:CredentialEpoch
$after = Update-WuuCredentialEpoch -Reason 'test change'
Assert-True ($after -eq ($before + 1)) 'Update-WuuCredentialEpoch increments the epoch exactly once'
Assert-True ([int]$global:CredentialEpoch -eq $after) 'the increment is visible through the global'

# =============================================================================================
# 4. STATE SIGNATURE: identity only, never a password, and it can be compared on load.
# =============================================================================================
$global:UseCustomCredentials = $false
$global:CustomCredentials = $null
$sigOff = Get-WuuCredentialStateSignature
Assert-True ($sigOff.Enabled -eq $false) 'signature records that custom credentials are off'
Assert-True ($sigOff.Mode -eq 'current-process') 'the off-mode is named, not blank'
Assert-True ($sigOff.UserName -eq '') 'no username is recorded when the process identity is used'

$global:CustomCredentials = New-Object System.Management.Automation.PSCredential('CONTOSO\svc_patch', $sec)
$global:UseCustomCredentials = $true
$sigOn = Get-WuuCredentialStateSignature
Assert-True ($sigOn.Enabled -eq $true) 'signature records that custom credentials are on'
Assert-True ($sigOn.UserName -eq 'CONTOSO\svc_patch') 'the signature reads the username from the PSCredential, not CredentialConfig'
Assert-True ($sigOn.Mode -eq 'custom') 'the on-mode is named'

# The signature must contain NO password material.
$sigText = ($sigOn | ConvertTo-Json -Compress)
Assert-True ($sigText -notmatch 'NotARealPassword') 'the credential signature contains no password material'

# A saved-off list loaded into a custom session must report a MISMATCH with a specific reason.
$match = Test-WuuCredentialStateMatches -Saved $sigOff
Assert-True ($match.Match -eq $false) 'a mismatch is detected between a saved mode and the running session'
Assert-True ($match.Reason -match 'current-process' -and $match.Reason -match 'custom') 'the mismatch reason names BOTH modes'
Assert-True ((Test-WuuCredentialStateMatches -Saved $sigOn).Match) 'the same mode matches'
Assert-True ((Test-WuuCredentialStateMatches -Saved $null).Match) 'a configuration with no credential block is treated as compatible (older build)'

# =============================================================================================
# 5. THE EPOCH IS ACTUALLY CONSULTED AT SUBMISSION (T009.1). The helper above only RECORDS the change;
#    this proves Start-UpdateCheckJob compares the row's stamped epoch and REBUILDS a stale runspace,
#    which is the behaviour R04 requires ("an operation always runs under the identity configured at
#    submission"). Without it the epoch is dead code and stale runspaces keep the old identity.
# =============================================================================================
$updateSrc = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'src\Wuu.WindowsUpdate.psm1'))
Assert-True ($updateSrc -match 'currentEpoch') 'Start-UpdateCheckJob computes the current credential epoch'
Assert-True ($updateSrc -match "Properties\['CredentialEpoch'\]") 'and reads the epoch stamped on the row'
Assert-True ($updateSrc -match '\$rowEpoch -ne \$currentEpoch') 'and compares them to detect a stale runspace'
Assert-True ($updateSrc -match 'runspace rebuilt') 'and rebuilds the stale runspace (evidence in the log line)'
Assert-True ($updateSrc -match "CredentialEpoch'\]\s*\)\s*\{\s*\`$ComputerItem\.CredentialEpoch = \`$currentEpoch") 'and stamps the epoch the new runspace was built with'

# Behavioural: a row whose stamped epoch differs must have its runspace DETACHED (the rebuild path), so
# the next `if (-not Runspace)` constructs a fresh one under the current identity.
Import-Module (Join-Path $RepoRoot 'src\Wuu.WindowsUpdate.psm1') -Force -ErrorAction Stop
$epochRow = New-WuuComputerRow -Computer 'EPOCH-HOST'
$epochRow.Pending = $false                   # a manual submission clears Pending, or the busy gate refuses
$epochRow.CredentialEpoch = 0               # built under epoch 0
$global:CredentialEpoch = 7                 # the operator has since changed credentials
$epochRow.Runspace = [runspacefactory]::CreateRunspace(); $epochRow.Runspace.Open()
$staleRef = $epochRow.Runspace
$acceptedEpoch = $false
try {
    # Submitting forces the epoch comparison. It may refuse for an unrelated reason in a rig (no UI), so
    # assert the RUNSPACE state, not the return value.
    $null = Start-UpdateCheckJob -ComputerItem $epochRow -Op 'Check'
    $acceptedEpoch = $true
} catch { $acceptedEpoch = $false }
Assert-True ($epochRow.CredentialEpoch -eq 7 -or $null -eq $epochRow.Runspace -or -not [object]::ReferenceEquals($epochRow.Runspace, $staleRef)) `
    'a row built under an older credential epoch does not keep the stale runspace'
$global:CredentialEpoch = 0

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:passes, $script:failures.Count)
if ($script:failures.Count -gt 0) {
    foreach ($f in $script:failures) { Write-Host ("  FAILED: " + $f) -ForegroundColor Red }
    exit 1
}
exit 0
