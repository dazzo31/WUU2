#Requires -Version 5.1
<#
.SYNOPSIS
Phase 1 T007: identity-fenced state writes + the admission critical section.

.DESCRIPTION
Two DISTINCT mechanisms are asserted here, and keeping them distinct is the point:

  1. STATE WRITES ARE FENCED BY OPERATION IDENTITY, not by a lock. A writer is refused only for a
     PROVEN staleness: the row names an OperationId (or a LastResetOperationId) and the writer names
     a different one. An UNATTRIBUTED write is permitted, because row population has no operation.
     A coarse state lock is deliberately NOT used - it would have to be held across remote calls and
     UI dispatch, so a blocked payload would freeze the whole application.

  2. ADMISSION CAPACITY IS the one genuine shared critical section. Enter/Exit-WuuSubmissionLock guard
     a capacity re-test immediately before a slot is consumed. This test drives it from REAL threads
     sharing ONE gate object, which is the only way to observe exclusion: module scope is per-RUNSPACE,
     so importing the module N times would prove nothing (that is exactly why the -Gate parameter
     exists).

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-StateFencing.ps1
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
# 1. IDENTITY FENCING - the funnel refuses a superseded writer.
# =============================================================================================
$row = New-WuuComputerRow -Computer 'SRV01'
$store = New-WuuStateStore
Add-WuuComputerRow -Store $store -Row $row | Out-Null

# Adopt an operation identity, exactly as the submission point does. Adoption is a SEPARATE, explicit
# act (OperationIdNew + OpState 'Running'), never inferred from a differing id - otherwise every
# resubmission would look stale.
$opA = New-WuuOperationId -Computer 'SRV01'
$adopt = Update-WuuOperationState -Row $row -OperationIdNew $opA -OpState 'Running' -State 'Searching' -Status 'checking'
Assert-True ($adopt.Applied) 'funnel adopts the new operation identity'
Assert-True ([string]$row.OperationId -ceq [string]$opA) 'the row carries the adopted identity'
Assert-True ([string]$row.OpState -eq 'Running') 'adopting with -OpState marks the row Running'

# A DIFFERENT writer must be refused (proven staleness).
$staleResult = Update-WuuOperationState -Row $row -OperationId ([guid]::NewGuid().ToString()) -State 'Installing' -Status 'stale write'
Assert-True ($staleResult.Refused) 'a superseded writer is REFUSED'
Assert-True (-not $staleResult.Applied) 'the refusal did not apply a write'
Assert-True ([string]$row.State -eq 'Searching') 'the refused write did not change State'

# A SECOND live operation may not adopt over the running one.
$adoptOver = Update-WuuOperationState -Row $row -OperationIdNew (New-WuuOperationId -Computer 'SRV01') -OpState 'Running' -State 'Searching'
Assert-True ($adoptOver.Refused) 'a new operation cannot adopt a row that is still Running'

# Test-WuuStaleWrite must agree with the funnel's decision.
Assert-True (Test-WuuStaleWrite -Row $row -OperationId ([guid]::NewGuid().ToString())) 'Test-WuuStaleWrite agrees the other writer is stale'
Assert-True (-not (Test-WuuStaleWrite -Row $row -OperationId $opA)) 'Test-WuuStaleWrite accepts the owning writer'

Update-WuuOperationState -Row $row -OperationId $opA -State 'Downloading' -Status 'downloading' | Out-Null
Assert-True ([string]$row.State -eq 'Downloading') 'the owning writer is ACCEPTED'

# An UNATTRIBUTED write is permitted - row population has no operation.
$unattributed = New-WuuComputerRow -Computer 'SRV02'
$uRes = Update-WuuOperationState -Row $unattributed -State 'Queued' -Status 'seeded'
Assert-True ($uRes.Applied) 'an unattributed write (no operation) is permitted - row population has no operation'
Assert-True ([string]$unattributed.State -eq 'Queued') 'the unattributed write applied'

# =============================================================================================
# 2. RESET FENCING - a writer that predates a reset is refused.
# =============================================================================================
$row2 = New-WuuComputerRow -Computer 'SRV03'
$opOld = New-WuuOperationId -Computer 'SRV03'
Update-WuuOperationState -Row $row2 -OperationIdNew $opOld -OpState 'Running' -State 'Installing' -Status 'installing' | Out-Null
$ctx = New-WuuResetOperationContext -Source 'OperatorReset' -Reason 'test reset'
Update-WuuOperationState -Row $row2 -ResetOperation $ctx | Out-Null
Assert-True ([string]$row2.OpState -eq 'Idle' -and [string]::IsNullOrEmpty([string]$row2.OperationId)) 'reset returns the row to Idle with no OperationId'
# NOTE: Test-WuuStaleWrite alone returns FALSE here, because the reset EMPTIED the row's OperationId
# and "two unknowns are not evidence of a match". Reset fencing is therefore enforced by the funnel's
# explicit LastResetOperationId branch, which is what the next assertion drives.
$lateAfterReset = Update-WuuOperationState -Row $row2 -OperationId $opOld -State 'Complete' -Status 'late write'
Assert-True ($lateAfterReset.Refused) 'the late pre-reset writer is refused by the funnel (reset fencing)'
Assert-True ((Get-WuuRefusalStallThreshold) -gt 1) 'more than one consecutive connectivity failure is required before eviction'

# =============================================================================================
# 2b. CONNECTIVITY EVICTION POLICY (SS12 / review M-5). The RemoveOffline payload used to evict on a
#     SINGLE lost ICMP packet, and its store removal could not resolve in a worker runspace (module
#     function + $global: unreachable) so the eviction silently no-opped while only the view changed.
#     The payload now uses a threshold and an INJECTED store-removal twin. These assert the wiring; the
#     twin's behaviour is covered by Test-WorkerTwinFence.
# =============================================================================================
$coreSrcForConn = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'src\Wuu.Core.psm1'))
$updateSrcForConn = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'src\Wuu.WindowsUpdate.psm1'))
Assert-True ($updateSrcForConn -match "SetVariable\('RemoveComputerRowScript'") 'the store-removal twin is injected into worker runspaces (M-5)'
Assert-True ($coreSrcForConn -match '\$RemoveComputerRowScript') 'the RemoveOffline payload CALLS the injected removal twin'
Assert-True ($coreSrcForConn -match 'ConnectivityFailures') 'the payload counts consecutive connectivity failures before eviction'
Assert-True ($updateSrcForConn -match 'ConnectivityFailuresBeforeRemoval') 'the threshold is injected (one lost packet must not evict a host)'
# EXACTLY ONE remaining caller: the MAIN-SESSION $removeEntry (which can resolve the module function).
# The payload's own call is gone - a second occurrence means the worker path crept back in.
$moduleRemoverCalls = ([regex]::Matches($coreSrcForConn, 'Remove-WuuComputerRow\s+-Store\s+\$global:stateStore')).Count
Assert-True ($moduleRemoverCalls -eq 1) 'only the main-session removal path calls the module remover (the worker payload uses the injected twin)'

# =============================================================================================
# 3. TERMINAL PROTECTION - a settled row cannot be rewritten by a bare transition.
# =============================================================================================
$row3 = New-WuuComputerRow -Computer 'SRV04'
$opT = New-WuuOperationId -Computer 'SRV04'
Update-WuuOperationState -Row $row3 -OperationIdNew $opT -OpState 'Running' -State 'Installing' -Status 'installing' | Out-Null
Update-WuuOperationState -Row $row3 -OperationId $opT -State 'Error' -Status 'failed' | Out-Null
Assert-True ([string]$row3.State -eq 'Error') 'row settled as Error'

# Retire the operation identity, exactly as the cleanup loop does when it settles a job.
Update-WuuOperationState -Row $row3 -OperationId $opT -ClearOperation | Out-Null
Assert-True ([string]$row3.OpState -eq 'Idle' -and [string]::IsNullOrEmpty([string]$row3.OperationId)) 'cleanup retires the identity'

# A bare rewrite of a settled row - with NO live operation - must be refused, and the display must
# NOT be laundered into a success.
Update-WuuOperationState -Row $row3 -State 'Complete' -Status 'sneaky rewrite' | Out-Null
Assert-True ([string]$row3.State -eq 'Error') 'a settled Error cannot be rewritten to Complete once its operation is retired'
Assert-True ((Test-WuuTerminalState -State 'Error').Terminal) 'Error is a terminal state'
Assert-True ((Get-WuuTerminalStates) -contains 'Timeout') 'Timeout is a terminal state'

# A retry is a NEW attributed operation - and that MUST be permitted, or a failed canary could never
# be re-run.
$opRetry = New-WuuOperationId -Computer 'SRV04'
$retry = Update-WuuOperationState -Row $row3 -OperationId $opRetry -OperationIdNew $opRetry -OpState 'Running' -State 'Searching' -Status 'retry'
Assert-True ($retry.Applied) 'a settled row can be retried by a NEW attributed operation'
Assert-True ([string]$row3.OperationId -ceq [string]$opRetry) 'the retry took ownership of the row'

# ClearOperation must NOT launder a terminal Error into Queued even when a follow-up is queued.
$row5 = New-WuuComputerRow -Computer 'SRV06'
$opQ = New-WuuOperationId -Computer 'SRV06'
Update-WuuOperationState -Row $row5 -OperationIdNew $opQ -OpState 'Running' -State 'Installing' | Out-Null
Update-WuuOperationState -Row $row5 -OperationId $opQ -State 'Error' -Status 'failed' | Out-Null
Set-WuuPendingOperation -Row $row5 -Op 'Download' | Out-Null
Update-WuuOperationState -Row $row5 -OperationId $opQ -ClearOperation | Out-Null
Assert-True ([string]$row5.State -eq 'Error') 'ClearOperation does not launder a settled Error into Queued'

# A FAILED INSTALL must not read as Complete.
$row4 = New-WuuComputerRow -Computer 'SRV05'
$opI = New-WuuOperationId -Computer 'SRV05'
Update-WuuOperationState -Row $row4 -OperationIdNew $opI -OpState 'Running' -State 'Installing' -Status 'installing' | Out-Null
Update-WuuOperationState -Row $row4 -OperationId $opI -State 'Complete' -Status 'all installed' -UpdatesStatus 'All updates installed' | Out-Null
$row4.InstallErrors = 2
$row4.RebootRequired = $true
Assert-True ((Get-WuuTargetOutcome -Row $row4) -eq 'Failed') 'InstallErrors=2 yields Failed even when State=Complete (install errors are not masked)'
Assert-True ((Get-WuuAggregateOutcome -Rows @($row3, $row4)) -in @('PartialSuccess', 'OperationFailed')) 'the aggregate reports mixed/failed outcomes rather than Success'

# =============================================================================================
# 4. ADMISSION CRITICAL SECTION - REAL threads, ONE shared gate object.
# =============================================================================================
# The gate is passed EXPLICITLY so every worker shares one object. Each worker imports the module
# itself (module scope is per-runspace, which is precisely why the gate cannot be discovered).
$gate = New-Object System.Object
$counter = [hashtable]::Synchronized(@{ Inside = 0; Max = 0; Entries = 0 })

$workerSource = @'
param([string]$RepoRoot, [object]$Gate, [int]$Rounds, [hashtable]$Counter)
Import-Module (Join-Path $RepoRoot 'src\Wuu.State.psm1') -Global -ErrorAction Stop
$violations = 0
for ($i = 0; $i -lt $Rounds; $i++) {
    $got = Enter-WuuSubmissionLock -Gate $Gate -TimeoutMs 10000
    if (-not $got) { continue }
    try {
        $Counter.Inside = [int]$Counter.Inside + 1
        $Counter.Entries = [int]$Counter.Entries + 1
        if ([int]$Counter.Inside -gt [int]$Counter.Max) { $Counter.Max = [int]$Counter.Inside }
        if ([int]$Counter.Inside -gt 1) { $violations++ }
        Start-Sleep -Milliseconds 1
        $Counter.Inside = [int]$Counter.Inside - 1
    } finally {
        Exit-WuuSubmissionLock -Gate $Gate
    }
}
return $violations
'@

$workers = @()
$handles = @()
for ($w = 0; $w -lt 4; $w++) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($workerSource).AddArgument($RepoRoot).AddArgument($gate).AddArgument(40).AddArgument($counter)
    $handles += $ps.BeginInvoke()
    # The runspace is created EXPLICITLY and assigned to the PowerShell instance, so
    # PowerShell.Dispose() will not close it - both must be disposed, separately.
    $workers += @{ PS = $ps; RS = $rs }
}

$totalViolations = 0
for ($i = 0; $i -lt $handles.Count; $i++) {
    $out = $workers[$i].PS.EndInvoke($handles[$i])
    foreach ($o in $out) { if ($o -is [int]) { $totalViolations += $o } }
    $workers[$i].PS.Dispose()
    $workers[$i].RS.Close()
    $workers[$i].RS.Dispose()
}

Assert-True ([int]$counter.Entries -gt 0) "the workers actually entered the section (entries=$($counter.Entries))"
Assert-True ([int]$counter.Max -le 1) "observed maximum concurrency inside the section was 1 (max=$($counter.Max))"
Assert-True ($totalViolations -eq 0) "no two threads were ever inside the submission critical section together (violations=$totalViolations)"
Assert-True ([int]$counter.Max -eq 1) 'concurrency reached 1, so the section was genuinely exercised (not merely never entered)'

# =============================================================================================
# 3. THE SHARED STATE GATE (G3) - the funnel, the store mutations and the worker ALL take ONE gate.
#
# WHY A SEPARATE GATE FROM THE SUBMISSION LOCK. The submission lock serialises CAPACITY RESERVATION
# and is held around admission; this gate serialises ROW STATE and is held only for the
# validate-mutate-publish window. This section proves the two properties that make it the right
# mechanism, both of which a module-scope lock could not have:
#   (a) it lives ON THE STORE, so the SAME object is visible in a worker runspace (module scope is
#       per-runspace and would exclude nothing);
#   (b) it FAILS CLOSED - a funnel write under a held gate is REFUSED, never run unlocked.
# =============================================================================================
''
Write-Host '=== 3. the shared state gate (G3) ===' -ForegroundColor Cyan

$gateStore = New-WuuStateStore
Assert-True ($null -ne $gateStore.Gate) 'the store carries a gate object (shared by reference with workers)'
# Production handlers call the funnel WITHOUT -Store; it resolves the application's global store so
# their writes are atomic too. Exercise that path here.
$global:stateStore = $gateStore

$gateRow = New-WuuComputerRow -Computer 'GATE01'
Add-WuuComputerRow -Store $gateStore -Row $gateRow | Out-Null
$gateOp = New-WuuOperationId -Computer 'GATE01'
Update-WuuOperationState -Row $gateRow -OperationIdNew $gateOp -OpState 'Running' -State 'Searching' | Out-Null

# (a) A worker runspace sees the SAME gate object and takes it; while it holds it, the MAIN-session
# funnel must be refused (fail-closed). This is real cross-runspace exclusion, not a same-process call.
$workerHoldSource = @'
param([object]$Store, [object]$ExpectedGate)
if (-not [object]::ReferenceEquals($Store.Gate, $ExpectedGate)) { return 'DIFFERENT-GATE' }
$held = [System.Threading.Monitor]::TryEnter($Store.Gate, 5000)
if (-not $held) { return 'COULD-NOT-TAKE' }
try {
    [System.Threading.Thread]::Sleep(1500)
    return 'HELD'
} finally {
    [System.Threading.Monitor]::Exit($Store.Gate)
}
'@
$holdRs = [runspacefactory]::CreateRunspace()
$holdRs.Open()
$holdPs = [powershell]::Create()
$holdPs.Runspace = $holdRs
[void]$holdPs.AddScript($workerHoldSource).AddArgument($gateStore).AddArgument($gateStore.Gate)
$holdHandle = $holdPs.BeginInvoke()
Start-Sleep -Milliseconds 400   # let the worker acquire the gate first
# A short gate timeout makes the FAIL-CLOSED path observable without waiting out the default 10s: the
# worker holds the gate for 1.5s, so a 300ms budget must REFUSE rather than run the write unlocked.
$blocked = Update-WuuOperationState -Row $gateRow -OperationId $gateOp -State 'Downloading' -Status 'should be refused' -StateGateTimeoutMs 300
$heldResult = @($holdPs.EndInvoke($holdHandle)) | Select-Object -First 1
$holdPs.Dispose(); $holdRs.Close(); $holdRs.Dispose()

Assert-True ("$heldResult" -eq 'HELD') "the worker runspace took the SAME store gate (result=$heldResult)"
Assert-True ($blocked.Refused) 'the main-session funnel is REFUSED while the worker holds the gate (fail-closed, not unlocked)'
Assert-True ([string]$gateRow.State -eq 'Searching') 'the refused funnel write did not change State'
Assert-True (-not (Test-WuuStateLockHeld -Store $gateStore)) 'the gate is not held after the worker released it'

# (b) The gate is genuinely re-entrant and released: the owning writer is accepted afterwards.
#     Also exercise the EXPLICIT -Store path, which must reach the same gate.
$afterRelease = Update-WuuOperationState -Row $gateRow -OperationId $gateOp -State 'Downloading' -Status 'accepted after release'
Assert-True ($afterRelease.Applied) 'the owning writer is accepted once the gate is free'
Assert-True ([string]$gateRow.State -eq 'Downloading') 'and the accepted write is visible'
$explicitStoreWrite = Update-WuuOperationState -Row $gateRow -Store $gateStore -OperationId $gateOp -State 'Installing' -Status 'explicit store path'
Assert-True ($explicitStoreWrite.Applied) 'an explicit -Store write reaches the same gate and is accepted when free'

# (c) THE FUNNEL REFUSES AN ORPHAN ROW. A removed or same-name-replaced row is not the store's row any
#     more; writing to it is a leak, and returning Applied=$true would tell the caller a write landed
#     that nothing can see. The worker twin already checked this; the funnel did not, so the two copies
#     disagreed - the defect this assertion pins down.
$orphanRow = New-WuuComputerRow -Computer 'ORPHAN01'
Add-WuuComputerRow -Store $gateStore -Row $orphanRow | Out-Null
$orphanOp = New-WuuOperationId -Computer 'ORPHAN01'
Remove-WuuComputerRow -Store $gateStore -Computer 'ORPHAN01' | Out-Null
$orphanWrite = Update-WuuOperationState -Row $orphanRow -OperationIdNew $orphanOp -OpState 'Running' -State 'Searching'
Assert-True ($orphanWrite.Refused) 'the funnel REFUSES a write to a row removed from the store'
Assert-True ([string]$orphanRow.OperationId -ne [string]$orphanOp) 'the orphan write did not take ownership'

# A same-name REPLACEMENT is the same class of orphan (the old reference is no longer the store's row).
$replacedOld = New-WuuComputerRow -Computer 'REPL01'
Add-WuuComputerRow -Store $gateStore -Row $replacedOld | Out-Null
$replacedNew = New-WuuComputerRow -Computer 'REPL01'
Add-WuuComputerRow -Store $gateStore -Row $replacedNew | Out-Null
$replacedWrite = Update-WuuOperationState -Row $replacedOld -OperationIdNew (New-WuuOperationId -Computer 'REPL01') -OpState 'Running' -State 'Searching'
Assert-True ($replacedWrite.Refused) 'the funnel REFUSES a write to a replaced (same-name) row'
Assert-True ($replacedWrite.Applied -eq $false) 'the replaced-row refusal applied nothing'

# =============================================================================================
# 3b. THE ONE-SLOT QUEUE IS SERIALIZED (review M-1). A payload queuing a follow-up from ITS OWN thread
#     and the scheduler consuming the slot are a read-modify-write on the SAME row. If they are not
#     serialized the scheduler can consume the slot while the payload is mid-write, and the operator's
#     queued install is LOST (replaced by the scheduler's 'Check') - the install never runs and the
#     phase gate blocks for ever with no diagnostic. Both paths now take the shared store gate.
#
#     This is DETERMINISTIC, not a timing race: a worker holds the gate for 1.5s, and the MAIN-session
#     `Set-WuuPendingOperation` must take a SHORT-gated path and be REFUSED - so the write provably
#     cannot land while the slot is being consumed.
# =============================================================================================
''; Write-Host '=== 3b. the one-slot queue write is serialized on the shared gate ===' -ForegroundColor Cyan

$qStore = New-WuuStateStore
$global:stateStore = $qStore
$qRow = New-WuuComputerRow -Computer 'QUEUE-GATE'
$qOp = New-WuuOperationId -Computer 'QUEUE-GATE'
Add-WuuComputerRow -Store $qStore -Row $qRow | Out-Null
Update-WuuOperationState -Row $qRow -OperationIdNew $qOp -OpState 'Running' -State 'Downloading' | Out-Null

# A worker holds the shared store gate longer than the module writer's 5s gate budget, so the writer is
# REFUSED (observable) rather than merely delayed (which would also be correct, but is not assertable
# without timing).
$queueHoldSource = @'
param([object]$Store)
$held = [System.Threading.Monitor]::TryEnter($Store.Gate, 5000)
if (-not $held) { return 'COULD-NOT-TAKE' }
try { [System.Threading.Thread]::Sleep(6500); return 'HELD' } finally { [System.Threading.Monitor]::Exit($Store.Gate) }
'@
$qRs = [runspacefactory]::CreateRunspace(); $qRs.Open()
$qPs = [powershell]::Create(); $qPs.Runspace = $qRs
[void]$qPs.AddScript($queueHoldSource).AddArgument($qStore)
$qHandle = $qPs.BeginInvoke()
Start-Sleep -Milliseconds 400   # let the worker take the gate

# The module copy: bounded 5s gate timeout. It cannot take the gate the worker holds, so it must REFUSE
# and NOT write the slot (fail-closed).
$queueRefused = Set-WuuPendingOperation -Row $qRow -Op 'InstallAndRecheck'
$qHeldResult = @($qPs.EndInvoke($qHandle)) | Select-Object -First 1
$qPs.Dispose(); $qRs.Close(); $qRs.Dispose()

Assert-True ("$qHeldResult" -eq 'HELD') 'the worker held the shared store gate'
Assert-True ($queueRefused.Refused -and -not $queueRefused.Set) 'the module queue write is REFUSED while the gate is held (it cannot interleave with a consume)'
Assert-True ([string]::IsNullOrEmpty([string]$qRow.PendingOp)) 'the refused queue write did NOT touch the slot (no lost update)'

# The INJECTED twin takes the SAME gate too (a payload's follow-up is the other side of the race).
$queueTwinSrc = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'src\Wuu.WindowsUpdate.psm1'))
Assert-True ($queueTwinSrc -match 'queueGateHeld') 'the injected SetPendingOpScript twin takes the shared store gate (M-1)'
Assert-True ($updateSrcForConn -match 'Enter-WuuStateLock\s+-Store\s+\$stateStore') 'the scheduler takes the shared store gate around its consume/re-arm (M-1)'

# Once free, the module write is accepted - proving the refusal above was the GATE, not a broken call.
$queueApplied = Set-WuuPendingOperation -Row $qRow -Op 'InstallAndRecheck'
Assert-True ($queueApplied.Set) 'the queue write is ACCEPTED once the gate is free (the refusal was contention, not a defect)'
Assert-True ([string]$qRow.PendingOp -eq 'InstallAndRecheck') 'and the slot now holds the request'
$global:stateStore = $null

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:passes, $script:failures.Count)
if ($script:failures.Count -gt 0) {
    foreach ($f in $script:failures) { Write-Host ("  FAILED: " + $f) -ForegroundColor Red }
    exit 1
}
exit 0
