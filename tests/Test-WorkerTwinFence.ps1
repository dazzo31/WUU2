# Test: T007 / step C — the WORKER TWIN is fenced, and agrees with the module funnel.
#
# WHY THIS SUITE EXISTS
# ---------------------
# The two injected state helpers in New-ComputerRunspace (`SetComputerStateScript`,
# `SetComputerTimeoutScript`) wrote State/Status/deadline with NO identity check and NO terminal guard.
# The module funnel has enforced both since T007's state layer, so the invariant "a superseded
# operation cannot write" was true of some writers and false of the ones that actually run inside every
# payload - which is to say, false where it mattered.
#
# The twin CANNOT call the module function (an isolated runspace does not see module exports), so the
# rule has to exist twice. That is the same shape as the C2 defect in the CLI edition, where two copies
# of a helper silently diverged. This suite therefore asserts the copies AGREE on identical input,
# rather than asserting each one separately - a test of one copy cannot notice a divergence.
#
# HOW THE TWIN IS OBTAINED: extracted from the live scriptblock injected by New-ComputerRunspace, so
# the test cannot pass against a copy pasted into the test file.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-WorkerTwinFence.ps1

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
# Extracting the twin from the real injection site.
#
# New-ComputerRunspace opens a runspace and injects into it; calling it needs a full context. Instead
# the SCRIPTBLOCK LITERALS are parsed out of the module source, which is the same text production
# injects - and the assertion below proves the extraction found the fenced body rather than an
# unrelated block.
# ---------------------------------------------------------------------------------------------
$src = [System.IO.File]::ReadAllText((Join-Path $repo 'src\Wuu.WindowsUpdate.psm1'))
# Core's payload source, used by the effect-boundary wiring assertions (the guard must sit immediately
# before each real effect, not merely exist) and the cleanup-timeout helper below.
$coreSrcForEffect = [System.IO.File]::ReadAllText((Join-Path $repo 'src\Wuu.Core.psm1'))

function Get-InjectedScriptBlock([string]$Source, [string]$VariableName) {
    $marker = "SetVariable('$VariableName', [scriptblock]::Create({"
    $start = $Source.IndexOf($marker)
    if ($start -lt 0) { return $null }
    $start = $start + $marker.Length
    # Walk braces to the matching close of the scriptblock body.
    $depth = 1
    $i = $start
    while ($i -lt $Source.Length -and $depth -gt 0) {
        $ch = $Source[$i]
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') { $depth-- }
        $i++
    }
    if ($depth -ne 0) { return $null }
    return $Source.Substring($start, $i - $start - 1)
}

$timeoutBody = Get-InjectedScriptBlock $src 'SetComputerTimeoutScript'
$stateBody   = Get-InjectedScriptBlock $src 'SetComputerStateScript'

# HEADLESS BOUNDARY (validation.md Phase 1 correction 2). An injected worker runspace has NO dispatcher,
# so a twin that touches the ListView / WPF is wrong by construction - and now also dead, because the
# grid holds DETACHED view rows it cannot see. This is a regression guard on the whole injected surface,
# not just the two named twins: the payload writes are headless engine writes, and the projection
# repaints them.
$wpfInInjected = @()
foreach ($varName in @('SetComputerStateScript','SetComputerTimeoutScript','SetComputerFencedFieldsScript','SetPendingOpScript','SetCleanupTimeoutScript','SafeUpdateListViewItemScript')) {
    $body = Get-InjectedScriptBlock $src $varName
    if (-not $body) { continue }
    if ($body -match 'uiHash|ListView|Listview|Dispatcher|System\.Windows|ContainerFromItem') { $wpfInInjected += $varName }
}
Assert-True ($wpfInInjected.Count -eq 0) ("no injected worker twin touches the ListView/WPF (offenders: " + (@($wpfInInjected) -join ', ') + ")")

# And the ENGINE modules must not reference WPF at all. Checked on comment-stripped source so a
# documentation mention ("does not touch the ListView") cannot trip the scan.
function Get-CodeWithoutComments([string]$Text) {
    $noBlock = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    return [regex]::Replace($noBlock, '(?m)^\s*#.*$', '')
}
foreach ($engineModule in @('Wuu.State.psm1','Wuu.Configuration.psm1','Wuu.Gui.psm1')) {
    $modText = Get-CodeWithoutComments ([System.IO.File]::ReadAllText((Join-Path $repo "src\$engineModule")))
    $wpfHit = $modText -match 'System\.Windows|PresentationCore|PresentationFramework|ContainerFromItem'
    # Wuu.Gui is ALLOWED exactly one WPF touch: Get-WuuColorBrush builds a Brush. Everything else in it is
    # pure. A second hit means WPF leaked into the mapping.
    if ($engineModule -eq 'Wuu.Gui.psm1') {
        $brushHits = ([regex]::Matches($modText, 'System\.Windows')).Count
        Assert-True ($brushHits -le 2) "Wuu.Gui confines WPF to Get-WuuColorBrush (found $brushHits System.Windows reference(s))"
    } else {
        Assert-True (-not $wpfHit) "$engineModule is headless (no WPF reference in its code)"
    }
}

Assert-True ([bool]$timeoutBody) 'the injected timeout helper was located in Wuu.WindowsUpdate.psm1'
Assert-True ([bool]$stateBody) 'the injected state helper was located in Wuu.WindowsUpdate.psm1'

# Prove the extraction found the FENCED body, not an older/unrelated block. If this fails, every
# assertion below would be testing something other than the twin.
Assert-True ($timeoutBody -match 'LastResetOperationId') 'the timeout twin contains the reset fence'
Assert-True ($stateBody -match 'LastResetOperationId') 'the state twin contains the reset fence'
Assert-True ($timeoutBody -match 'OperationId') 'the timeout twin contains the identity fence'
Assert-True ($stateBody -match 'OperationId') 'the state twin contains the identity fence'

# And prove it no longer reaches for the ListView - the engine/view decoupling this step delivers.
Assert-True ($timeoutBody -notmatch 'ListView|EditItem|CommitEdit|ItemContainerGenerator') 'the timeout twin no longer touches the ListView'
Assert-True ($stateBody -notmatch 'ListView|EditItem|CommitEdit|ItemContainerGenerator') 'the state twin no longer touches the ListView'

# The twins must signal a redraw through the STORE, or the UI would never learn of the change.
Assert-True ($timeoutBody -match 'stateStore\.Touch\(\)') 'the timeout twin signals a redraw via the store'
Assert-True ($stateBody -match 'stateStore\.Touch\(\)') 'the state twin signals a redraw via the store'

# ---------------------------------------------------------------------------------------------
# Driving the twin against the module funnel on identical rows.
# ---------------------------------------------------------------------------------------------
$stateFn   = [scriptblock]::Create($stateBody)
$timeoutFn = [scriptblock]::Create($timeoutBody)

# A store so the twins' live-row check passes, plus a runspace-scope variable for writer identity.
$store = New-WuuStateStore
$script:stateStore = $store

function New-FencedRow([string]$Computer, [string]$OpId, [string]$State = 'Searching', [string]$OpState = 'Running') {
    $r = New-WuuComputerRow -Computer $Computer
    $r.State = $State
    $r.OpState = $OpState
    $r.OperationId = $OpId
    Add-WuuComputerRow -Store $store -Row $r | Out-Null
    return $r
}

# ---------------------------------------------------------------------------------------------
# 1. IDENTITY. A worker holding operation A must not write to a row owned by B.
# ---------------------------------------------------------------------------------------------
''
'=== 1. the twin refuses a superseded writer (identity fence) ==='

$rowB = New-FencedRow 'TWIN-B' 'op-B'
$WuuOperationId = 'op-A'         # this runspace is running a DIFFERENT operation
& $stateFn -Computer $rowB -State 'Complete'
Assert-Equal $rowB.State 'Searching' 'a worker from another operation cannot change the row State'
Assert-Equal $rowB.OperationId 'op-B' 'and cannot steal ownership'

# The module funnel refuses the identical write - so the copies AGREE. This is the assertion that
# catches divergence; asserting only the twin would miss the twin drifting from the funnel.
$modRowB = New-FencedRow 'TWIN-B-MOD' 'op-B'
$res = Update-WuuOperationState -Row $modRowB -OperationId 'op-A' -State 'Complete'
Assert-True ($res.Refused) 'the module funnel refuses the same stale write'
Assert-Equal $modRowB.State 'Searching' 'and the module copy leaves the row unchanged too'
Assert-Equal $rowB.State $modRowB.State 'the twin and the funnel AGREE on the stale-write outcome'

# A matching writer IS allowed.
$rowOk = New-FencedRow 'TWIN-OK' 'op-C'
$WuuOperationId = 'op-C'
& $stateFn -Computer $rowOk -State 'Installing'
Assert-Equal $rowOk.State 'Installing' 'the owning writer may write'

# An UNATTRIBUTED write is permitted (row population has no operation).
$rowUnattr = New-FencedRow 'TWIN-UNATTR' ''
$WuuOperationId = ''
& $stateFn -Computer $rowUnattr -State 'Connected'
Assert-Equal $rowUnattr.State 'Connected' 'an unattributed write is still permitted (populating a row with no operation)'

# ---------------------------------------------------------------------------------------------
# 2. RESET FENCE.
# ---------------------------------------------------------------------------------------------
''
'=== 2. the twin refuses a writer whose operation was reset ==='

$rowReset = New-FencedRow 'TWIN-RESET' 'op-D'
$rowReset.LastResetOperationId = 'reset-xyz'
$WuuOperationId = 'op-D'
& $stateFn -Computer $rowReset -State 'Complete'
Assert-Equal $rowReset.State 'Searching' 'a writer is refused once its operation has been reset'

# ---------------------------------------------------------------------------------------------
# 3. TERMINAL GUARD. A settled row is not rewritten by a bare transition.
# ---------------------------------------------------------------------------------------------
''
'=== 3. the twin refuses to rewrite a settled row ==='

foreach ($terminal in @('Error', 'Timeout', 'Complete')) {
    $rowT = New-FencedRow "TWIN-$terminal" 'op-E'
    $rowT.State = $terminal
    $WuuOperationId = 'op-E'
    & $stateFn -Computer $rowT -State 'Searching'
    Assert-Equal $rowT.State $terminal "a settled '$terminal' row is not rewritten to 'Searching'"
}

# A retry IS legal - but only over a row whose operation has been RELEASED. That is the finding this
# suite recorded, and it is why step B had to land before a retry could work at all:
#
#   settle (State=Error)  ->  the cleanup loop RELEASES the identity (OpState=Idle, id retired)
#                         ->  a new attributed operation adopts the row
#
# Adopting while the row is still Running is deliberately REFUSED ("cannot adopt ... the row is
# Running under ..."), and the module funnel refuses it identically - verified below. An earlier
# version of this assertion skipped the release step and expected the retry to be permitted; both
# copies refused, and AGREEING on the refusal is the property that matters.
$rowRetry = New-FencedRow 'TWIN-RETRY' 'op-F'
$rowRetry.State = 'Error'
# Release, exactly as the cleanup loop does when a job settles.
$rowRetry.OpState = 'Idle'
$rowRetry.OperationId = ''
$WuuOperationId = ''
& $stateFn -Computer $rowRetry -State 'Searching' -OperationId 'op-RETRY'
Assert-Equal $rowRetry.State 'Searching' 'a retry carrying a NEW attributed operation may rewrite a released row'

# And the module funnel permits the same retry, so the two agree on the retry rule too.
$modRetry = New-FencedRow 'TWIN-RETRY-MOD' 'op-F'
$modRetry.State = 'Error'
$null = Update-WuuOperationState -Row $modRetry -OperationId 'op-F' -ClearOperation
$retryRes = Update-WuuOperationState -Row $modRetry -OperationId 'op-RETRY' -OperationIdNew 'op-RETRY' -State 'Searching'
Assert-True ($retryRes.Applied) 'the module funnel also permits the attributed retry after release'
Assert-Equal $rowRetry.State $modRetry.State 'the twin and the funnel AGREE on the retry outcome'

# AGREEMENT ON THE REFUSAL TOO. Adopting while the row is still Running must be refused by BOTH, or a
# retry could silently hijack a live operation.
$rowBusy = New-FencedRow 'TWIN-RETRY-BUSY' 'op-LIVE' 'Error' 'Running'
$WuuOperationId = ''
& $stateFn -Computer $rowBusy -State 'Searching' -OperationId 'op-HIJACK'
Assert-Equal $rowBusy.State 'Error' 'the twin refuses to adopt a row that is still Running'
Assert-Equal $rowBusy.OperationId 'op-LIVE' 'and does not steal the live identity'

$modBusy = New-FencedRow 'TWIN-RETRY-BUSY-MOD' 'op-LIVE' 'Error' 'Running'
$busyRes = Update-WuuOperationState -Row $modBusy -OperationId 'op-HIJACK' -OperationIdNew 'op-HIJACK' -State 'Searching'
Assert-True ($busyRes.Refused) 'the module funnel refuses the same hijack'
Assert-Equal $rowBusy.OperationId $modBusy.OperationId 'the twin and the funnel AGREE on the adoption refusal'

# ---------------------------------------------------------------------------------------------
# 4. THE TIMEOUT TWIN.
# ---------------------------------------------------------------------------------------------
''
'=== 4. the timeout twin sets the deadline, and is fenced the same way ==='

$rowTo = New-FencedRow 'TWIN-TIMEOUT' 'op-G'
$WuuOperationId = 'op-G'
& $timeoutFn -Computer $rowTo -Phase 'Search' -TimeoutSec 60
Assert-Equal $rowTo.State 'Timeout' 'the timeout twin sets the terminal Timeout state'
Assert-Equal $rowTo.UpdatesStatus 'Timeout' 'and the updates status'
Assert-True ($null -ne $rowTo.TimeoutExpiresAt) 'and records the deadline'
Assert-Equal $rowTo.TimeoutSource 'Search' 'and records which phase timed out'
Assert-Equal $rowTo.Color 'Timeout' 'and sets the colour NAME (no WPF brush from a worker)'

# A superseded timeout write is refused.
$rowTo2 = New-FencedRow 'TWIN-TIMEOUT2' 'op-H'
$WuuOperationId = 'op-STALE'
& $timeoutFn -Computer $rowTo2 -Phase 'Search' -TimeoutSec 60
Assert-Equal $rowTo2.State 'Searching' 'a stale writer cannot mark the row Timeout'
Assert-True ($null -eq $rowTo2.TimeoutExpiresAt) 'and cannot set a deadline on it'

# A settled row is not re-settled into Timeout.
$rowTo3 = New-FencedRow 'TWIN-TIMEOUT3' 'op-I'
$rowTo3.State = 'Complete'
$WuuOperationId = 'op-I'
& $timeoutFn -Computer $rowTo3 -Phase 'Search' -TimeoutSec 60
Assert-Equal $rowTo3.State 'Complete' 'a settled Complete row is not re-marked Timeout'

# ---------------------------------------------------------------------------------------------
# 5. DELETED ROWS. Writing to a row the operator removed is a leak, not a write.
# ---------------------------------------------------------------------------------------------
''
'=== 5. the twin refuses to write to a row no longer in the store ==='

$rowGone = New-FencedRow 'TWIN-GONE' 'op-J'
$WuuOperationId = 'op-J'
Remove-WuuComputerRow -Store $store -Computer 'TWIN-GONE' | Out-Null
& $stateFn -Computer $rowGone -State 'Installing'
Assert-Equal $rowGone.State 'Searching' 'a row removed from the store is not written to'

$rowReplaced = New-FencedRow 'TWIN-REPLACED' 'op-REPLACED'
$replacementRow = New-WuuComputerRow -Computer 'TWIN-REPLACED'
Add-WuuComputerRow -Store $store -Row $replacementRow | Out-Null
$WuuOperationId = 'op-REPLACED'
$replacementRevision = $store.Revision
& $stateFn -Computer $rowReplaced -State 'Installing'
Assert-Equal $rowReplaced.State 'Searching' 'an old row reference cannot be written after same-name replacement'
& $timeoutFn -Computer $rowReplaced -Phase 'Search' -TimeoutSec 60
Assert-True ($null -eq $rowReplaced.TimeoutExpiresAt) 'an old row reference cannot receive a timeout after replacement'
Assert-Equal $store.Revision $replacementRevision 'replaced-row refusals do not advance the store revision'
Assert-True ([object]::ReferenceEquals($store.ByName['TWIN-REPLACED'], $replacementRow)) 'the replacement remains the authoritative row'

$literalRow = New-FencedRow 'TWIN-LITERAL' 'op-LITERAL'
$WuuOperationId = 'op-LITERAL'
$literalResult = & $stateFn -Computer $literalRow -State 'Downloading' -Status 'Downloading 3 Updates (42MB).'
Assert-True ($literalResult.Applied -and -not $literalResult.Refused) 'literal status update reports applied'
Assert-Equal $literalRow.Status 'Downloading 3 Updates (42MB).' 'literal progress text is preserved verbatim'
$detailResult = & $stateFn -Computer $literalRow -State 'Downloading' -StatusDetail 'phase one'
Assert-True $detailResult.Applied 'status-detail update reports applied'
Assert-Equal $literalRow.Status 'Downloading updates... phase one' 'status detail retains its existing appended semantics'

'=== 6. actual factory injection across two bounded worker runspaces ==='

Add-Type -TypeDefinition @'
using System.Management.Automation.Runspaces;
using System.Threading.Tasks;
public static class WuuFenceRunspaceCleanup {
    public static bool CloseAndDispose(Runspace runspace, int timeoutMilliseconds) {
        return Task.Run(() => { runspace.Close(); runspace.Dispose(); }).Wait(timeoutMilliseconds);
    }
}
'@

$realStore = New-WuuStateStore
# The funnel resolves the store from -Store or $global:stateStore, and enforces the live-row check
# against THAT store. Production has exactly one global store, so point the global at this fixture
# too - otherwise the funnel would compare against a different (or absent) store and refuse.
$global:stateStore = $realStore
$realRow = New-WuuComputerRow -Computer 'REAL-TWIN'
Add-WuuComputerRow -Store $realStore -Row $realRow | Out-Null
$null = Update-WuuOperationState -Row $realRow -OperationIdNew 'real-A' -OpState 'Running' -State 'Searching'
Initialize-WuuWindowsUpdateContext -Context @{
    StateStore = $realStore
    UiHash = @{}
    UpdatesHash = @{}
    PerformanceHash = @{}
    ErrorSuggestions = @{}
    EnableDebugLogging = $false
}

$entered = New-Object System.Threading.ManualResetEventSlim($false)
$releaseWriter = New-Object System.Threading.ManualResetEventSlim($false)
$workerA = $null
$workerB = $null
$pipelineA = $null
$pipelineB = $null
$handleA = $null
$handleB = $null
$collectedA = $false
$collectedB = $false
$workerBody = @'
param($Row, $ExpectedStore, $Entered, $ReleaseWriter, $Pause, $NewState)
$ErrorActionPreference = 'Stop'
if (-not [object]::ReferenceEquals($stateStore, $ExpectedStore)) { throw 'Injected store is not the authoritative instance' }
if (-not [object]::ReferenceEquals($stateStore.ByName[$Row.Computer], $Row)) { throw 'Injected row is not the authoritative instance' }
if (-not $WuuOperationId) { throw 'Injected operation identity is absent' }
if ($SetComputerStateScript -isnot [scriptblock]) { throw 'Injected state helper is absent' }
# The payloads CALL the fenced multi-field writer at every converted site, so its ABSENCE would throw
# inside every payload and be swallowed by their catches - the grid would silently stop updating.
if ($SetComputerFencedFieldsScript -isnot [scriptblock]) { throw 'Injected multi-field writer is absent' }
$capturedWriter = [string]$WuuOperationId
$Entered.Set()
if ($Pause -and -not $ReleaseWriter.Wait(10000)) { throw 'Writer release barrier timed out' }
if ($WuuOperationId -cne $capturedWriter) { throw 'Worker identity changed while the payload was running' }
if ($NewState -eq 'Timeout') {
    $helperResult = & $SetComputerTimeoutScript -Computer $Row -Phase 'Search' -TimeoutSec 60
} else {
    $helperResult = & $SetComputerStateScript -Computer $Row -State $NewState
}
# Also drive the fenced multi-field writer IN THE REAL RUNSPACE: a converted payload depends on it
# resolving here, not merely on the module copy existing.
$multiFieldResult = & $SetComputerFencedFieldsScript -Computer $Row -OperationId $capturedWriter -Fields @{ Status = 'worker-multifield-ok' }
[pscustomobject]@{
    Executed = $true
    Writer = $capturedWriter
    Row = $Row
    Result = $helperResult
    MultiField = $multiFieldResult
}
'@

try {
    $workerA = New-ComputerRunspace -ComputerItem $realRow
    $workerB = New-ComputerRunspace -ComputerItem $realRow
    Assert-True ($workerA.SessionStateProxy.GetVariable('SetComputerStateScript') -is [scriptblock]) 'factory actually injected a state scriptblock'
    $workerA.SessionStateProxy.SetVariable('WuuOperationId', 'real-A')
    $workerB.SessionStateProxy.SetVariable('WuuOperationId', 'real-B')
    $pipelineA = [powershell]::Create()
    $pipelineA.Runspace = $workerA
    $null = $pipelineA.AddScript($workerBody).AddArgument($realRow).AddArgument($realStore).AddArgument($entered).AddArgument($releaseWriter).AddArgument($true).AddArgument('Complete')
    $handleA = $pipelineA.BeginInvoke()
    if (-not $entered.Wait(10000)) { throw 'Writer A did not reach its barrier' }

    $retireResult = Update-WuuOperationState -Row $realRow -OperationId 'real-A' -ClearOperation
    $adoptResult = Update-WuuOperationState -Row $realRow -OperationIdNew 'real-B' -OpState 'Running' -State 'Searching'
    Assert-True ($retireResult.Applied -and $adoptResult.Applied) 'A is retired before B is admitted through the module funnel'

    $pipelineB = [powershell]::Create()
    $pipelineB.Runspace = $workerB
    $revisionBeforeAccepted = $realStore.Revision
    $null = $pipelineB.AddScript($workerBody).AddArgument($realRow).AddArgument($realStore).AddArgument($entered).AddArgument($releaseWriter).AddArgument($false).AddArgument('Installing')
    $handleB = $pipelineB.BeginInvoke()
    if (-not $handleB.AsyncWaitHandle.WaitOne(10000)) { throw 'Writer B did not complete' }
    $collectedB = $true
    $outputB = @($pipelineB.EndInvoke($handleB))
    Assert-Equal $pipelineB.Streams.Error.Count 0 'writer B has no hidden pipeline errors'
    Assert-True ($outputB.Count -eq 1 -and $outputB[0].Executed -and $outputB[0].Writer -eq 'real-B') 'writer B executed with its injected identity'
    Assert-True ($outputB[0].MultiField.Applied -and -not $outputB[0].MultiField.Refused) 'the multi-field fenced writer resolves and applies IN A REAL factory runspace (a converted payload depends on this)'
    Assert-True ($outputB[0].Result.Applied -and -not $outputB[0].Result.Refused) 'writer B explicitly reports an applied write'
    Assert-Equal $realRow.State 'Installing' 'actual worker B writes the shared authoritative row'
    Assert-True ($realStore.Revision -gt $revisionBeforeAccepted) 'an accepted real-worker write publishes a revision'
    $revisionBeforeStale = $realStore.Revision

    $releaseWriter.Set()
    if (-not $handleA.AsyncWaitHandle.WaitOne(10000)) { throw 'Writer A did not complete' }
    $collectedA = $true
    $outputA = @($pipelineA.EndInvoke($handleA))
    Assert-Equal $pipelineA.Streams.Error.Count 0 'writer A has no hidden pipeline errors'
    Assert-True ($outputA.Count -eq 1 -and $outputA[0].Executed -and $outputA[0].Writer -eq 'real-A') 'delayed writer A actually executed with its original identity'
    Assert-True ($outputA[0].Result.Refused -and -not $outputA[0].Result.Applied) 'delayed writer A explicitly reports refusal, not a swallowed failure'
    Assert-True ([object]::ReferenceEquals($outputA[0].Row, $realRow)) 'the worker and main session observe the same row instance'
    Assert-Equal $realRow.State 'Installing' 'actual superseded writer A cannot overwrite B'
    Assert-Equal $realRow.OperationId 'real-B' 'actual superseded writer A cannot steal B ownership'
    Assert-Equal $realStore.Revision $revisionBeforeStale 'a rejected real-worker write does not publish a revision'

    foreach ($scenario in @('Reset', 'Remove', 'ReplaceState', 'ReplaceTimeout')) {
        $caseRow = New-WuuComputerRow -Computer ('REAL-' + $scenario)
        Add-WuuComputerRow -Store $realStore -Row $caseRow | Out-Null
        $caseId = 'real-' + $scenario
        $null = Update-WuuOperationState -Row $caseRow -OperationIdNew $caseId -OpState 'Running' -State 'Searching'
        $workerA.SessionStateProxy.SetVariable('WuuOperationId', $caseId)
        $entered.Reset()
        $releaseWriter.Reset()
        $pipelineA.Dispose()
        $pipelineA = [powershell]::Create()
        $pipelineA.Runspace = $workerA
        $nextState = 'Installing'
        if ($scenario -eq 'ReplaceTimeout') { $nextState = 'Timeout' }
        $null = $pipelineA.AddScript($workerBody).AddArgument($caseRow).AddArgument($realStore).AddArgument($entered).AddArgument($releaseWriter).AddArgument($true).AddArgument($nextState)
        $collectedA = $false
        $handleA = $pipelineA.BeginInvoke()
        if (-not $entered.Wait(10000)) { throw ($scenario + ': writer did not reach its barrier') }
        $expectedState = 'Searching'
        switch ($scenario) {
            'Reset' {
                $resetContext = New-WuuResetOperationContext -Reason 'synthetic reset' -Source 'OperatorReset'
                $resetResult = Update-WuuOperationState -Row $caseRow -ResetOperation $resetContext -State 'Error'
                if (-not $resetResult.Applied) { throw 'Synthetic reset was refused' }
                $expectedState = 'Error'
            }
            'Remove' { Remove-WuuComputerRow -Store $realStore -Computer $caseRow.Computer | Out-Null }
            default {
                $caseReplacement = New-WuuComputerRow -Computer $caseRow.Computer
                Add-WuuComputerRow -Store $realStore -Row $caseReplacement | Out-Null
            }
        }
        $caseRevision = $realStore.Revision
        $releaseWriter.Set()
        if (-not $handleA.AsyncWaitHandle.WaitOne(10000)) { throw ($scenario + ': writer did not complete') }
        $collectedA = $true
        $caseOutput = @($pipelineA.EndInvoke($handleA))
        Assert-Equal $pipelineA.Streams.Error.Count 0 "$scenario real worker has no pipeline errors"
        Assert-True ($caseOutput.Count -eq 1 -and $caseOutput[0].Executed -and $caseOutput[0].Writer -eq $caseId) "$scenario real worker executed with its captured identity"
        Assert-True ($caseOutput[0].Result.Refused -and -not $caseOutput[0].Result.Applied) "$scenario real worker explicitly reports refusal"
        Assert-Equal $caseRow.State $expectedState "$scenario real worker cannot overwrite the retired row"
        Assert-True ($null -eq $caseRow.TimeoutExpiresAt) "$scenario real worker cannot set a retired-row deadline"
        Assert-Equal $realStore.Revision $caseRevision "$scenario refused real-worker write publishes no revision"
        if ($scenario -like 'Replace*') {
            Assert-True ([object]::ReferenceEquals($realStore.ByName[$caseRow.Computer], $caseReplacement)) "$scenario replacement stays authoritative"
        }
    }

    $pipelineB.Commands.Clear()
    $pipelineB.Streams.Error.Clear()
    $malformedRow = [pscustomobject]@{ Computer = 'REAL-MALFORMED'; State = 'Searching' }
    $null = $pipelineB.AddScript('param($Row) & $SetComputerStateScript -Computer $Row -State Installing').AddArgument($malformedRow)
    $collectedB = $false
    $handleB = $pipelineB.BeginInvoke()
    if (-not $handleB.AsyncWaitHandle.WaitOne(10000)) { throw 'Malformed-row probe did not complete' }
    $malformedThrew = $false
    $collectedB = $true
    try { $null = $pipelineB.EndInvoke($handleB) } catch { $malformedThrew = $true }
    Assert-True ($malformedThrew -or $pipelineB.Streams.Error.Count -gt 0) 'unexpected injected-helper failure is visible, not mistaken for refusal'
    Assert-Equal $malformedRow.State 'Searching' 'missing row properties fail before any state mutation'
} catch {
    Assert-True $false ('real injection failed: ' + $_.Exception.Message)
} finally {
    $releaseWriter.Set()
    foreach ($pending in @(
        @{ Pipeline = $pipelineA; Handle = $handleA; Collected = $collectedA },
        @{ Pipeline = $pipelineB; Handle = $handleB; Collected = $collectedB }
    )) {
        if ($pending.Pipeline) {
            try {
                if ($pending.Pipeline.InvocationStateInfo.State -eq 'Running') {
                    $stopHandle = $pending.Pipeline.BeginStop($null, $null)
                    if (-not $stopHandle.AsyncWaitHandle.WaitOne(10000)) { throw 'Worker stop exceeded its teardown deadline' }
                    $pending.Pipeline.EndStop($stopHandle)
                }
                if ($pending.Handle -and -not $pending.Collected) {
                    if (-not $pending.Handle.AsyncWaitHandle.WaitOne(10000)) { throw 'Worker drain exceeded its teardown deadline' }
                    try { $null = $pending.Pipeline.EndInvoke($pending.Handle) } catch {
                        Write-Host ('TEARDOWN: ' + $_.Exception.Message)
                    }
                    foreach ($workerError in $pending.Pipeline.Streams.Error) { Write-Host ('TEARDOWN: ' + $workerError) }
                }
                $pending.Pipeline.Dispose()
            } catch { Assert-True $false ('bounded pipeline teardown failed: ' + $_.Exception.Message) }
        }
    }
    foreach ($worker in @($workerA, $workerB)) {
        if ($worker) {
            try {
                Assert-True ([WuuFenceRunspaceCleanup]::CloseAndDispose($worker, 10000)) 'factory runspace closes and disposes within its deadline'
            } catch { Assert-True $false ('bounded runspace teardown failed: ' + $_.Exception.Message) }
        }
    }
    $entered.Dispose()
    $releaseWriter.Dispose()
}

''
'=== 7. the effect-boundary authorization helper (G6) ==='

# WHY SEPARATE FROM THE STATE FENCE: the fence stops a superseded payload WRITING the row, but the
# payload keeps running and could still download/install/reboot. This helper decides whether an EFFECT
# may be dispatched, and it FAILS CLOSED: an unattributed effect is refused even though an unattributed
# STATE write is permitted. The helper is extracted from the live injection site, like the twins.
$effectBody = Get-InjectedScriptBlock $src 'TestEffectAuthorizedScript'
Assert-True ([bool]$effectBody) 'the effect-authorization helper was located in Wuu.WindowsUpdate.psm1'
Assert-True ($effectBody -match 'UnattributedEffect') 'the helper refuses an unattributed effect (fail-closed)'
Assert-True ($effectBody -match 'ReferenceEquals') 'the helper checks the row is still live before authorizing'

$effectFn = [scriptblock]::Create($effectBody)
$effectStore = New-WuuStateStore
$script:stateStore = $effectStore

function New-EffectRow([string]$Computer, [string]$OpId, [string]$OpState = 'Running') {
    $r = New-WuuComputerRow -Computer $Computer
    $r.OpState = $OpState
    $r.OperationId = $OpId
    $r.State = 'Searching'
    Add-WuuComputerRow -Store $effectStore -Row $r | Out-Null
    return $r
}

# The owning writer is authorized to act.
$actRow = New-EffectRow 'EFF-OK' 'op-EFF-OK'
$WuuOperationId = 'op-EFF-OK'
$actOk = & $effectFn -Computer $actRow
Assert-True ($actOk.Authorized) 'the owning writer is authorized to dispatch an effect'

# A superseded writer is refused - the effect is stopped, not merely made silent.
$staleRow = New-EffectRow 'EFF-STALE' 'op-EFF-LIVE'
$WuuOperationId = 'op-EFF-STALE'
$actStale = & $effectFn -Computer $staleRow
Assert-True (-not $actStale.Authorized) 'a superseded writer is refused an effect'
Assert-Equal $actStale.Reason 'StaleOperation' 'and the refusal names staleness'

# An UNATTRIBUTED effect is refused (fail-closed). Note the deliberate asymmetry with the state fence:
# an unattributed STATE write is allowed (row population), an unattributed EFFECT is not.
$unattrRow = New-EffectRow 'EFF-UNATTR' 'op-EFF-OWNER'
$WuuOperationId = ''
$actUnattr = & $effectFn -Computer $unattrRow
Assert-True (-not $actUnattr.Authorized) 'an unattributed effect is refused (fail-closed)'
Assert-Equal $actUnattr.Reason 'UnattributedEffect' 'and the refusal names the missing attribution'

# A reset operation is refused an effect.
$resetRow = New-EffectRow 'EFF-RESET' 'op-EFF-RESET'
$resetRow.LastResetOperationId = 'reset-abc'
$WuuOperationId = 'op-EFF-RESET'
$actReset = & $effectFn -Computer $resetRow
Assert-True (-not $actReset.Authorized) 'a reset operation is refused an effect'

# A removed/replaced row is refused an effect.
$goneRow = New-EffectRow 'EFF-GONE' 'op-EFF-GONE'
$WuuOperationId = 'op-EFF-GONE'
Remove-WuuComputerRow -Store $effectStore -Computer 'EFF-GONE' | Out-Null
$actGone = & $effectFn -Computer $goneRow
Assert-True (-not $actGone.Authorized) 'a row removed from the store is refused an effect'

# WIRING: the guard must actually sit before each real effect site, not merely exist. A bounded-character
# window tolerates the refusal-report block between the guard and the effect while still failing if the
# guard drifts away or the effect is dispatched unguarded. This is a DRIFT GUARD (source ordering), not
# proof the guard executed - the plan is explicit that source matches corroborate, they do not prove.
Assert-True ($coreSrcForEffect -match "(?s)TestEffectAuthorizedScript.{0,2000}?-Operation 'Download'") 'the download effect is guarded before dispatch'
Assert-True ($coreSrcForEffect -match "(?s)TestEffectAuthorizedScript.{0,2000}?-Operation 'Install'") 'the install effect is guarded before dispatch'
Assert-True ($coreSrcForEffect -match '(?s)TestEffectAuthorizedScript.{0,2000}?Restart-Computer') 'the restart effect is guarded before dispatch'
Assert-True ($coreSrcForEffect -match '(?s)TestEffectAuthorizedScript.{0,2000}?Stop-Service') 'the service-action effect is guarded before dispatch'
# The pre-flight service check/start and the auto-recovery path are also real remote effects (G6).
Assert-True ($coreSrcForEffect -match "(?s)TestEffectAuthorizedScript.{0,600}?-Action 'Check'") 'the pre-flight service check is guarded'
Assert-True ($coreSrcForEffect -match "(?s)TestEffectAuthorizedScript.{0,600}?-Action 'Start'") 'the best-effort service start is guarded'
Assert-True ($coreSrcForEffect -match '(?s)TestEffectAuthorizedScript.{0,600}?Invoke-AutoRecovery') 'the auto-recovery effect is guarded'
# A REFUSAL MUST NOT THROW. Throwing would fall into the payload's shared Catch, which paints
# State/UpdatesStatus='Error', arms a stale auto-retry and aborts the rest of the chain for an operation
# that merely no longer owns the computer. Each guard block must therefore end in a clean `return`.
$refusalThrows = ([regex]::Matches($coreSrcForEffect, "refused before dispatch")).Count
Assert-Equal $refusalThrows 0 'no effect refusal throws into the shared error path (refusals return cleanly)'
$refusalReturns = ([regex]::Matches($coreSrcForEffect, "this operation no longer owns the computer")).Count
Assert-True ($refusalReturns -ge 4) "each guarded effect reports a clean refusal (found $refusalReturns of 4)"
''
'=== 9. the cleanup-loop timeout helper (T007.10, runspace gets no module functions) ==='

# The 10-minute cleanup loop paints 'Timeout' on a row. It runs in its OWN runspace with no twins, so its
# write was a raw assignment - and the loop RELEASES the identity immediately before painting, so by then
# the row may belong to a NEW operation. The helper must therefore refuse a stale paint.
$cleanupBody = Get-InjectedScriptBlock -Source $coreSrcForEffect -VariableName 'SetCleanupTimeoutScript'
Assert-True ([bool]$cleanupBody) 'the cleanup timeout helper was located at its live injection site'
Assert-True ($cleanupBody -match 'StaleOperation') 'the cleanup helper fences on operation identity'
Assert-True ($cleanupBody -match "TimeoutSource.*JobTimeout") 'the cleanup helper records its timeout source'

$cleanupFn = [scriptblock]::Create($cleanupBody)
$cleanupStore = New-WuuStateStore
$script:stateStore = $cleanupStore

function New-CleanupRow([string]$Computer, [string]$OpId) {
    $r = New-WuuComputerRow -Computer $Computer
    $r.OpState = 'Running'; $r.OperationId = $OpId; $r.State = 'Checking'
    Add-WuuComputerRow -Store $cleanupStore -Row $r | Out-Null
    return $r
}

# The job that still owns the row may paint its timeout.
$ownRow = New-CleanupRow 'CLN-OWN' 'op-CLN'
$ownResult = & $cleanupFn -Computer $ownRow -WriterOperationId 'op-CLN'
Assert-True ($ownResult.Applied) 'the owning job paints its timeout'
Assert-Equal $ownRow.State 'Timeout' 'and the row settles to Timeout'
Assert-Equal $ownRow.TimeoutSource 'JobTimeout' 'and records the source'

# A row adopted by a NEW operation must NOT be painted by the superseded job.
$adoptedRow = New-CleanupRow 'CLN-ADOPTED' 'op-NEW'
$adoptedResult = & $cleanupFn -Computer $adoptedRow -WriterOperationId 'op-OLD'
Assert-True ($adoptedResult.Refused) 'a superseded cleanup pass is REFUSED the timeout paint'
Assert-Equal $adoptedRow.State 'Checking' 'and the NEW operation''s display is untouched'

# A settled row keeps its outcome (Complete is not converted into a timeout).
$settledRow = New-CleanupRow 'CLN-SETTLED' 'op-CLN2'
$settledRow.State = 'Complete'
$settledResult = & $cleanupFn -Computer $settledRow -WriterOperationId 'op-CLN2'
Assert-True ($settledResult.Refused) 'a Complete row is not reconverted into Timeout'
Assert-Equal $settledRow.State 'Complete' 'and keeps its terminal outcome'

# A row removed during the run is refused (the row must still be the store's row).
$goneRow = New-CleanupRow 'CLN-GONE' 'op-CLN3'
Remove-WuuComputerRow -Store $cleanupStore -Computer 'CLN-GONE' | Out-Null
$goneResult = & $cleanupFn -Computer $goneRow -WriterOperationId 'op-CLN3'
Assert-True ($goneResult.Refused) 'a removed row is refused the timeout paint'

# WIRING: the loop must pass the identity it captured BEFORE the release, not the row's current id.
Assert-True ($coreSrcForEffect -match 'timedOutOwnerId\s*=\s*if\s*\(\$runspace\.OperationId\)') 'the loop captures the owner id before releasing the identity'
''
'=== 10. the pre-dispatch queue twin (SS16 precedence, T007.9) ==='

# A payload queues a follow-up after a download ('InstallAndRecheck'). If it WRITES PendingOp directly it
# bypasses the SS16 precedence policy and can DOWNGRADE an 'AutoFlow' the operator already queued, so the
# computer would do less than was asked. The injected twin must reproduce the rank table and decline a
# downgrade. Extracted from the live injection site, as with the other helpers.
$pendingBody = Get-InjectedScriptBlock -Source $src -VariableName 'SetPendingOpScript'
Assert-True ([bool]$pendingBody) 'the queue twin was located at its live injection site'
Assert-True ($pendingBody -match 'ranks below') 'the queue twin declines a downgrade'

$pendingFn = [scriptblock]::Create($pendingBody)
$queueRow = New-WuuComputerRow -Computer 'QUEUE-1'
$queueRow.OpState = 'Running'; $queueRow.OperationId = 'op-Q'; $queueRow.State = 'Downloading'

# Operator queued AutoFlow (rank 4); the download tail tries to queue 'Download' (rank 2) -> declined.
$queueRow.PendingOp = 'AutoFlow'
$dlResult = & $pendingFn -Computer $queueRow -Op 'Download'
Assert-True ($dlResult.Refused) 'queuing Download below a queued AutoFlow is DECLINED'
Assert-Equal $queueRow.PendingOp 'AutoFlow' 'and the higher-ranked request is KEPT'

# Queuing UPWARD replaces (the operator ends up doing what they asked).
$upRow = New-WuuComputerRow -Computer 'QUEUE-2'
$upRow.OpState = 'Running'; $upRow.OperationId = 'op-Q2'; $upRow.State = 'Downloading'
$upRow.PendingOp = 'Download'
$upResult = & $pendingFn -Computer $upRow -Op 'InstallAndRecheck'
Assert-True ($upResult.Set) 'queuing InstallAndRecheck over a queued Download is accepted'
Assert-Equal $upRow.PendingOp 'InstallAndRecheck' 'and the request is upgraded'
Assert-Equal $upResult.Replaced 'Download' 'and the displaced request is REPORTED'

# A SETTLED row takes no follow-up (mirrors the module copy).
$settledQ = New-WuuComputerRow -Computer 'QUEUE-3'
$settledQ.OpState = 'Idle'; $settledQ.State = 'Complete'
$settledQResult = & $pendingFn -Computer $settledQ -Op 'Download'
Assert-True (-not $settledQResult.Set) 'a settled row takes no follow-up'
Assert-True ([string]::IsNullOrEmpty([string]$settledQ.PendingOp)) 'and nothing is queued on it'

# And the module copy agrees on the downgrade decision (the copies must not diverge).
$modQueue = New-WuuComputerRow -Computer 'QUEUE-4'
$modQueue.OpState = 'Running'; $modQueue.OperationId = 'op-Q4'; $modQueue.State = 'Downloading'
$modQueue.PendingOp = 'AutoFlow'
$modResult = Set-WuuPendingOperation -Row $modQueue -Op 'Download'
Assert-True ($modResult.Refused) 'the module policy ALSO declines the downgrade'
Assert-Equal $dlResult.Refused $modResult.Refused 'the twin and the module copy AGREE on the downgrade'

''
'=== 8. the multi-field fenced writer (T007.8) ==='

# The payloads set SEVERAL fields together (Status+State+UpdatesStatus+counters). Single-field calls
# would expose half-written rows, so the patch is applied atomically - and through an allow-list, so the
# scheduler-owned queue fields (Pending/PendingOp) and the funnel-owned identity fields cannot be reached.
$mfBody = Get-InjectedScriptBlock $src 'SetComputerFencedFieldsScript'
Assert-True ([bool]$mfBody) 'the multi-field fenced writer was located at the live injection site'
Assert-True ($mfBody -match 'not writable through the fenced writer') 'the writer enforces an allow-list'

$mfFn = [scriptblock]::Create($mfBody)
$mfStore = New-WuuStateStore
$script:stateStore = $mfStore
$global:stateStore = $mfStore   # module copy resolves the same store; keep them identical for agreement

function New-MfRow([string]$Computer, [string]$OpId = 'op-MF', [string]$RowState = 'Searching') {
    $r = New-WuuComputerRow -Computer $Computer
    $r.OpState = 'Running'; $r.OperationId = $OpId; $r.State = $RowState
    Add-WuuComputerRow -Store $mfStore -Row $r | Out-Null
    return $r
}

# A multi-field patch lands ALL fields in one accepted write.
$mfRow = New-MfRow 'MF-OK'
$WuuOperationId = 'op-MF'
$mfPatch = @{ State = 'UpdatesFound'; Status = '3 update(s) found.'; UpdatesStatus = 'Updates required'; Available = 3; Downloaded = 1 }
$mfResult = & $mfFn -Computer $mfRow -Fields $mfPatch
Assert-True ($mfResult.Applied -and -not $mfResult.Refused) 'the multi-field patch reports applied'
Assert-Equal $mfRow.State 'UpdatesFound' 'State is written'
Assert-Equal $mfRow.Status '3 update(s) found.' 'Status is written'
Assert-Equal $mfRow.UpdatesStatus 'Updates required' 'UpdatesStatus is written'
Assert-Equal $mfRow.Available 3 'a counter is written'
Assert-Equal $mfRow.Downloaded 1 'a second counter is written'

# The module copy agrees with the twin on the same patch (agreement is the property that matters).
$mfRowMod = New-MfRow 'MF-OK-MOD'
$mfModResult = Set-WuuComputerFencedFields -Row $mfRowMod -Fields $mfPatch -OperationId 'op-MF' -Store $mfStore
Assert-True ($mfModResult.Applied) 'the module copy applies the same patch'
Assert-Equal $mfRowMod.State $mfRow.State 'the twin and the module copy AGREE on the patched State'
Assert-Equal $mfRowMod.Status $mfRow.Status 'and on the patched Status'

# A superseded writer is refused, and NOTHING is written (no partial patch).
$mfStale = New-MfRow 'MF-STALE'
$WuuOperationId = 'op-OTHER'
$before = "$($mfStale.State)|$($mfStale.Available)"
$mfStaleResult = & $mfFn -Computer $mfStale -Fields @{ State = 'Complete'; Available = 99 }
Assert-True ($mfStaleResult.Refused) 'a superseded writer is refused'
Assert-Equal "$($mfStale.State)|$($mfStale.Available)" $before 'a refused patch writes NO field (no partial application)'

# The allow-list blocks scheduler-owned and identity fields, so the queue policy cannot be bypassed.
$WuuOperationId = 'op-MF'
$mfQueueRejected = $false
try { $null = & $mfFn -Computer $mfRow -Fields @{ PendingOp = 'InstallAndRecheck' } } catch { $mfQueueRejected = $true }
Assert-True $mfQueueRejected 'the writer REFUSES to set PendingOp (scheduler queue policy is not bypassable)'
$mfIdentityRejected = $false
try { $null = & $mfFn -Computer $mfRow -Fields @{ OperationId = 'op-HIJACK' } } catch { $mfIdentityRejected = $true }
Assert-True $mfIdentityRejected 'the writer REFUSES to set OperationId (identity is funnel-owned)'
# An UNKNOWN colour name is rejected too (review m-1): `Color` is bound by ui\MainWindow.xaml's
# DataTriggers, so an unrecognised name renders as NO fill with no signal. Reject the whole patch.
$mfColorRejected = $false
try { $null = & $mfFn -Computer $mfRow -Fields @{ Color = 'Chartreuse' } } catch { $mfColorRejected = $true }
Assert-True $mfColorRejected 'the writer REFUSES an unknown Color name (a bad colour would silently drop the visual cue)'
$mfColorAccepted = & $mfFn -Computer $mfRow -Fields @{ Color = 'Timeout' }
Assert-True ($mfColorAccepted.Applied) 'and it ACCEPTS a known colour name'

# A terminal row is not rewritten without a NEW attribution, exactly as the other writers enforce.
$mfSettled = New-MfRow 'MF-SETTLED' 'op-MF' 'Complete'
$WuuOperationId = 'op-MF'
$mfSettledResult = & $mfFn -Computer $mfSettled -Fields @{ State = 'Searching' }
Assert-True ($mfSettledResult.Refused) 'a settled row is not rewritten by a bare patch'
Assert-Equal $mfSettled.State 'Complete' 'and the settled display is unchanged'

''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
