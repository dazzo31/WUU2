# Test: T006/T007 step B — operation identity is minted at submission, stamped on the row, injected
# into the runspace, and RELEASED when the job settles.
#
# WHY THIS SUITE EXISTS
# ---------------------
# Measured before this step: `New-WuuOperationId` was called ONLY by the test suite, no runspace ever
# received `WuuOperationId`, and no row ever carried a non-empty `OperationId`. The engine's identity
# fence was therefore unenforceable by construction - a row has no owner, so every write is
# "unattributed" and the staleness rule has both sides of its comparison empty.
#
# The subtle half is the RELEASE. Stamping `OpState='Running'` without retiring it would leave every
# row permanently busy, and `Test-WuuOperationStateInvariant` reports exactly that as
# "settled row ('X') still holds the runspace lock (OpState='Running')". A fence is only usable if the
# lock it takes is also given back - so both halves are asserted here, not just the stamp.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-OperationIdentityLifecycle.ps1

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
# 1. THE IDENTITY IS UNIQUE AND CARRIES THE COMPUTER. It has to be unique, because the whole point is
#    to distinguish two operations on the SAME computer - the computer name alone cannot.
# ---------------------------------------------------------------------------------------------
'=== 1. a minted operation id is unique per operation ==='

$idA1 = New-WuuOperationId -Computer 'LIFE-A'
$idA2 = New-WuuOperationId -Computer 'LIFE-A'
Assert-True ([bool]$idA1) 'an id is produced'
Assert-True ($idA1 -ne $idA2) 'two operations on the SAME computer get DIFFERENT ids (a computer name cannot distinguish them)'
Assert-True ($idA1 -match 'LIFE-A') 'the id names its computer, so a log line is readable'

$idOther = New-WuuOperationId -Computer 'LIFE-B'
Assert-True ($idOther -ne $idA1) 'a different computer gets a different id'

# ---------------------------------------------------------------------------------------------
# 2. MINT -> STAMP -> RUNNING. The row becomes owned, and the funnel records who owns it.
# ---------------------------------------------------------------------------------------------
''
'=== 2. stamping a row makes it owned and Running ==='

$row = New-WuuComputerRow -Computer 'LIFE-C'
Assert-Equal $row.OperationId '' 'a fresh row has no owner'
Assert-Equal $row.OpState 'Idle' 'a fresh row is Idle'

$opId = New-WuuOperationId -Computer 'LIFE-C'
# OpStartedAt is passed by the CALLER (production does the same) - the funnel does not invent a start
# time, so that a caller replaying a submission keeps the original timestamp.
$stamp = Update-WuuOperationState -Row $row -OperationIdNew $opId -OpState 'Running' -OpStartedAt (Get-Date) -OpName 'Check'

Assert-True $stamp.Applied 'the stamp is applied'
Assert-Equal $row.OperationId $opId 'the row now carries the operation id'
Assert-Equal $row.OpState 'Running' 'the row is Running'
Assert-True ($null -ne $row.OpStartedAt) 'the start time is recorded'
Assert-Equal $row.OpName 'Check' 'the operation name is recorded (the deadline table keys off it)'

# The row must now be reported busy - that is what the stamp is FOR.
Assert-True (Test-WuuComputerBusy -Row $row -IgnorePending) 'a Running row is reported busy'

# NOTE: Test-WuuComputerBusy consults Pending as well as OpState, and Pending is a DIFFERENT signal -
# the 'a follow-up is queued' flag, owned by the pending-operation work (phase 2 T011), not by this
# step. -IgnorePending isolates the OpState question this suite is about.

# ---------------------------------------------------------------------------------------------
# 3. RELEASE. ClearOperation retires the identity and returns the row to Idle.
# ---------------------------------------------------------------------------------------------
''
'=== 3. releasing the identity makes the row admit another operation ==='

$release = Update-WuuOperationState -Row $row -OperationId $opId -ClearOperation
Assert-True $release.Applied 'the release is applied'
Assert-Equal $row.OperationId '' 'the identity is retired'
Assert-Equal $row.OpState 'Idle' 'the row is Idle again'
Assert-True (-not (Test-WuuComputerBusy -Row $row -IgnorePending)) 'the row is no longer busy, so a retry can be admitted'

# THE INVARIANT THAT MAKES THE RELEASE MANDATORY. A settled row must not still hold the lock.
# -Row is singular on this function (an earlier version of this test passed -Rows and the parameter
# binding error was counted as a violation, which is how a wrong-shaped assertion passes as a failure).
$violations = Test-WuuOperationStateInvariant -Row $row
Assert-Equal @($violations).Count 0 'no invariant violation after a clean release (settled row does not hold the lock)'

# ---------------------------------------------------------------------------------------------
# 4. THE RELEASE IS IDENTITY-GUARDED. A late/superseded job must not unlock someone else's row.
#    This is the same stale-writer rule the funnel enforces, applied to the release path.
# ---------------------------------------------------------------------------------------------
''
'=== 4. a superseded job must not release its replacement''s identity ==='

$row2 = New-WuuComputerRow -Computer 'LIFE-D'
$oldOp = New-WuuOperationId -Computer 'LIFE-D'
$null = Update-WuuOperationState -Row $row2 -OperationIdNew $oldOp -OpState 'Running' -OpStartedAt (Get-Date)
# The operation is reset (e.g. the operator restarted it): the row is settled and the old id retired.
# -Source is validated: only SubmissionFailure / PhaseWaitBookkeeping / OperatorReset are accepted.
$resetCtx = New-WuuResetOperationContext -Reason 'operator restart' -Source 'OperatorReset'
$null = Update-WuuOperationState -Row $row2 -ResetOperation $resetCtx -State 'Error'
Assert-Equal $row2.OperationId '' 'the reset retired the old identity'
Assert-True ([bool]$row2.LastResetOperationId) 'and recorded a reset marker'

# A NEW operation now takes the row.
$newOp = New-WuuOperationId -Computer 'LIFE-D'
$null = Update-WuuOperationState -Row $row2 -OperationIdNew $newOp -OpState 'Running'
Assert-Equal $row2.OperationId $newOp 'the new operation owns the row'
Assert-Equal $row2.LastResetOperationId '' 'taking the row cleared the previous reset marker'
# Now the OLD (superseded) job finishes and tries to release. It must NOT clear the new owner.
$lateRelease = Update-WuuOperationState -Row $row2 -OperationId $oldOp -ClearOperation
Assert-True ($lateRelease.Refused -or -not $lateRelease.Applied) 'the stale release is refused'
Assert-Equal $row2.OperationId $newOp 'the new owner keeps its identity'
Assert-Equal $row2.OpState 'Running' 'and keeps the row Running (it really is running)'

# ---------------------------------------------------------------------------------------------
# 5. WIRING. The identity must actually reach the runspace, or the payload cannot attribute a write.
# ---------------------------------------------------------------------------------------------
''
'=== 5. the identity is injected into the runspace and carried on the job ==='

$updateSrc = [System.IO.File]::ReadAllText((Join-Path $repo 'src\Wuu.WindowsUpdate.psm1'))
Assert-True ($updateSrc -match 'New-WuuOperationId\s+-Computer') 'Start-UpdateCheckJob mints an identity'
Assert-True ($updateSrc -match "SetVariable\('WuuOperationId'" ) 'the identity is injected as $WuuOperationId before the payload runs'
Assert-True ($updateSrc -match 'OperationId\s*=\s*\$opId') 'the job record carries the identity so cleanup can compare it'
Assert-True ($updateSrc -match 'Update-WuuOperationState\s+-Row\s+\$ComputerItem\s+-OperationIdNew') 'the row is stamped through the FUNNEL, not by direct assignment'

$coreSrc = [System.IO.File]::ReadAllText((Join-Path $repo 'src\Wuu.Core.psm1'))
Assert-True ($coreSrc -match "SetVariable\('stateStore'" ) 'the cleanup runspace receives the store so it can release an identity'
$releaseSites = ([regex]::Matches($coreSrc, "\.OpState = 'Idle'")).Count
Assert-True ($releaseSites -ge 2) "the cleanup loop releases identity on BOTH completion and timeout (found $releaseSites of 2)"

# ---------------------------------------------------------------------------------------------
# 6. IDLE-REUSE vs RETIRE (T012/T013). A normal settle RELEASES THE IDENTITY but RETAINS the runspace,
#    so the next operation reuses it (no per-operation runspace churn). An END-OF-OPERATION retire
#    (ClearOperation) detaches AND disposes it exactly once. The two must be distinguishable or a
#    reused runspace is disposed under a live job, or every settle leaks a runspace.
# ---------------------------------------------------------------------------------------------
''
'=== 6. idle-reuse retains the runspace; ClearOperation retires it exactly once ==='

# A fake runspace that records Close/Dispose so we can count retirement. The counter MUST be $global:
# the ScriptMethod body runs with the FUNNEL's $script: scope (Wuu.State), so a $script: counter is
# invisible here - $global: is the one scope shared with the caller.
$global:wuuCloseCount = 0
$global:wuuDisposeCount = 0
$fakeRunspace = New-Object PSObject
$null = Add-Member -InputObject $fakeRunspace -MemberType ScriptMethod -Name Close -Value { $global:wuuCloseCount++ } -Force
$null = Add-Member -InputObject $fakeRunspace -MemberType ScriptMethod -Name Dispose -Value { $global:wuuDisposeCount++ } -Force

$row3 = New-WuuComputerRow -Computer 'LIFE-E'
$op3 = New-WuuOperationId -Computer 'LIFE-E'
$row3.Runspace = $fakeRunspace
$null = Update-WuuOperationState -Row $row3 -OperationIdNew $op3 -OpState 'Running' -OpStartedAt (Get-Date)

# A normal settle via the cleanup-loop release shape (identity retired, runspace KEPT) - the loop writes
# these fields directly, never ClearOperation, precisely so the runspace survives for reuse.
$row3.OpState = 'Idle'; $row3.OperationId = ''; $row3.OpStartedAt = $null; $row3.LastHeartbeatAt = $null
Assert-True ([object]::ReferenceEquals($row3.Runspace, $fakeRunspace)) 'a normal settle RETAINS the runspace (idle-reusable)'
Assert-Equal $global:wuuCloseCount 0 'and does NOT close it (it is reused, not retired)'

# Start-UpdateCheckJob reuses a non-null Runspace rather than recreating one (source contract).
Assert-True ($updateSrc -match 'if\s*\(-not\s+\$ComputerItem\.Runspace\)\s*\{') 'the submission path reuses an existing runspace (creates only when absent)'

# ClearOperation ends the operation: it retires the IDENTITY and DETACHES the runspace, but does NOT
# close it. That split is deliberate - Close can block on a busy pipeline, so it must not run under the
# state gate, and the CALLER owns retirement (close+dispose) after capturing the reference. A caller
# that read `$Row.Runspace` AFTER ClearOperation would see $null and leak - the dead-code bug fixed by
# capturing first (see the source assertions below).
$retire = Update-WuuOperationState -Row $row3 -OperationId $op3 -ClearOperation
Assert-True ($retire.Applied) 'ClearOperation applies on the current owner'
Assert-True ($null -eq $row3.Runspace) 'ClearOperation DETACHES the runspace from the row'
Assert-Equal $global:wuuCloseCount 0 'ClearOperation does NOT itself close it (the caller retires it, outside the gate)'

# The retirement is the CALLER's job, and the reference must be CAPTURED BEFORE the detach or the close
# is dead code. Assert both Core retirement paths capture first.
Assert-True ($coreSrc -match 'if \(\$Computer\.Runspace\)') 'the removal path closes the computer runspace'
$loadCaptures = $coreSrc -match '\$previousRunspace = \$previousRow\.Runspace'
Assert-True $loadCaptures 'the load-reclaim path CAPTURES the outgoing runspace before clearing it (not dead code after a detach)'
Assert-True ($coreSrc -match '\$previousRunspace\.Close\(\)') 'and actually closes the captured runspace'

# ---------------------------------------------------------------------------------------------
# 7. PER-OPERATION DEADLINE (SS5 / review M-3). The per-op table exists (AutoFlow 4 h, Restart 45 m) but
#    NOTHING enforced it: the cleanup loop hard-coded 10 minutes, so an AutoFlow was force-stopped at
#    10 minutes and its row painted Timeout, while $global:OperationTimeoutSeconds was dead config.
#    Both halves are now asserted: the submission STAMPS the deadline, and the cleanup ENFORCES a
#    stamped deadline (not a flat number).
# ---------------------------------------------------------------------------------------------
''
'=== 7. the per-operation deadline is stamped and enforced ==='

# (a) THE RULE. A row with a FUTURE deadline is not expired; a PAST one is; with no deadline the
#     start-time fallback (start + default budget) decides.
# The per-op table ($global:OperationTimeoutSeconds) is set up by Initialize-WuuConfiguration, exactly
# as Start-WuuApplication does - the suite never calls Start-WuuApplication, so it must load it here or
# Get-WuuOperationTimeoutSeconds would fall back to its 1800 default.
Initialize-WuuConfiguration -WuuRoot $repo | Out-Null
$dlRow = New-WuuComputerRow -Computer 'LIFE-DL'
$dlRow.OpName = 'AutoFlow'
Set-WuuOperationDeadline -Row $dlRow -Op 'AutoFlow' | Out-Null
Assert-True ($dlRow.TimeoutExpiresAt -gt (Get-Date).AddHours(3)) 'an AutoFlow gets a ~4h deadline, not 10 minutes'
Assert-True (-not (Test-WuuOperationExpired -Row $dlRow).Expired) 'a fresh AutoFlow has not expired'
Assert-Equal (Test-WuuOperationExpired -Row $dlRow).Basis 'row-deadline' 'the stamped deadline is the basis (the value the operator was shown)'

$dlRow.TimeoutExpiresAt = (Get-Date).AddMinutes(-1)
$expiredVerdict = Test-WuuOperationExpired -Row $dlRow
Assert-True ($expiredVerdict.Expired) 'a past deadline is expired'
Assert-True ($expiredVerdict.OvershootSeconds -ge 50) 'the overshoot is reported'

$noDeadlineRow = New-WuuComputerRow -Computer 'LIFE-DL2'
$fallbackVerdict = Test-WuuOperationExpired -Row $noDeadlineRow -StartedAt (Get-Date).AddMinutes(-40)
Assert-True ($fallbackVerdict.Expired) 'with no stamped deadline the start-time fallback (start + default 30m) expires'
Assert-Equal $fallbackVerdict.Basis 'start-time-fallback' 'and reports the fallback basis (so a non-standard submitter is visible)'

# (b) THE WIRING. Submission must STAMP the deadline; the cleanup must ENFORCE the stamped one.
Assert-True ($updateSrc -match 'Set-WuuOperationDeadline\s+-Row\s+\$ComputerItem\s+-Op\s+\$Op') 'Start-UpdateCheckJob stamps the per-op deadline at submission'
Assert-True ($coreSrc -match 'TestJobExpiredScript') 'the cleanup loop has the deadline helper injected'
Assert-True ($coreSrc -match 'TestJobExpiredScript\s+-Computer\s+\$runspace\.Computer\s+-StartTime\s+\$runspace\.StartTime') 'the cleanup loop enforces the per-job deadline'
Assert-True ($coreSrc -notmatch 'TotalMinutes\s*-gt\s*10') 'the flat 10-minute cutoff is GONE (it ignored the per-op table)'
Assert-True ($coreSrc -match "SetVariable\('OperationDefaultBudgetSeconds'") 'the fallback default budget is injected into the cleanup runspace'


''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
