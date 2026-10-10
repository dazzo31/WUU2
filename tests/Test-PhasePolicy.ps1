#Requires -Version 5.1
<#
.SYNOPSIS M-4: phase gating honours the configured PhaseFailurePolicy.
.DESCRIPTION
WHY THIS SUITE EXISTS. `Test-PhaseCompletion` decided "is this phase done?" by SKIPPING errored and
timed-out rows unconditionally - i.e. it ALWAYS behaved as ContinueOnFailure, the unsafe option - while
the store defaulted to BlockOnFailure. A failed canary therefore silently permitted the next phase, and
`$store.Settings['PhaseFailurePolicy']` was inert configuration. This drives the real gate for each
policy so the decision cannot drift back to a hard-coded skip.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-PhasePolicy.ps1
#>

$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$ErrorActionPreference = 'Stop'

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

Import-Module (Join-Path $repo 'src\Wuu.Core.psm1') -Force -ErrorAction Stop
Import-WuuModules -WuuRoot $repo | Out-Null

$store = New-WuuStateStore
$global:stateStore = $store
Initialize-WuuWindowsUpdateContext -Context @{ StateStore = $store; UiHash = @{}; Jobs = @() }
Assert-Equal $store.Settings['PhaseFailurePolicy'] 'BlockOnFailure' 'the store DEFAULT is the safe policy (BlockOnFailure)'

function New-PhaseRow([string]$Computer, [string]$UpdatesStatus, [string]$State, [bool]$Pending) {
    $r = New-WuuComputerRow -Computer $Computer -Phase 'Phase 1'
    $r.UpdatesStatus = $UpdatesStatus
    $r.State = $State
    $r.Pending = $Pending
    Add-WuuComputerRow -Store $store -Row $r | Out-Null
    return $r
}
function Reset-Store {
    Set-WuuComputerRows -Store $store -Rows @() | Out-Null
}

''; '=== phase gating honours BlockOnFailure (the default) ==='

# A settled FAILURE blocks the next phase under the default policy.
Reset-Store
New-PhaseRow 'PH-FAIL' 'Error' 'Error' $false | Out-Null
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $false 'BlockOnFailure: a settled Error row BLOCKS the phase'

# A settled TIMEOUT blocks too under BlockOnFailure.
Reset-Store
New-PhaseRow 'PH-TMO' 'Timeout' 'Timeout' $false | Out-Null
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $false 'BlockOnFailure: a settled Timeout row BLOCKS the phase'

''; '=== ContinueOnTimeout tolerates timeouts but not failures ==='

Set-WuuPhaseFailurePolicy -Store $store -Policy 'ContinueOnTimeout' | Out-Null
Reset-Store
New-PhaseRow 'PH-TMO2' 'Timeout' 'Timeout' $false | Out-Null
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $true 'ContinueOnTimeout: a Timeout row does NOT block'
Reset-Store
New-PhaseRow 'PH-FAIL2' 'Error' 'Error' $false | Out-Null
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $false 'ContinueOnTimeout: an Error row STILL blocks'

''; '=== ContinueOnFailure permits the next phase past a settled failure ==='

Set-WuuPhaseFailurePolicy -Store $store -Policy 'ContinueOnFailure' | Out-Null
Reset-Store
New-PhaseRow 'PH-FAIL3' 'Error' 'Error' $false | Out-Null
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $true 'ContinueOnFailure: an Error row does NOT block (the old hard-coded behaviour, now opt-in)'

''; '=== a pending row blocks under EVERY policy; a clean row never does ==='

Reset-Store
New-PhaseRow 'PH-PEND' 'Initializing' 'Queued' $true | Out-Null
foreach ($pol in @('BlockOnFailure', 'ContinueOnTimeout', 'ContinueOnFailure')) {
    Set-WuuPhaseFailurePolicy -Store $store -Policy $pol | Out-Null
    Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $false "a Pending row blocks the phase under $pol (work still queued)"
}

Reset-Store
$clean = New-WuuComputerRow -Computer 'PH-OK' -Phase 'Phase 1'
$clean.Pending = $false; $clean.Available = 0; $clean.Downloaded = 0; $clean.RebootRequired = $false
$clean.UpdatesStatus = 'All updates installed'; $clean.State = 'Complete'
Add-WuuComputerRow -Store $store -Row $clean | Out-Null
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 1') $true 'a settled, cleanly-installed row does not block'
Assert-Equal (Test-PhaseCompletion -Phase 'Phase 9') $true 'an empty phase is complete'
Assert-Equal (Test-PhaseReady -Phase 'Phase 1') $true 'Phase 1 is always ready'

''; '=== an unknown policy fails SAFE (blocks) ==='

Set-WuuPhaseFailurePolicy -Store $store -Policy 'BlockOnFailure' | Out-Null
# Drive the predicate directly with a bogus policy rather than corrupting the store's ValidateSet.
$errRow = New-WuuComputerRow -Computer 'PH-UNK'
$errRow.UpdatesStatus = 'Error'
Assert-True (Test-WuuPhaseFailureBlocks -Row $errRow -Policy 'SomethingElse') 'an unrecognised policy BLOCKS (fails safe, not permissive)'
Assert-True (-not (Test-WuuPhaseFailureBlocks -Row $errRow -Policy 'ContinueOnFailure')) 'and ContinueOnFailure does NOT block (the predicate is policy-driven, not hard-coded)'

''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
