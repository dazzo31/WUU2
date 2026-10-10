#Requires -Version 5.1
<#
.SYNOPSIS Regression test: the Auto Download/Install follow-up chain.
.DESCRIPTION Verifies the fix for "auto download/install does nothing":
  - Start-PendingUpdateCheck consumes an item's PendingOp and starts exactly ONE job.
  - Start-UpdateCheckJob -Op composes the right op chain in ONE pipeline. Payload stubs
    append a marker to a shared file (worker runspaces can write files but cannot see the
    test's in-memory variables), proving WHICH AddScript calls executed and their order:
        Check            -> GET
        Download         -> DOWNLOAD:Download
        InstallAndRecheck-> INSTALL, RESTART, GET
        AutoFlow         -> DOWNLOAD:AutoFlow, INSTALL, RESTART, GET
  Production payloads update the GUI via the UI-thread dispatcher (not the pipeline stream),
  so a file ledger is the faithful signal here; pipeline stdout only carries the last
  script's return value and cannot prove execution.
  Uses a REAL worker runspace (New-ComputerRunspace), exactly as production composes it.
Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-AutoFlowChain.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

Import-Module (Join-Path $root 'src\Wuu.Core.psm1') -Force
Import-WuuModules -WuuRoot $root

# Shared marker file the worker-runspace payload stubs append to.
$markerFile = Join-Path $env:TEMP ("WUU_autoflow_markers_{0}.log" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType File -Path $markerFile -Force | Out-Null

# --- Stub UI state (no-op dispatcher so dispatcher actions run inline) ------------------
$global:uiHash = [hashtable]::Synchronized(@{})
$fakeItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$noOpDispatcher = New-Object PSObject
$null = Add-Member -InputObject $noOpDispatcher -MemberType ScriptMethod -Name Invoke -Value { param($priority, $action) & $action } -Force
$global:uiHash.ListView = [pscustomobject]@{ Items = $fakeItems; Dispatcher = $noOpDispatcher }
$global:uiHash.AutoInstallCheckBox = [pscustomobject]@{ IsChecked = $true }
$global:uiHash.AutoRebootCheckBox  = [pscustomobject]@{ IsChecked = $false }

$global:jobs = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
# The engine store the SCHEDULER reads (Start-PendingUpdateCheck no longer walks the ListView). The
# scheduler and Start-UpdateCheckJob resolve it from the context; the FUNNEL still resolves
# $global:stateStore, which is deliberately left unset here so the admission cases that use
# hand-built rows keep working.
$schedStore = New-WuuStateStore
$global:backgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })
$global:MaxConcurrentJobs = 10
$global:LogPath = Join-Path $env:TEMP 'WUU_test_autoflow.log'
$global:LogLock = New-Object Object
$global:EnableDebugLogging = $false
$global:searchTimeout = 5
$global:sessionTimeout = 5
$global:rebootCheckTimeout = 5
$global:updatesHash = [hashtable]::Synchronized(@{})
$global:performanceHash = [hashtable]::Synchronized(@{})
$global:errorSuggestionsHash = New-WuuErrorSuggestions
$global:ConfigPaths = @{ DownloadScript = 'unused'; InstallScript = 'unused' }
$global:UseCustomCredentials = $false
$global:CustomCredentials = $null
$global:CredentialCache = @{}
$global:PerformanceThreshold = @{ CPUPercent = 80; MemoryMB = 1024; NetworkLatencyMs = 1000 }
$global:EnableEnhancedErrorHandling = $false

# --- Recording payload stubs: append "NAME:arg" to the marker file --------------------
# (path is literal inside the scriptblock text so the worker runspace needs no injection;
#  payloads that take an arg emit it after a colon, others emit just the name)
$mkA = { param($name) [scriptblock]::Create(("param(`$ComputerItem, `$Op) Add-Content -Path '{0}' -Value ('{1}:' + `$Op)" -f $markerFile, $name)) }
$mkN = { param($name) [scriptblock]::Create(("param(`$ComputerItem, `$Op) Add-Content -Path '{0}' -Value '{1}'" -f $markerFile, $name)) }
$payloadGet      = $mkN.Invoke('GET')      | Select-Object -First 1
$payloadDownload = $mkA.Invoke('DOWNLOAD') | Select-Object -First 1
$payloadInstall  = $mkN.Invoke('INSTALL')  | Select-Object -First 1
$payloadRestart  = $mkA.Invoke('RESTART')  | Select-Object -First 1

Initialize-WuuWindowsUpdateContext -Context @{
    UiHash                      = $global:uiHash
    Jobs                        = $global:jobs
    StateStore                  = $schedStore
    UpdatesHash                 = $global:updatesHash
    PerformanceHash             = $global:performanceHash
    ErrorSuggestions            = $global:errorSuggestionsHash
    Path                        = $PWD.Path
    LogPath                     = $global:LogPath
    LogLock                     = $global:LogLock
    EnableDebugLogging          = $false
    EnableEnhancedErrorHandling = $false
    UseCustomCredentials        = $false
    CustomCredentials           = $null
    CredentialCache             = $global:CredentialCache
    PerformanceThreshold        = $global:PerformanceThreshold
    ConfigPaths                 = $global:ConfigPaths
    SearchTimeout               = $global:searchTimeout
    SessionTimeout              = $global:sessionTimeout
    RebootCheckTimeout          = $global:rebootCheckTimeout
    MaxConcurrentJobs           = $global:MaxConcurrentJobs
    GetUpdates                  = $payloadGet
    DownloadUpdates             = $payloadDownload
    InstallUpdates              = $payloadInstall
    RestartComputer             = $payloadRestart
    BackgroundProcessing        = $global:backgroundProcessing
    CredDialogXamlPath          = Join-Path $root 'ui\CredentialDialog.xaml'
}

$fail = $false

function Invoke-OpChain {
    param([string]$PendingOp, [string[]]$Expected)
    # Fresh marker file per op so ordering is unambiguous
    Set-Content -Path $markerFile -Value $null

    $item = New-Object PSObject -Property @{
        Computer = 'localhost'; Phase = 'Phase 1'; Pending = $true
        PendingOp = $PendingOp; Runspace = $null; Status = 'test'
    }
    # REGISTERED IN THE ENGINE STORE (T006.1): the scheduler sources its queue from the store, not the
    # ListView, so the item must be the authoritative store row for the drain to find it.
    Set-WuuRowEngineDefaults -Row $item | Out-Null
    Add-WuuComputerRow -Store $schedStore -Row $item | Out-Null
    Start-PendingUpdateCheck

    if ($global:jobs.Count -ne 1) {
        Write-Host ("FAIL [{0}]: expected exactly 1 job, got {1}" -f $PendingOp, $global:jobs.Count) -ForegroundColor Red
        $script:fail = $true; return
    }
    $job = $global:jobs[0]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $job.Runspace.IsCompleted -and $sw.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 100 }
    try { $job.PowerShell.EndInvoke($job.Runspace) | Out-Null } catch { Write-Host ("FAIL [{0}]: EndInvoke threw: {1}" -f $PendingOp, $_.Exception.Message) -ForegroundColor Red; $script:fail = $true }

    $global:jobs.Remove($job)
    try { $job.PowerShell.Dispose() } catch { $null = $_ }
    if ($item.Runspace) { try { $item.Runspace.Close(); $item.Runspace.Dispose() } catch { $null = $_ } }
    try { Remove-WuuComputerRow -Store $schedStore -Computer $item.Computer } catch { }

    $got = @((Get-Content $markerFile) | Where-Object { $_ })
    $match = ($got.Count -eq $Expected.Count)
    if ($match) { for ($i = 0; $i -lt $Expected.Count; $i++) { if ($got[$i] -ne $Expected[$i]) { $match = $false } } }
    if ($match) {
        Write-Host ("PASS [{0}]: chain executed -> {1}; PendingOp cleared={2}; Pending={3}" -f $PendingOp, ($got -join ' | '), $item.PendingOp, $item.Pending) -ForegroundColor Green
    } else {
        Write-Host ("FAIL [{0}]: expected [{1}] got [{2}]" -f $PendingOp, ($Expected -join ', '), ($got -join ', ')) -ForegroundColor Red
        $script:fail = $true
    }
}

Invoke-OpChain $null                  @('GET')
Invoke-OpChain 'Download'             @('DOWNLOAD:Download')
Invoke-OpChain 'InstallAndRecheck'    @('INSTALL', 'RESTART:True', 'GET')
Invoke-OpChain 'AutoFlow'             @('DOWNLOAD:AutoFlow', 'INSTALL', 'RESTART:True', 'GET')

# --- Section 2: admission must precede the start (T011.1 / remediation G3) --------------
#
# MEASURED DEFECT THIS SECTION GUARDS: Start-UpdateCheckJob used to call BeginInvoke BEFORE the row
# claim, and a refused claim was only logged ("the job still runs"). A submission against an already
# busy computer therefore STARTED a second payload on the same runspace whose work the engine
# discards, while its writes carried no identity and were consequently permitted by the fence.
#
# The proof is a MARKER FILE, not an assertion on a return value: a payload stub that never runs
# writes nothing, so "no marker lines" is evidence that no work started. A return value alone would
# not distinguish "refused" from "accepted but silently discarded".

function New-AdmissionItem {
    param([string]$Computer, [string]$State = 'Queued', [string]$OperationId = '', [string]$OpState = 'Idle')
    $item = New-Object PSObject -Property @{
        Computer = $Computer; Phase = 'Phase 1'; Pending = $false; PendingOp = $null
        Runspace = $null; Status = 'test'; State = $State
        OperationId = $OperationId; OpState = $OpState
    }
    Set-WuuRowEngineDefaults -Row $item | Out-Null
    # Set-WuuRowEngineDefaults only ADDS missing fields; an explicitly passed identity must be
    # re-stamped because the backfill never overwrites an existing value.
    $item.OperationId = $OperationId
    $item.OpState = $OpState
    $item.State = $State
    return $item
}

# 2a. A BUSY computer is refused, and the refusal starts no payload.
Set-Content -Path $markerFile -Value $null
$busyItem = New-AdmissionItem -Computer 'admit-busy' -State 'Searching' -OperationId 'op-live' -OpState 'Running'
$jobsBeforeBusy = $global:jobs.Count
$busyAccepted = Start-UpdateCheckJob -ComputerItem $busyItem
Start-Sleep -Milliseconds 400
$busyMarkers = @((Get-Content $markerFile) | Where-Object { $_ })
if ($busyAccepted -ne $false) {
    Write-Host ("FAIL [busy]: a submission on a busy computer reported success ({0})" -f $busyAccepted) -ForegroundColor Red
    $script:fail = $true
} elseif ($busyMarkers.Count -ne 0) {
    Write-Host ("FAIL [busy]: a refused submission STARTED payload work: {0}" -f ($busyMarkers -join ', ')) -ForegroundColor Red
    $script:fail = $true
} elseif ($global:jobs.Count -ne $jobsBeforeBusy) {
    Write-Host ('FAIL [busy]: a refused submission consumed a job slot') -ForegroundColor Red
    $script:fail = $true
} elseif ($busyItem.OperationId -ne 'op-live' -or $busyItem.OpState -ne 'Running') {
    Write-Host ('FAIL [busy]: a refused submission changed the live owner') -ForegroundColor Red
    $script:fail = $true
} else {
    Write-Host 'PASS [busy]: refused before starting any payload; live owner untouched' -ForegroundColor Green
}

# 2a-ii. THE OPERATOR'S DOUBLE-CLICK REPRO. Measured in the field: the operator clicked Check for
# Updates while a check was STILL RUNNING, and got "update status is at error". Cause: the runspace was
# created and SessionStateProxy.SetVariable('WuuOperationId') was attempted BEFORE the admission check,
# and SetVariable on a BUSY runspace throws "A pipeline is already running. Concurrent SessionStateProxy
# method calls are not allowed." - which the catch reported as "Runspace creation failed", painting the
# row Error. A second submission on a busy row must be refused CLEANLY: no error log, no Error state, and
# crucially the RUNNING operation's progress text must survive.
Set-Content -Path $markerFile -Value $null
$doubleClickItem = New-AdmissionItem -Computer 'admit-doubleclick' -State 'Searching' -OperationId 'op-running' -OpState 'Running'
$doubleClickItem.Runspace = New-ComputerRunspace -ComputerItem $doubleClickItem   # a REAL, idle runspace
$doubleClickItem.Status = 'Checking for updates...'                                # the running op's progress
if (-not $doubleClickItem.PSObject.Properties['UpdatesStatus']) {
    $doubleClickItem | Add-Member -MemberType NoteProperty -Name UpdatesStatus -Value 'Initializing' -Force
} else { $doubleClickItem.UpdatesStatus = 'Initializing' }
$doubleClickAccepted = Start-UpdateCheckJob -ComputerItem $doubleClickItem
$doubleClickMarkers = @((Get-Content $markerFile) | Where-Object { $_ })
$doubleClickOk = $true
if ($doubleClickAccepted -ne $false) {
    Write-Host ("FAIL [doubleclick]: a second Check on a busy row reported success ({0})" -f $doubleClickAccepted) -ForegroundColor Red
    $doubleClickOk = $false
}
if ($doubleClickItem.State -eq 'Error' -or $doubleClickItem.UpdatesStatus -eq 'Error') {
    Write-Host ('FAIL [doubleclick]: the refused second Check painted the row Error (the field symptom)') -ForegroundColor Red
    $doubleClickOk = $false
}
if ($doubleClickItem.Status -ne 'Checking for updates...') {
    Write-Host ("FAIL [doubleclick]: the running operation's progress was overwritten (Status='{0}')" -f $doubleClickItem.Status) -ForegroundColor Red
    $doubleClickOk = $false
}
if ($doubleClickItem.OperationId -ne 'op-running' -or $doubleClickItem.OpState -ne 'Running') {
    Write-Host ('FAIL [doubleclick]: the refused second Check disturbed the running owner') -ForegroundColor Red
    $doubleClickOk = $false
}
if ($doubleClickMarkers.Count -ne 0) {
    Write-Host ('FAIL [doubleclick]: the refused second Check started payload work') -ForegroundColor Red
    $doubleClickOk = $false
}
if ($doubleClickOk) {
    Write-Host 'PASS [doubleclick]: a second Check while one is RUNNING is refused cleanly (no Error, progress preserved)' -ForegroundColor Green
}
if ($doubleClickItem.Runspace) { try { $doubleClickItem.Runspace.Close(); $doubleClickItem.Runspace.Dispose() } catch { $null = $_ } }

# 2b. A FULL CAP is refused, and the refusal starts no payload.
Set-Content -Path $markerFile -Value $null
$capContext = @{ MaxConcurrentJobs = 1 }
Initialize-WuuWindowsUpdateContext -Context @{
    UiHash                      = $global:uiHash
    Jobs                        = $global:jobs
    StateStore                  = $schedStore
    UpdatesHash                 = $global:updatesHash
    PerformanceHash             = $global:performanceHash
    ErrorSuggestions            = $global:errorSuggestionsHash
    Path                        = $PWD.Path
    LogPath                     = $global:LogPath
    LogLock                     = $global:LogLock
    EnableDebugLogging          = $false
    EnableEnhancedErrorHandling = $false
    UseCustomCredentials        = $false
    CustomCredentials           = $null
    CredentialCache             = $global:CredentialCache
    PerformanceThreshold        = $global:PerformanceThreshold
    ConfigPaths                 = $global:ConfigPaths
    SearchTimeout               = $global:searchTimeout
    SessionTimeout              = $global:sessionTimeout
    RebootCheckTimeout          = $global:rebootCheckTimeout
    MaxConcurrentJobs           = $capContext.MaxConcurrentJobs
    GetUpdates                  = $payloadGet
    DownloadUpdates             = $payloadDownload
    InstallUpdates             = $payloadInstall
    RestartComputer            = $payloadRestart
    BackgroundProcessing        = $global:backgroundProcessing
    CredDialogXamlPath          = Join-Path $root 'ui\CredentialDialog.xaml'
}
# Occupy the single slot with a placeholder entry. The cap counts $jobs entries, so this makes
# "cap reached" true without starting any real work.
$placeholder = New-Object PSObject -Property @{ PowerShell = $null; Runspace = $null; StartTime = Get-Date; Computer = 'cap-placeholder'; OperationId = 'op-placeholder' }
$global:jobs.Add($placeholder) | Out-Null
$capItem = New-AdmissionItem -Computer 'admit-cap'
$capAccepted = Start-UpdateCheckJob -ComputerItem $capItem
Start-Sleep -Milliseconds 400
$capMarkers = @((Get-Content $markerFile) | Where-Object { $_ })
if ($capAccepted -ne $false) {
    Write-Host ("FAIL [cap]: a submission at the cap reported success ({0})" -f $capAccepted) -ForegroundColor Red
    $script:fail = $true
} elseif ($capMarkers.Count -ne 0) {
    Write-Host ("FAIL [cap]: a cap-refused submission STARTED payload work: {0}" -f ($capMarkers -join ', ')) -ForegroundColor Red
    $script:fail = $true
} elseif ($global:jobs.Count -ne 1) {
    Write-Host ('FAIL [cap]: a cap-refused submission added a job entry') -ForegroundColor Red
    $script:fail = $true
} elseif ($capItem.OpState -eq 'Running') {
    Write-Host ('FAIL [cap]: a cap-refused submission left the row claimed Running') -ForegroundColor Red
    $script:fail = $true
} else {
    Write-Host 'PASS [cap]: refused at the cap before starting any payload; row left unclaimed' -ForegroundColor Green
}

$global:jobs.Remove($placeholder) | Out-Null
foreach ($leftover in @($busyItem, $capItem)) {
    if ($leftover.Runspace) { try { $leftover.Runspace.Close(); $leftover.Runspace.Dispose() } catch { $null = $_ } }
}

# 2c. A QUEUED FOLLOW-UP blocks a direct submission. This case is discriminating on purpose: the
#     row is NOT claimed (OpState='Idle', no OperationId), so the identity funnel alone would ACCEPT
#     the claim and start the payload. Only the admission gate consults Pending, so this is the case
#     that would start work if the gate were removed - which is exactly why it is here. Per
#     Test-WuuComputerBusy, a queued follow-up must block a direct submission or the direct one wins
#     the runspace and the queued one is silently discarded.
Initialize-WuuWindowsUpdateContext -Context @{
    UiHash                      = $global:uiHash
    Jobs                        = $global:jobs
    StateStore                  = $schedStore
    UpdatesHash                 = $global:updatesHash
    PerformanceHash             = $global:performanceHash
    ErrorSuggestions            = $global:errorSuggestionsHash
    Path                        = $PWD.Path
    LogPath                     = $global:LogPath
    LogLock                     = $global:LogLock
    EnableDebugLogging          = $false
    EnableEnhancedErrorHandling = $false
    UseCustomCredentials        = $false
    CustomCredentials           = $null
    CredentialCache             = $global:CredentialCache
    PerformanceThreshold        = $global:PerformanceThreshold
    ConfigPaths                 = $global:ConfigPaths
    SearchTimeout               = $global:searchTimeout
    SessionTimeout              = $global:sessionTimeout
    RebootCheckTimeout          = $global:rebootCheckTimeout
    MaxConcurrentJobs           = $global:MaxConcurrentJobs
    GetUpdates                  = $payloadGet
    DownloadUpdates             = $payloadDownload
    InstallUpdates             = $payloadInstall
    RestartComputer            = $payloadRestart
    BackgroundProcessing        = $global:backgroundProcessing
    CredDialogXamlPath          = Join-Path $root 'ui\CredentialDialog.xaml'
}
Set-Content -Path $markerFile -Value $null
$pendingItem = New-AdmissionItem -Computer 'admit-pending'
$pendingItem.Pending = $true
$pendingItem.PendingOp = 'Download'
$pendingAccepted = Start-UpdateCheckJob -ComputerItem $pendingItem
Start-Sleep -Milliseconds 400
$pendingMarkers = @((Get-Content $markerFile) | Where-Object { $_ })
if ($pendingAccepted -ne $false) {
    Write-Host ("FAIL [pending]: a submission with a queued follow-up reported success ({0})" -f $pendingAccepted) -ForegroundColor Red
    $script:fail = $true
} elseif ($pendingMarkers.Count -ne 0) {
    Write-Host ("FAIL [pending]: a submission with a queued follow-up STARTED payload work: {0}" -f ($pendingMarkers -join ', ')) -ForegroundColor Red
    $script:fail = $true
} elseif ($pendingItem.OpState -eq 'Running') {
    Write-Host ('FAIL [pending]: the row was claimed Running, so the queued follow-up will be discarded') -ForegroundColor Red
    $script:fail = $true
} else {
    Write-Host 'PASS [pending]: a queued follow-up blocks a direct submission before any payload starts' -ForegroundColor Green
}
if ($pendingItem.Runspace) { try { $pendingItem.Runspace.Close(); $pendingItem.Runspace.Dispose() } catch { $null = $_ } }

# 2d. Prove WHICH half of the admission gate does the blocking, without mutating production code.
#     -IgnorePending is the scheduler's view; the scheduler OWNS the Pending flag and consumes it, so
#     for it the row is admissible. A direct submission must see the OTHER answer, or a queued
#     follow-up would be silently discarded when the direct operation won the runspace.
$pendingGateFull = Test-WuuComputerBusy -Row $pendingItem
$pendingGateIgnore = Test-WuuComputerBusy -Row $pendingItem -IgnorePending
if ($pendingGateFull -and -not $pendingGateIgnore) {
    Write-Host 'PASS [gate]: the queued follow-up alone makes a direct submission busy (Pending half of the gate)' -ForegroundColor Green
} else {
    Write-Host ("FAIL [gate]: expected busy without -IgnorePending and not-busy with it (got {0} / {1})" -f $pendingGateFull, $pendingGateIgnore) -ForegroundColor Red
    $script:fail = $true
}

# 2e. THE GATE IS LOAD-BEARING WHEN THE FUNNEL WOULD ACCEPT. A row that is OpState='Running' with an
#     EMPTY OperationId is refused by the busy gate, but the funnel would ACCEPT and overwrite it -
#     its adoption rule only refuses when the row names a DIFFERENT non-empty owner. So this is the
#     case that fails if the busy gate is removed, unlike 2a where the funnel also refuses. It is the
#     "runspace is busy but the identity is missing" state a crashed/partially-cleared row can reach.
Set-Content -Path $markerFile -Value $null
$emptyIdBusyItem = New-AdmissionItem -Computer 'admit-emptyid' -State 'Searching' -OperationId '' -OpState 'Running'
$emptyIdAccepted = Start-UpdateCheckJob -ComputerItem $emptyIdBusyItem
Start-Sleep -Milliseconds 400
$emptyIdMarkers = @((Get-Content $markerFile) | Where-Object { $_ })
if ($emptyIdAccepted -ne $false) {
    Write-Host ("FAIL [emptyid]: a Running-but-unattributed row accepted a submission ({0})" -f $emptyIdAccepted) -ForegroundColor Red
    $script:fail = $true
} elseif ($emptyIdMarkers.Count -ne 0) {
    Write-Host ("FAIL [emptyid]: payload work started on a busy unattributed row: {0}" -f ($emptyIdMarkers -join ', ')) -ForegroundColor Red
    $script:fail = $true
} elseif ($emptyIdBusyItem.OperationId -ne '' -or $emptyIdBusyItem.OpState -ne 'Running') {
    Write-Host ('FAIL [emptyid]: a refused submission claimed/overwrote a busy unattributed row') -ForegroundColor Red
    $script:fail = $true
} else {
    Write-Host 'PASS [emptyid]: busy gate refuses where the funnel alone would accept, so no payload starts' -ForegroundColor Green
}
if ($emptyIdBusyItem.Runspace) { try { $emptyIdBusyItem.Runspace.Close(); $emptyIdBusyItem.Runspace.Dispose() } catch { $null = $_ } }

# 2f. THE SCHEDULER RE-ARMS A REFUSED QUEUED REQUEST. Start-PendingUpdateCheck clears Pending and
#     consumes PendingOp BEFORE submitting; if admission refuses, the request must go back or it is
#     LOST (the measured auto-install-tail strand). The busy unattributed row above is reused as the
#     target so the refusal is deterministic.
Set-Content -Path $markerFile -Value $null
$rearmItem = New-Object PSObject -Property @{
    Computer = 'admit-rearm-busy'; Phase = 'Phase 1'; Pending = $true; PendingOp = 'InstallAndRecheck'
    Runspace = $null; Status = 'test'; State = 'Searching'
    OperationId = ''; OpState = 'Running'
}
Set-WuuRowEngineDefaults -Row $rearmItem | Out-Null
$rearmItem.Pending = $true; $rearmItem.PendingOp = 'InstallAndRecheck'
$rearmItem.OperationId = ''; $rearmItem.OpState = 'Running'; $rearmItem.State = 'Searching'
# Registered in the engine store so the scheduler (which reads the store) finds this queued request.
Add-WuuComputerRow -Store $schedStore -Row $rearmItem | Out-Null
$jobsBeforeRearm = $global:jobs.Count
Start-PendingUpdateCheck
Start-Sleep -Milliseconds 300
$rearmMarkers = @((Get-Content $markerFile) | Where-Object { $_ })
if (-not $rearmItem.Pending) {
    Write-Host 'FAIL [rearm]: a refused queued request was NOT re-armed (Pending stayed false)' -ForegroundColor Red
    $script:fail = $true
} elseif ($rearmItem.PendingOp -ne 'InstallAndRecheck') {
    Write-Host ("FAIL [rearm]: the queued follow-up op was lost (got '{0}')" -f $rearmItem.PendingOp) -ForegroundColor Red
    $script:fail = $true
} elseif ($rearmMarkers.Count -ne 0) {
    Write-Host ('FAIL [rearm]: a refused queued request started payload work') -ForegroundColor Red
    $script:fail = $true
} elseif ($global:jobs.Count -ne $jobsBeforeRearm) {
    Write-Host ('FAIL [rearm]: a refused queued request consumed a job slot') -ForegroundColor Red
    $script:fail = $true
} else {
    Write-Host 'PASS [rearm]: the scheduler re-arms a refused queued request instead of losing it' -ForegroundColor Green
}
try { Remove-WuuComputerRow -Store $schedStore -Computer $rearmItem.Computer } catch { }

# 2g. THE REFUSAL IS RECORDED (visible stall) AND CLEARED ON ADMISSION. A row refused every tick must
#     be distinguishable from one waiting its turn.
$refusalRow = New-AdmissionItem -Computer 'admit-refusal-record'
$recordAfterRefuse = Update-WuuRefusalRecord -Row $refusalRow -Reason 'test refusal'
$stalledAfterRefuse = Test-WuuRefusalStalled -Row $refusalRow
# CAPTURE BEFORE CLEARING: -Admitted resets RefusedCount, so reading the row afterwards asserts the
# wrong thing (a cleared record looks like a record that was never written).
$refusedCountRecorded = $refusalRow.RefusedCount
$refusedReasonRecorded = $refusalRow.RefusedReason
$null = Update-WuuRefusalRecord -Row $refusalRow -Admitted
# NOTE: read the recorded COUNT off the row, not off the returned hashtable. A hashtable's .Count is
# the number of ENTRIES (4: Count/Reason/At/Stalled), so $record.Count -eq 1 would never be true - the
# exact collision that makes a returned record look wrong when the recorder is fine.
if ($refusedCountRecorded -ne 1 -or $recordAfterRefuse['Count'] -ne 1) {
    Write-Host 'FAIL [refusalrecord]: a refusal was not recorded on the row' -ForegroundColor Red
    $script:fail = $true
} elseif ($stalledAfterRefuse.Threshold -ne (Get-WuuRefusalStallThreshold)) {
    Write-Host 'FAIL [refusalrecord]: the stalled predicate and the recorder disagree on the threshold' -ForegroundColor Red
    $script:fail = $true
} elseif ($refusalRow.RefusedCount -ne 0 -or $refusalRow.RefusedReason -ne '') {
    Write-Host 'FAIL [refusalrecord]: admission did not clear the consecutive-refusal record' -ForegroundColor Red
    $script:fail = $true
} else {
    Write-Host ('PASS [refusalrecord]: refusal recorded (count={0}, reason set) then cleared on admission' -f $refusedCountRecorded) -ForegroundColor Green
}

foreach ($extra in @($emptyIdBusyItem)) {
    if ($extra.Runspace) { try { $extra.Runspace.Close(); $extra.Runspace.Dispose() } catch { $null = $_ } }
}

# 2h. LIFECYCLE OPS GO THROUGH THE SAME ADMITTED PATH. Restart / RemoveOffline / ServiceAction are
#     not built-in update chains, so they are driven with -Payload. This proves the payload really
#     runs, is claimed under its own op name, and that a payload-less lifecycle op is refused (which
#     would otherwise silently run a plain Check under that op's deadline).
Set-Content -Path $markerFile -Value $null
$lifecycleItem = New-AdmissionItem -Computer 'admit-lifecycle'
$lifecycleAccepted = Start-UpdateCheckJob -ComputerItem $lifecycleItem -Op 'Restart' -Payload @(
    @{ Script = $payloadGet; Arguments = @($lifecycleItem) })
# Wait on the JOB's async handle, not on the Runspace object - a Runspace has no IsCompleted property,
# so waiting on it silently spins the whole timeout on every run.
$lifecycleJob = @($global:jobs | Where-Object { $_.Computer -eq 'admit-lifecycle' })[0]
$swLife = [Diagnostics.Stopwatch]::StartNew()
while ($lifecycleJob -and -not $lifecycleJob.Runspace.IsCompleted -and $swLife.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 50 }
if ($lifecycleJob) { try { $lifecycleJob.PowerShell.EndInvoke($lifecycleJob.Runspace) | Out-Null } catch { } }
$lifecycleMarkers = @((Get-Content $markerFile) | Where-Object { $_ })
if (-not $lifecycleAccepted) {
    Write-Host 'FAIL [lifecycle]: an explicit-payload lifecycle submission was refused' -ForegroundColor Red
    $script:fail = $true
} elseif ($lifecycleMarkers -join ',' -ne 'GET') {
    Write-Host ("FAIL [lifecycle]: explicit payload did not run (got '{0}')" -f ($lifecycleMarkers -join ',')) -ForegroundColor Red
    $script:fail = $true
} elseif ($lifecycleJob.OperationId -ne $lifecycleItem.OperationId -or $lifecycleItem.OperationId -eq '') {
    Write-Host 'FAIL [lifecycle]: the admitted job did not carry the row''s operation identity' -ForegroundColor Red
    $script:fail = $true
} else {
    Write-Host 'PASS [lifecycle]: an explicit-payload lifecycle op is admitted, claimed and executed' -ForegroundColor Green
}
if ($lifecycleJob) { $global:jobs.Remove($lifecycleJob) | Out-Null; try { $lifecycleJob.PowerShell.Dispose() } catch { } }
if ($lifecycleItem.Runspace) { try { $lifecycleItem.Runspace.Close(); $lifecycleItem.Runspace.Dispose() } catch { $null = $_ } }

$payloadlessItem = New-AdmissionItem -Computer 'admit-nopayload'
$payloadlessResult = Start-UpdateCheckJob -ComputerItem $payloadlessItem -Op 'ServiceAction'
# The guard must REFUSE (return $false) without painting the row as a failed operation. A throw here
# would be caught by the runspace-failure handler, which sets Status='Failed to initialize...' and
# UpdatesStatus='Error' - the exact corruption this assertion rules out.
if ($payloadlessResult -eq $false -and $payloadlessItem.UpdatesStatus -ne 'Error' -and $payloadlessItem.State -ne 'Error') {
    Write-Host 'PASS [lifecycle]: a payload-less lifecycle op is refused without corrupting the row' -ForegroundColor Green
} else {
    Write-Host ("FAIL [lifecycle]: payload-less lifecycle op result={0} UpdatesStatus={1} State={2}" -f $payloadlessResult, $payloadlessItem.UpdatesStatus, $payloadlessItem.State) -ForegroundColor Red
    $script:fail = $true
}

# 2i. STRUCTURAL GUARD: every engine submission must go through Start-UpdateCheckJob. Core must not
#     append a job entry itself. (A reintroduced `$jobs.Add` is how the six handlers used to bypass
#     ownership, and it would be invisible to the behavioural cases above because it needs the UI.)
$coreText = [System.IO.File]::ReadAllText((Join-Path $root 'src\Wuu.Core.psm1'))
# Case-insensitive and whitespace-tolerant: a reintroduced `$Jobs.Add(` or `$jobs . Add(` must still
# be caught. (A determined alias like `$j = $jobs; $j.Add(...)` evades any text guard - that is why the
# behavioural cases above exist too - but the common silent revert is a literal append.)
$directJobAdds = ([regex]::Matches($coreText, '(?i)\$jobs\s*\.\s*Add\s*\(')).Count
# The six converted handlers route under these op names: the reuse/check path, download, install,
# remove-offline, restart and the service action. Assert each is present so a silent revert of any
# ONE handler back to a private BeginInvoke is caught, not just a total count.
$routedOps = @('Check', 'Download', 'InstallAndRecheck', 'RemoveOffline', 'Restart', 'ServiceAction')
$missingOps = @($routedOps | Where-Object {
    -not ($coreText -match ("Start-UpdateCheckJob -ComputerItem [^\r\n]*-Op '" + $_ + "'"))
})
if ($directJobAdds -ne 0) {
    Write-Host ("FAIL [guard]: Core still appends a job entry directly ({0} site(s)) - a submission bypasses admission" -f $directJobAdds) -ForegroundColor Red
    $script:fail = $true
} elseif ($missingOps.Count -gt 0) {
    Write-Host ("FAIL [guard]: handler(s) not routing through admission: {0}" -f ($missingOps -join ', ')) -ForegroundColor Red
    $script:fail = $true
} else {
    Write-Host 'PASS [guard]: no direct job append in Core; all six handlers route through admission' -ForegroundColor Green
}

Remove-Item $markerFile -Force -ErrorAction SilentlyContinue

if ($fail) { Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS' -ForegroundColor Cyan }
