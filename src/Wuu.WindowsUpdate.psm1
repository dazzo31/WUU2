#Requires -Version 5.1
<#
.DESCRIPTION
Per-computer worker runspaces, job scheduling, phase gating, and update payloads.
#>

function Initialize-WuuWindowsUpdateContext {
    # Shared app state (entry point owns it; modules must not rely on caller scope).
    # Expected keys: UiHash, Jobs, UpdatesHash, PerformanceHash, ErrorSuggestions,
    # Path, LogPath, LogLock, EnableDebugLogging, EnableEnhancedErrorHandling,
    # UseCustomCredentials, CustomCredentials, CredentialCache, PerformanceThreshold,
    # ConfigPaths, SearchTimeout, SessionTimeout, RebootCheckTimeout, MaxConcurrentJobs,
    # GetUpdates, DownloadUpdates, InstallUpdates, RestartComputer,
    # BackgroundProcessing, CredDialogXamlPath
    param([Parameter(Mandatory)][hashtable]$Context)
    $script:WuuCtx = $Context
}

function New-ComputerRunspace {
    param($ComputerItem)
    $ctx = $script:WuuCtx
    $uiHash = $ctx.UiHash; $updatesHash = $ctx.UpdatesHash; $performanceHash = $ctx.PerformanceHash
    $errorSuggestionsHash = $ctx.ErrorSuggestions; $path = $ctx.Path
    $PerformanceThreshold = $ctx.PerformanceThreshold
    $searchTimeout = $ctx.SearchTimeout; $sessionTimeout = $ctx.SessionTimeout
    $rebootCheckTimeout = $ctx.RebootCheckTimeout
        Write-InfoLog "Creating runspace for computer: $($ComputerItem.Computer)"
            # Create runspace with proper scope isolation to prevent "Global scope cannot be removed" error
            $runspaceConfig = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            $runspaceConfig.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
            $newRunspace = [runspacefactory]::CreateRunspace($runspaceConfig)
            $newRunspace.ApartmentState = "STA"
            $newRunspace.Open()
            Write-InfoLog "Runspace opened successfully for: $($ComputerItem.Computer)"
        $newRunspace.SessionStateProxy.SetVariable("uiHash",$uiHash)
        # The engine store (T006/T007 step A). Injected so the worker twin can resolve rows from the
        # store instead of from the ListView, and so the identity fence has something to compare
        # against. Until the twin is ported (step C) nothing in the payload reads it, which is
        # deliberate: this step must not change behaviour.
        $newRunspace.SessionStateProxy.SetVariable("stateStore",$ctx.StateStore)
        $newRunspace.SessionStateProxy.SetVariable("updatesHash",$updatesHash)
        $newRunspace.SessionStateProxy.SetVariable("performanceHash",$performanceHash)
        $newRunspace.SessionStateProxy.SetVariable("errorSuggestionsHash",$errorSuggestionsHash)
        $newRunspace.SessionStateProxy.SetVariable("path",$pwd)
        $newRunspace.SessionStateProxy.SetVariable("LogPath",$ctx.LogPath)
        $newRunspace.SessionStateProxy.SetVariable("LogLock",$ctx.LogLock)
        $newRunspace.SessionStateProxy.SetVariable("EnableDebugLogging",$ctx.EnableDebugLogging)
        $newRunspace.SessionStateProxy.SetVariable("EnableEnhancedErrorHandling",$ctx.EnableEnhancedErrorHandling)
        # Read runtime-reassignable credential state at creation time (config dialog
        # reassigns the $global: variables; the startup context snapshot would be stale).
        $newRunspace.SessionStateProxy.SetVariable("UseCustomCredentials",$global:UseCustomCredentials)
        $newRunspace.SessionStateProxy.SetVariable("CustomCredentials",$global:CustomCredentials)
        $newRunspace.SessionStateProxy.SetVariable("CredentialCache",$global:CredentialCache)
        $newRunspace.SessionStateProxy.SetVariable("PerformanceThreshold",$PerformanceThreshold)
        $newRunspace.SessionStateProxy.SetVariable("ConfigPaths",$ctx.ConfigPaths)
        $newRunspace.SessionStateProxy.SetVariable("searchTimeout",$searchTimeout)
        $newRunspace.SessionStateProxy.SetVariable("sessionTimeout",$sessionTimeout)
        $newRunspace.SessionStateProxy.SetVariable("rebootCheckTimeout",$rebootCheckTimeout)
        $newRunspace.SessionStateProxy.SetVariable("CimTimeoutSeconds",$ctx.CimTimeoutSeconds)
        $newRunspace.SessionStateProxy.SetVariable("ServiceTimeoutSeconds",$ctx.ServiceTimeoutSeconds)
        $newRunspace.SessionStateProxy.SetVariable("PerformanceTimeoutSeconds",$ctx.PerformanceTimeoutSeconds)
        $newRunspace.SessionStateProxy.SetVariable("CredProbeTimeoutSeconds",$ctx.CredProbeTimeoutSeconds)
        $newRunspace.SessionStateProxy.SetVariable("RebootProbeTimeoutSeconds",$ctx.RebootProbeTimeoutSeconds)
        $newRunspace.SessionStateProxy.SetVariable("OfflineWaitSeconds",$ctx.OfflineWaitSeconds)
        $newRunspace.SessionStateProxy.SetVariable("OnlineWaitSeconds",$ctx.OnlineWaitSeconds)
        # SS12: how many CONSECUTIVE connectivity failures justify eviction. Injected so the payload can
        # apply the same policy the state layer documents (one lost ICMP packet must not evict a host).
        $newRunspace.SessionStateProxy.SetVariable("ConnectivityFailuresBeforeRemoval",$global:ConnectivityFailuresBeforeRemoval)
        # ui/ layout file for the worker-side credential dialog (workers have no $PSScriptRoot)
        $newRunspace.SessionStateProxy.SetVariable("CredDialogXamlPath", $ctx.CredDialogXamlPath)
        # Shared worker pool for bounded probes (isolated runspaces cannot see
        # module functions - the pool OBJECT and an unbound invoke script are
        # injected together; see New-PooledInvokeScript in Wuu.Workers.psm1)
        $newRunspace.SessionStateProxy.SetVariable('WuuWorkerPool', (Get-WuuWorkerPool))
        $newRunspace.SessionStateProxy.SetVariable('InvokePooledScript', (New-PooledInvokeScript))
        
        # Add required functions to runspace by embedding them as script blocks
        # Unbound ([scriptblock]::Create) so invocation binds to the worker runspace where these variables exist
        $newRunspace.SessionStateProxy.SetVariable('WriteDebugLogScript', [scriptblock]::Create({
            param($Message, $Level = 'INFO', $Computer = '', [switch]$ToConsole)
            
            # Skip logging if debug logging is disabled
            if (-not $EnableDebugLogging) {
                return
            }
            
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [$Level]$(if($Computer){" [$Computer]"}) $Message"
            # Fault-tolerant append with retry: OneDrive/sync engines transiently lock
            # the log mid-write ("Stream was not readable" in PS 5.1). Logging must
            # never throw into a worker payload - retry, then give up silently.
            $maxAttempts = 3
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                $lockTaken = $false
                try {
                    [System.Threading.Monitor]::Enter($LogLock); $lockTaken = $true
                    Add-Content -Path $LogPath -Value $logEntry -Force
                    break
                } catch {
                    if ($attempt -ge $maxAttempts) { return }   # give up silently
                    Start-Sleep -Milliseconds (100 * $attempt)
                } finally {
                    if ($lockTaken) { [System.Threading.Monitor]::Exit($LogLock) }
                }
            }
        }.ToString()))
        
        # Fault-tolerant append for PRE-FORMATTED log lines (worker payload copy).
        # Worker payloads build "$logEntry" inline then call this instead of raw
        # Add-Content: same lock+retry semantics as WriteDebugLogScript, but takes
        # the finished line so payload format strings stay unchanged.
        $newRunspace.SessionStateProxy.SetVariable('WriteLogFileScript', [scriptblock]::Create({
            param([string]$LogEntry)
            $maxAttempts = 3
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                $lockTaken = $false
                try {
                    [System.Threading.Monitor]::Enter($LogLock); $lockTaken = $true
                    Add-Content -Path $LogPath -Value $LogEntry -Force
                    break
                } catch {
                    if ($attempt -ge $maxAttempts) { return }   # give up silently
                    Start-Sleep -Milliseconds (100 * $attempt)
                } finally {
                    if ($lockTaken) { [System.Threading.Monitor]::Exit($LogLock) }
                }
            }
        }.ToString()))
        
        # Display-patch helper for worker runspaces (T006.1 decoupled).
        #
        # THE OLD BODY WALKED THE LISTVIEW. It found the item by name and wrote the properties onto the
        # ITEM under a Dispatcher envelope. That only worked while the grid held the ENGINE rows by
        # reference. Under the projection the grid holds VIEW rows, so writing the item would land on a
        # snapshot and be overwritten by the next reconcile - the grid would silently stop updating.
        #
        # It now resolves the ENGINE row from the store BY KEY and delegates to the injected fenced
        # writer (SetComputerFencedFieldsScript), so the write is identity-checked exactly like every
        # other payload write, and the projection repaints the view. It touches no ListView and needs no
        # dispatcher. Returns the fence verdict, or $null when the row is gone / the writer is absent.
        $newRunspace.SessionStateProxy.SetVariable('SafeUpdateListViewItemScript', [scriptblock]::Create({
            param(
                [string]$ComputerName,
                [hashtable]$Properties
            )

            $row = $null
            try {
                if ($stateStore) { $row = $stateStore.ByName[$ComputerName.ToLowerInvariant()] }
            } catch { $row = $null }
            if (-not $row) { return $null }
            if (-not $SetComputerFencedFieldsScript) { return $null }

            $writerId = ''
            try { $writerId = [string]$WuuOperationId } catch { $writerId = '' }
            return & $SetComputerFencedFieldsScript -Computer $row -Fields $Properties -OperationId $writerId
        }.ToString()))

        # Timeout state helper for worker runspaces - FENCED TWIN of the funnel (T007 / step C).
        #
        # IT NO LONGER TOUCHES THE LISTVIEW. The old body mutated the row through
        # $uiHash.Listview.Items.EditItem/CommitEdit and set $listViewItem.Background directly, which
        # is the engine/view coupling this uplift exists to remove - and it meant a worker could only
        # write presentation that the UI happened to be showing. It now writes the ROW and signals a
        # redraw via the store; the projection layer renders it.
        #
        # IT IS NOW FENCED. The old body wrote State/Status/deadline with NO identity check and NO
        # terminal guard, so a superseded or force-stopped job could overwrite whatever row its
        # computer name resolved to - including one a newer operation already owned. The three checks
        # below are the same three in the same order as Update-WuuOperationState in Wuu.State.psm1:
        # identity, then reset fence, then the terminal guard. Refuse only a PROVEN staleness (the row
        # names an operation and this runspace is running a different one), because an unattributed
        # write is legitimate during row population.
        #
        # KEPT IN STEP WITH THE MODULE COPY. An injected runspace cannot resolve a module function, so
        # the rule has to exist twice; tests\Test-StateFencing.ps1 drives the module copy and
        # tests\Test-WorkerTwinFence.ps1 drives this one on identical rows and asserts they agree.
        $newRunspace.SessionStateProxy.SetVariable('SetComputerTimeoutScript', [scriptblock]::Create({
            param(
                [Parameter(Mandatory)][object]$Computer,
                [Parameter(Mandatory)][string]$Phase,
                [Parameter(Mandatory)][int]$TimeoutSec,
                [string]$Detail = '',
                # Explicit writer identity (submission/adoption). '' = use this runspace's operation.
                [string]$OperationId = ''
            )
            try {
                foreach ($requiredProperty in @('Computer', 'State', 'Status', 'UpdatesStatus', 'Color', 'TimeoutExpiresAt', 'TimeoutSource')) {
                    if (-not $Computer.PSObject.Properties[$requiredProperty]) { throw "Timeout row lacks required property: $requiredProperty" }
                }
                # SHARED STATE GATE (G3). Same store-held object the module funnel takes, so a worker
                # cannot interleave between another writer's validation and its write. Bounded: on a
                # busy gate this refuses rather than blocks (a worker must not hang the operation).
                $stateGateHeld = $false
                if ($stateStore -and $stateStore.Gate) {
                    try { $stateGateHeld = [System.Threading.Monitor]::TryEnter($stateStore.Gate, 5000) } catch { $stateGateHeld = $false }
                    if (-not $stateGateHeld) { return [pscustomobject]@{ Applied = $false; Refused = $true; Reason = 'StateGateBusy' } }
                }
                try {
                $writerId = $OperationId
                if (-not $writerId) { $writerId = [string]$WuuOperationId }

                $rowId = ''
                if ($Computer.PSObject.Properties['OperationId']) { $rowId = [string]$Computer.OperationId }

                # 1. IDENTITY - refuse only a proven staleness.
                if ($rowId -and $writerId -and ($rowId -cne $writerId)) { return [pscustomobject]@{ Applied = $false; Refused = $true; Reason = 'StaleOperation' } }
                # 2. RESET FENCE - the operation was reset, so this writer is stale.
                if ($writerId -and $Computer.PSObject.Properties['LastResetOperationId'] -and $Computer.LastResetOperationId) { return [pscustomobject]@{ Applied = $false; Refused = $true; Reason = 'ResetOperation' } }
                # 3. TERMINAL GUARD - a settled row is not re-settled into Timeout.
                $cur = if ($Computer.PSObject.Properties['State']) { [string]$Computer.State } else { '' }
                if ($cur -in @('Error', 'Timeout', 'Complete')) { return [pscustomobject]@{ Applied = $false; Refused = $true; Reason = 'TerminalState' } }
                # The row must still be in the store: writing to one the operator deleted is a leak.
                if ($stateStore) {
                    $live = $stateStore.ByName[[string]$Computer.Computer.ToLowerInvariant()]
                    if (-not [object]::ReferenceEquals($live, $Computer)) { return [pscustomobject]@{ Applied = $false; Refused = $true; Reason = 'RowReplacedOrRemoved' } }
                }

                $detailSuffix = if ($Detail) { " $Detail" } else { '' }
                if ($Computer.PSObject.Properties['TimeoutExpiresAt']) { $Computer.TimeoutExpiresAt = [DateTime]::Now.AddSeconds($TimeoutSec) }
                if ($Computer.PSObject.Properties['TimeoutSource'])    { $Computer.TimeoutSource    = $Phase }
                if ($Computer.PSObject.Properties['UpdatesStatus'])    { $Computer.UpdatesStatus    = 'Timeout' }
                if ($Computer.PSObject.Properties['State'])            { $Computer.State            = 'Timeout' }
                if ($Computer.PSObject.Properties['Status'])           { $Computer.Status           = "Timeout during $Phase after ${TimeoutSec}s - continuing to monitor.$detailSuffix" }
                if ($Computer.PSObject.Properties['Color'])            { $Computer.Color            = 'Timeout' }
                if ($stateStore) { $stateStore.Touch() }
                } finally {
                    if ($stateGateHeld) { [System.Threading.Monitor]::Exit($stateStore.Gate) }
                }
                return [pscustomobject]@{ Applied = $true; Refused = $false; Reason = '' }
            } catch { throw }
        }.ToString()))

        # State machine helper for worker runspaces - FENCED TWIN of the funnel (T007 / step C).
        # See the notes on SetComputerTimeoutScript above: same three checks, same order, and the same
        # deliberate avoidance of the ListView.
        $newRunspace.SessionStateProxy.SetVariable('SetComputerStateScript', [scriptblock]::Create({
            param(
                [Parameter(Mandatory)][object]$Computer,
                [Parameter(Mandatory)][string]$State,
                [string]$StatusDetail = '',
                [AllowEmptyString()][string]$Status = '',
                # Explicit writer identity (submission/adoption). '' = use this runspace's operation.
                [string]$OperationId = ''
            )
            $stateToStatus = @{
                'Queued'          = 'Waiting to start...'
                'Connecting'      = 'Testing Connectivity.'
                'Connected'       = 'Online.'
                'Checking'        = 'Initializing update session...'
                'Searching'       = 'Checking for updates...'
                'UpdatesFound'    = 'Updates found.'
                'Downloading'     = 'Downloading updates...'
                'Installing'      = 'Installing updates...'
                'RebootRequired'  = 'Reboot required.'
                'Rebooting'       = 'Restarting...'
                'Verifying'       = 'Verifying post-reboot state...'
                'Complete'        = 'All updates installed.'
                'Timeout'         = 'Operation timed out (recoverable).'
                'Error'           = 'Error occurred.'
            }
            try {
                foreach ($requiredProperty in @('Computer', 'State', 'Status')) {
                    if (-not $Computer.PSObject.Properties[$requiredProperty]) { throw "State row lacks required property: $requiredProperty" }
                }
                # SHARED STATE GATE (G3) - see the timeout twin above.
                $stateGateHeld = $false
                if ($stateStore -and $stateStore.Gate) {
                    try { $stateGateHeld = [System.Threading.Monitor]::TryEnter($stateStore.Gate, 5000) } catch { $stateGateHeld = $false }
                    if (-not $stateGateHeld) { return [pscustomobject]@{ Applied = $false; Refused = $true; Reason = 'StateGateBusy' } }
                }
                try {
                $writerId = $OperationId
                if (-not $writerId) { $writerId = [string]$WuuOperationId }

                $rowId = ''
                if ($Computer.PSObject.Properties['OperationId']) { $rowId = [string]$Computer.OperationId }

                # 1. IDENTITY
                if ($rowId -and $writerId -and ($rowId -cne $writerId)) { return [pscustomobject]@{ Applied = $false; Refused = $true; Reason = 'StaleOperation' } }
                # 2. RESET FENCE
                if ($writerId -and $Computer.PSObject.Properties['LastResetOperationId'] -and $Computer.LastResetOperationId) { return [pscustomobject]@{ Applied = $false; Refused = $true; Reason = 'ResetOperation' } }
                # 3. TERMINAL GUARD - a settled row may not be rewritten WITHOUT a new attributed
                #    operation. An explicit -OperationId IS the new attribution, which is how a retry
                #    of a failed canary stays legal; the module copy states the same rule.
                $cur = if ($Computer.PSObject.Properties['State']) { [string]$Computer.State } else { '' }
                if ($cur -in @('Error', 'Timeout', 'Complete') -and $State -ne $cur -and -not $OperationId) { return [pscustomobject]@{ Applied = $false; Refused = $true; Reason = 'TerminalState' } }
                if ($stateStore) {
                    $live = $stateStore.ByName[[string]$Computer.Computer.ToLowerInvariant()]
                    if (-not [object]::ReferenceEquals($live, $Computer)) { return [pscustomobject]@{ Applied = $false; Refused = $true; Reason = 'RowReplacedOrRemoved' } }
                }

                $statusString = $stateToStatus[$State]
                if (-not $statusString) { $statusString = $State }
                if ($StatusDetail) { $statusString += " $StatusDetail" }
                if ($PSBoundParameters.ContainsKey('Status')) { $statusString = $Status }
                if ($Computer.PSObject.Properties['State'])  { $Computer.State  = $State }
                if ($Computer.PSObject.Properties['Status']) { $Computer.Status = $statusString }
                if ($stateStore) { $stateStore.Touch() }
                } finally {
                    if ($stateGateHeld) { [System.Threading.Monitor]::Exit($stateStore.Gate) }
                }
                return [pscustomobject]@{ Applied = $true; Refused = $false; Reason = '' }
            } catch { throw }
        }.ToString()))

        # STORE-ROW REMOVAL (SS12 / review M-5). The RemoveOffline payload used to call the MODULE
        # function `Remove-WuuComputerRow -Store $global:stateStore` - but a module function is NOT
        # resolvable in an isolated worker runspace and `$global:stateStore` is not reachable there, so
        # the removal silently no-opped while the view write landed: the row was never actually evicted
        # from the authoritative store. This twin removes it under the shared gate, identity-guarded so a
        # superseded writer cannot evict a row a new operation owns.
        $newRunspace.SessionStateProxy.SetVariable('RemoveComputerRowScript', [scriptblock]::Create({
            param(
                [Parameter(Mandatory)][object]$Computer,
                [string]$WriterOperationId = ''
            )
            try {
                if (-not $stateStore) { return @{ Applied = $false; Refused = $true; Reason = 'NoStore' } }
                $key = [string]$Computer.Computer
                if (-not $key) { return @{ Applied = $false; Refused = $true; Reason = 'NoKey' } }
                $rmGateHeld = $false
                try { if ($stateStore.Gate) { $rmGateHeld = [System.Threading.Monitor]::TryEnter($stateStore.Gate, 5000) } } catch { $rmGateHeld = $false }
                if (-not $rmGateHeld) { return @{ Applied = $false; Refused = $true; Reason = 'StateGateBusy' } }
                try {
                    $live = $stateStore.ByName[$key.ToLowerInvariant()]
                    if (-not [object]::ReferenceEquals($live, $Computer)) { return @{ Applied = $false; Refused = $true; Reason = 'RowReplacedOrRemoved' } }
                    $rowId = ''
                    if ($Computer.PSObject.Properties['OperationId']) { $rowId = [string]$Computer.OperationId }
                    if ($rowId -and $WriterOperationId -and ($rowId -cne $WriterOperationId)) { return @{ Applied = $false; Refused = $true; Reason = 'StaleOperation' } }
                    [void]$stateStore.ByName.Remove($key.ToLowerInvariant())
                    $ri = $stateStore.Rows.Count - 1
                    while ($ri -ge 0) {
                        if ([object]::ReferenceEquals($stateStore.Rows[$ri], $Computer)) { $stateStore.Rows.RemoveAt($ri); break }
                        $ri--
                    }
                    $stateStore.Touch()
                    return @{ Applied = $true; Refused = $false; Reason = '' }
                } finally { [System.Threading.Monitor]::Exit($stateStore.Gate) }
            } catch { return @{ Applied = $false; Refused = $true; Reason = "error: $($_.Exception.Message)" } }
        }.ToString()))

        # PRE-DISPATCH QUEUE TWIN (T007.9). Payloads queue follow-ups ('InstallAndRecheck' after a
        # download), and doing that with a raw `$Computer.PendingOp = ...` BYPASSES the SS16 precedence
        # policy: a download tail could DOWNGRADE an 'AutoFlow' the operator had queued, so the computer
        # would do less than was asked. This is the injected twin of Set-WuuPendingOperation - same rank
        # table, same decline-below-queued rule - because an isolated runspace cannot call the module
        # function. A settled row takes no follow-up, exactly as the module copy refuses.
        $newRunspace.SessionStateProxy.SetVariable('SetPendingOpScript', [scriptblock]::Create({
            param(
                [Parameter(Mandatory)][object]$Computer,
                [Parameter(Mandatory)][string]$Op,
                [switch]$OnlyIfEmpty
            )
            $noChange = @{ Set = $false; Refused = $false; Op = $null; Replaced = $null; Existing = $null; Reason = '' }
            if (-not $Op -or -not $Computer.PSObject.Properties['PendingOp']) { return $noChange }

            # SERIALIZE THE ONE-SLOT QUEUE against the scheduler's consume (see Set-WuuPendingOperation).
            # Same shared store gate the fenced writers take. Bounded and fail-closed.
            $queueGateHeld = $false
            try { if ($stateStore -and $stateStore.Gate) { $queueGateHeld = [System.Threading.Monitor]::TryEnter($stateStore.Gate, 5000) } } catch { $queueGateHeld = $false }
            if ($stateStore -and $stateStore.Gate -and -not $queueGateHeld) { return @{ Set = $false; Refused = $true; Op = $null; Replaced = $null; Existing = $null; Reason = 'StateGateBusy' } }
            try {
            # SETTLED rows take no follow-up (mirrors Set-WuuPendingOperation).
            $cur = if ($Computer.PSObject.Properties['State']) { [string]$Computer.State } else { '' }
            if ($cur -in @('Error', 'Timeout', 'Complete')) {
                return @{ Set = $false; Refused = $false; Op = $null; Replaced = $null; Existing = $null; Reason = "the row has settled ('$cur') - there is no operation for a follow-up to follow" }
            }

            $rank = {
                param([string]$Name)
                if ([string]::IsNullOrWhiteSpace($Name)) { return 0 }
                switch -Regex ($Name.Trim()) {
                    '^Check$'                { return 1 }
                    '^Download$'             { return 2 }
                    '^Install(AndRecheck)?$' { return 3 }
                    '^(Restart|AutoFlow)$'   { return 4 }
                    default                  { return 0 }
                }
            }

            $existing = ''
            if ($Computer.PendingOp) { $existing = [string]$Computer.PendingOp }
            if ($OnlyIfEmpty -and $existing -ne '') { return $noChange }
            if ($existing -ceq $Op) {
                if ($Computer.PSObject.Properties['Pending']) { $Computer.Pending = $true }
                return @{ Set = $true; Refused = $false; Op = $Op; Replaced = $null; Existing = $existing; Reason = '' }
            }
            # DECLINE A DOWNGRADE: keep the higher-ranked request already queued.
            if ($existing -ne '' -and (& $rank $Op) -lt (& $rank $existing)) {
                return @{ Set = $false; Refused = $true; Op = $null; Replaced = $null; Existing = $existing
                    Reason = "'$Op' ranks below the '$existing' already queued for $($Computer.Computer) - the queued request is kept" }
            }
            $Computer.PendingOp = $Op
            if ($Computer.PSObject.Properties['Pending']) { $Computer.Pending = $true }
            $replaced = if ($existing -ne '') { $existing } else { $null }
            return @{ Set = $true; Refused = $false; Op = $Op; Replaced = $replaced; Existing = $existing; Reason = '' }
            } finally {
                if ($queueGateHeld) { [System.Threading.Monitor]::Exit($stateStore.Gate) }
            }
        }.ToString()))

        # EFFECT-BOUNDARY AUTHORIZATION (G6) - injected so a payload can ask "am I still allowed to ACT?"
        # immediately BEFORE a real remote effect (download/install/restart/service action).
        #
        # WHY THIS IS SEPARATE FROM THE STATE FENCE. The state fence stops a superseded payload from
        # WRITING the row - but a superseded payload keeps RUNNING for minutes, and the fence made it
        # silent, not safe: it could still download, install and reboot. The state fence protects state;
        # this decides whether an EFFECT may be dispatched, and it FAILS CLOSED (an unattributed writer
        # is refused here even though an unattributed state write is permitted, because populating a row
        # is not the same as rebooting a computer).
        #
        # Returns a hashtable @{ Authorized; Reason } - never throws, so a refusal is a clean outcome:
        # the payload reports it and stops, rather than starting work it is not entitled to do.
        $newRunspace.SessionStateProxy.SetVariable('TestEffectAuthorizedScript', [scriptblock]::Create({
            param(
                [Parameter(Mandatory)][object]$Computer,
                [string]$OperationId = ''
            )
            try {
                $writerId = $OperationId
                if (-not $writerId) { $writerId = [string]$WuuOperationId }
                $rowId = ''
                if ($Computer.PSObject.Properties['OperationId']) { $rowId = [string]$Computer.OperationId }

                # 1. IDENTITY - the acting writer must be the row's current owner. An UNATTRIBUTED
                #    effect is refused (fail-closed): every submitted operation claims its row before
                #    the payload runs, so an unattributed effect is a payload that should not exist.
                if (-not $writerId) { return @{ Authorized = $false; Reason = 'UnattributedEffect' } }
                if ($rowId -and ($rowId -cne $writerId)) { return @{ Authorized = $false; Reason = 'StaleOperation' } }
                if (-not $rowId) { return @{ Authorized = $false; Reason = 'RowNotClaimed' } }

                # 2. RESET FENCE - an operation that was reset is no longer authorized to act.
                if ($Computer.PSObject.Properties['LastResetOperationId'] -and $Computer.LastResetOperationId) {
                    return @{ Authorized = $false; Reason = 'ResetOperation' }
                }

                # 3. LIVE ROW - a removed or same-name-replaced row must not act on the wire.
                if ($stateStore) {
                    $live = $stateStore.ByName[[string]$Computer.Computer.ToLowerInvariant()]
                    if (-not [object]::ReferenceEquals($live, $Computer)) {
                        return @{ Authorized = $false; Reason = 'RowReplacedOrRemoved' }
                    }
                }
                return @{ Authorized = $true; Reason = '' }
            } catch {
                return @{ Authorized = $false; Reason = ('EffectAuthorizationError: ' + $_.Exception.Message) }
            }
        }.ToString()))

        # MULTI-FIELD FENCED WRITER (T007.8+). The payloads set several row fields TOGETHER
        # (Status+State+UpdatesStatus+RebootRequired+counters), and a sequence of single-field calls
        # would expose half-written rows. This applies an allow-listed patch atomically under the gate.
        #
        # DELIBERATELY NOT ROUTED: Pending/PendingOp (scheduler-owned queue policy with inlined
        # precedence - see Set-WuuPendingOperation) and OperationId/OpState (funnel-owned identity).
        # A caller cannot reach those through this writer, so the queue policy cannot be bypassed.
        #
        # The field bag is applied with language constructs only (no pipeline cmdlets) - this runs in a
        # payload runspace and, on the timeout path, can run inside a Dispatcher action.
        $newRunspace.SessionStateProxy.SetVariable('SetComputerFencedFieldsScript', [scriptblock]::Create({
            param(
                [Parameter(Mandatory)][object]$Computer,
                [Parameter(Mandatory)][System.Collections.IDictionary]$Fields,
                [string]$OperationId = ''
            )
            $allowedFields = @(
                'State', 'Status', 'UpdatesStatus', 'Color', 'Available', 'Downloaded',
                'InstallErrors', 'RebootRequired', 'RetryCount', 'RetryAt',
                'TimeoutExpiresAt', 'TimeoutSource', 'ConnectivityFailures', 'LastConnectivityError',
                'Phase'
            )
            # RetryCount/RetryAt ARE writable (Phase-E retry bookkeeping, no precedence policy).
            $terminalStates = @('Error', 'Timeout', 'Complete')
            try {
                # Reject the WHOLE patch (not a partial apply) if it touches a non-allow-listed or
                # absent field, so a typo cannot silently drop an update.
                foreach ($name in $Fields.Keys) {
                    if ($name -notin $allowedFields) { throw "field '$name' is not writable through the fenced writer" }
                    if (-not $Computer.PSObject.Properties[$name]) { throw "row lacks field '$name'" }
                }
                # VALIDATE THE COLOUR VOCABULARY (review m-1) - same rule as the module copy.
                if ($Fields.Contains('Color')) {
                    $colorValue = [string]$Fields['Color']
                    if ($colorValue -and $colorValue -notin @('Default', 'Error', 'Timeout', 'Success')) {
                        throw "Color '$colorValue' is not a known colour name"
                    }
                }

                $stateGateHeld = $false
                if ($stateStore -and $stateStore.Gate) {
                    try { $stateGateHeld = [System.Threading.Monitor]::TryEnter($stateStore.Gate, 5000) } catch { $stateGateHeld = $false }
                    if (-not $stateGateHeld) { return @{ Applied = $false; Refused = $true; Reason = 'StateGateBusy' } }
                }
                try {
                    $writerId = $OperationId
                    if (-not $writerId) { $writerId = [string]$WuuOperationId }
                    $rowId = ''
                    if ($Computer.PSObject.Properties['OperationId']) { $rowId = [string]$Computer.OperationId }

                    # IDENTITY: a row that names a DIFFERENT owner refuses the patch; an unattributed
                    # write is permitted exactly as the other writers permit one (row population).
                    if ($rowId -and $writerId -and ($rowId -cne $writerId)) { return @{ Applied = $false; Refused = $true; Reason = 'StaleOperation' } }
                    if ($writerId -and $Computer.PSObject.Properties['LastResetOperationId'] -and $Computer.LastResetOperationId) { return @{ Applied = $false; Refused = $true; Reason = 'ResetOperation' } }
                    # TERMINAL GUARD: a settled row is not rewritten without a NEW attribution. A patch
                    # that only sets terminal-display or bookkeeping fields on an already-settled row is
                    # a same-state write and stays legal.
                    $newState = if ($Fields.Contains('State')) { [string]$Fields['State'] } else { '' }
                    $cur = if ($Computer.PSObject.Properties['State']) { [string]$Computer.State } else { '' }
                    if ($cur -in $terminalStates -and $newState -and $newState -ne $cur -and -not $OperationId) {
                        return @{ Applied = $false; Refused = $true; Reason = 'TerminalState' }
                    }
                    if ($stateStore) {
                        $live = $stateStore.ByName[[string]$Computer.Computer.ToLowerInvariant()]
                        if (-not [object]::ReferenceEquals($live, $Computer)) { return @{ Applied = $false; Refused = $true; Reason = 'RowReplacedOrRemoved' } }
                    }

                    foreach ($name in $Fields.Keys) { $Computer.$name = $Fields[$name] }
                    if ($stateStore) { $stateStore.Touch() }
                    return @{ Applied = $true; Refused = $false; Reason = '' }
                } finally {
                    if ($stateGateHeld) { [System.Threading.Monitor]::Exit($stateStore.Gate) }
                }
            } catch { throw }
        }.ToString()))

        # Single source of truth lives in Wuu.Remote.psm1; unbound copy so it runs in the worker runspace
        $newRunspace.SessionStateProxy.SetVariable('InvokeRemoteTaskScript', [scriptblock]::Create((Get-Command -Name 'Invoke-WuuRemoteTask' -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()))

        # Add custom credential dialog script to runspace
        $newRunspace.SessionStateProxy.SetVariable('ShowCustomCredentialDialogScript', [scriptblock]::Create({
            param(
                [string]$Message = "Enter your credentials",
                [string]$Username = "",
                [string]$Title = "Credentials Required"
            )
            
            Add-Type -AssemblyName PresentationFramework
            Add-Type -AssemblyName PresentationCore
            Add-Type -AssemblyName WindowsBase
            
            # Layout lives in ui/CredentialDialog.xaml - single source of truth, loaded via
            # the injected $CredDialogXamlPath variable (workers have no $PSScriptRoot).
            $xamlCredentialDialog = Get-Content -Path $CredDialogXamlPath -Raw
            $xamlCredentialDialog = $xamlCredentialDialog -replace '\$Title\b', $Title -replace '\$Message\b', $Message
            
            try {
                $reader = [System.Xml.XmlNodeReader]::new([xml]$xamlCredentialDialog)
                $dialog = [Windows.Markup.XamlReader]::Load($reader)
                
                # Get dialog controls
                $usernameTextBox = $dialog.FindName('UsernameTextBox')
                $passwordBox = $dialog.FindName('PasswordBox')
                $rememberCheckBox = $dialog.FindName('RememberCheckBox')
                $okButton = $dialog.FindName('OKButton')
                $cancelButton = $dialog.FindName('CancelButton')
                
                # Set initial username if provided
                if ($Username) {
                    $usernameTextBox.Text = $Username
                }
                
                # Set focus to appropriate control when dialog opens
                $dialog.Add_Loaded({
                    if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
                        $usernameTextBox.Focus()
                    } else {
                        $passwordBox.Focus()
                    }
                })
                
                # OK button click handler
                $okButton.Add_Click({
                    if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
                        [System.Windows.MessageBox]::Show("Please enter a username.", "Credential Error", 'OK', 'Warning')
                        $usernameTextBox.Focus()
                        return
                    }
                    
                    if ($passwordBox.SecurePassword.Length -eq 0) {
                        [System.Windows.MessageBox]::Show("Please enter a password.", "Credential Error", 'OK', 'Warning')
                        $passwordBox.Focus()
                        return
                    }
                    
                    # Store results in dialog tag
                    $dialog.Tag = @{
                        Username = $usernameTextBox.Text
                        Password = $passwordBox.SecurePassword.Copy()
                        Remember = $rememberCheckBox.IsChecked
                    }
                    $dialog.DialogResult = $true
                    $dialog.Close()
                })
                
                # Cancel button click handler
                $cancelButton.Add_Click({
                    $dialog.DialogResult = $false
                    $dialog.Close()
                })
                
                # Handle Enter key in both text boxes
                $usernameTextBox.Add_KeyDown({
                    if ($_.Key -eq 'Enter') {
                        $passwordBox.Focus()
                    }
                })
                
                $passwordBox.Add_KeyDown({
                    if ($_.Key -eq 'Enter') {
                        $okButton.RaiseEvent([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
                    }
                })
                
                # Set dialog owner to main window if available
                if ($uiHash.Window) {
                    $dialog.Owner = $uiHash.Window
                }
                
                # Show dialog
                $result = $dialog.ShowDialog()
                
                if ($result -eq $true) {
                    $credential = New-Object System.Management.Automation.PSCredential($dialog.Tag.Username, $dialog.Tag.Password)
                    return $credential
                } else {
                    return $null
                }
                
            } catch {
                # Fallback to Get-Credential if custom dialog fails
                return Get-Credential -Message $Message -ErrorAction SilentlyContinue
            }
        }.ToString()))
        
        # Add Get-RemoteCredentials function to runspace (with timeout protection to prevent hangs)
        $newRunspace.SessionStateProxy.SetVariable('GetRemoteCredentialsScript', [scriptblock]::Create({
            param(
                [string]$ComputerName,
                [string]$Operation = 'WMI access'
            )
            
            # Initialize CredentialCache if it doesn't exist
            if (-not $CredentialCache) {
                $CredentialCache = @{}
            }
            
            # Check cache first
            if ($CredentialCache.ContainsKey($ComputerName)) {
                return $CredentialCache[$ComputerName]
            }
            
            # Inline timeout helper: runs a CIM probe on the shared worker pool with a
            # hard timeout. Was Start-Job (one child process per probe, two per computer).
            # $Cred is always a PSCredential (or $null for default credentials) - typed so a
            # plain-string password can never be passed as a credential.
            # NOTE: PS 5.1's Get-CimInstance has NO -Credential parameter; alternate
            # credentials must go through New-CimSession (DCOM) + Get-CimInstance -CimSession.
            # The probe must actually RUN the query - it validates credentials AND reachability.
            $testCim = {
                # DCOM for both paths - Get-CimInstance -ComputerName implies WinRM and
                # fails on WMI-reachable hosts with no WinRM listener (see Invoke-CimWithTimeout).
                param([string]$ComputerName, [pscredential]$Cred)
                $cimSession = $null
                try {
                    $sessionArgs = @{ ComputerName = $ComputerName; SessionOption = (New-CimSessionOption -Protocol DCOM) }
                    if ($Cred) { $sessionArgs['Credential'] = $Cred }
                    $cimSession = New-CimSession @sessionArgs -ErrorAction Stop
                    $null = Get-CimInstance -CimSession $cimSession -ClassName 'Win32_ComputerSystem' -ErrorAction Stop
                    return @{ Success = $true }
                } catch {
                    return @{ Success = $false; Error = $_.Exception.Message }
                } finally {
                    if ($cimSession) { Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue }
                }
            }
            
            # Try custom credentials first if configured
            if ($UseCustomCredentials -and $CustomCredentials) {
                try {
                    $result = & $InvokePooledScript -Pool $WuuWorkerPool -ScriptBlock $testCim `
                        -ArgumentList @($ComputerName, $CustomCredentials) -TimeoutSeconds 5 -OperationName 'Credential probe (custom)'
                    if ($result -and $result.Success -and $result.Result -and $result.Result.Success) {
                        if (-not $CredentialCache) { $CredentialCache = @{} }
                        $CredentialCache[$ComputerName] = $CustomCredentials
                        return $CustomCredentials
                    }
                } catch {
                    try {
                        & $WriteDebugLogScript -Message "Custom credentials failed for $ComputerName : $($_.Exception.Message)" -Level 'WARN'
                    } catch { }
                }
            }
            
            # Custom credentials failed or not configured, try default credentials
            try {
                $result = & $InvokePooledScript -Pool $WuuWorkerPool -ScriptBlock $testCim `
                    -ArgumentList @($ComputerName, $null) -TimeoutSeconds 5 -OperationName 'Credential probe (default)'
                if ($result -and $result.Success -and $result.Result -and $result.Result.Success) {
                    if (-not $CredentialCache) { $CredentialCache = @{} }
                    $CredentialCache[$ComputerName] = $null  # null means use default credentials
                    return $null
                }
            } catch {
                try {
                    & $WriteDebugLogScript -Message "Default credentials failed for $ComputerName : $($_.Exception.Message)" -Level 'WARN'
                } catch { }
            }
            
            # Cannot prompt for credentials from a background runspace (deadlocks UI thread)
            # Return $null to indicate auth failed; the caller will handle the error
            return $null
        }.ToString()))
        
        # Add Get-ErrorSuggestions function to runspace
        $newRunspace.SessionStateProxy.SetVariable('GetErrorSuggestionsScript', [scriptblock]::Create({
            param([string]$ErrorMessage)
            
            foreach ($errorCode in $errorSuggestionsHash.Keys) {
                if ($ErrorMessage -match $errorCode) {
                    return $errorSuggestionsHash[$errorCode]
                }
            }
            
            return @{
                Description = 'Unknown error'
                Suggestions = @('Check Windows Event Logs for more details', 'Verify network connectivity', 'Try the operation again')
                AutoFix = $false
            }
        }.ToString()))
        
        # Add Invoke-AutoRecovery function to runspace
        $newRunspace.SessionStateProxy.SetVariable('InvokeAutoRecoveryScript', [scriptblock]::Create({
            param([string]$ComputerName, [string]$ErrorCode)
            
            $errorInfo = & $GetErrorSuggestionsScript -ErrorMessage $ErrorCode
            
            if (-not $errorInfo.AutoFix) {
                return $false
            }
            
            try {
                switch ($ErrorCode) {
                    '800706ba' { # RPC server unavailable
                        # Try to restart RPC service using Invoke-Command
                        if ($ComputerName -eq 'localhost' -or $ComputerName -eq $env:COMPUTERNAME) {
                            Get-Service -Name 'RpcSs' -ErrorAction Stop | Restart-Service -ErrorAction Stop
                            Start-Sleep -Seconds 5
                            Get-Service -Name 'RemoteRegistry' -ErrorAction Stop | Start-Service -ErrorAction Stop
                        } else {
                            # Get appropriate credentials for this computer
                            $credential = Get-RemoteCredentials -ComputerName $ComputerName -Operation 'RPC service restart'
                            
                            if ($credential) {
                                Invoke-Command -ComputerName $ComputerName -Credential $credential -ScriptBlock {
                                    Get-Service -Name 'RpcSs' -ErrorAction Stop | Restart-Service -ErrorAction Stop
                                    Start-Sleep -Seconds 5
                                    Get-Service -Name 'RemoteRegistry' -ErrorAction Stop | Start-Service -ErrorAction Stop
                                } -ErrorAction Stop
                            } else {
                                Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                                    Get-Service -Name 'RpcSs' -ErrorAction Stop | Restart-Service -ErrorAction Stop
                                    Start-Sleep -Seconds 5
                                    Get-Service -Name 'RemoteRegistry' -ErrorAction Stop | Start-Service -ErrorAction Stop
                                } -ErrorAction Stop
                            }
                        }
                        Start-Sleep -Seconds 3
                        
                        return $true
                    }
                    '800706be' { # RPC failed
                        # Wait and retry
                        Start-Sleep -Seconds 10
                        return $true
                    }
                    default {
                        return $false
                    }
                }
            } catch {
                return $false
            }
        }.ToString()))

            return $newRunspace
}

function Start-UpdateCheckJob {
    param(
        $ComputerItem,
        # Optional follow-up operation to chain in a SINGLE pipeline. NEVER BeginInvoke a
        # second pipeline onto a busy per-computer runspace from inside that runspace:
        # the inner payload silently never runs and EndInvoke throws "pipeline already
        # running" (root cause of auto-download/auto-install doing nothing). Chained
        # ops run sequentially inside one BeginInvoke, exactly like $eventInstallUpdates.
        #
        # Restart/RemoveOffline/ServiceAction are lifecycle ops whose pipeline is NOT one of the
        # built-in update chains; they must be driven through -Payload so every engine/action
        # submission shares THIS ONE admitted path instead of composing its own BeginInvoke.
        [ValidateSet('Check','Download','InstallAndRecheck','AutoFlow','Restart','RemoveOffline','ServiceAction')]
        [string]$Op = 'Check',
        # Explicit pipeline for the lifecycle ops: an ordered array of
        #   @{ Script = <scriptblock>; Arguments = @(...) }
        # composed exactly like the switch below. When supplied, -Op names the operation (and thus
        # its deadline) but no longer selects the pipeline.
        [Parameter(Mandatory=$false)][AllowEmptyCollection()][object[]]$Payload = $null
    )
    $ctx = $script:WuuCtx
    $GetUpdates = $ctx.GetUpdates; $jobs = $ctx.Jobs
    $stateStore = $ctx.StateStore
    # Resolve the cap defensively: Test-WuuConcurrencyAvailable refuses at <= 0 (deliberate
    # fail-closed), so an absent context value would otherwise refuse EVERY submission. Fall back to
    # the configured global; a genuinely misconfigured cap of 0 still refuses, which is intended.
    $MaxConcurrentJobs = $ctx.MaxConcurrentJobs
    if ($null -eq $MaxConcurrentJobs) { $MaxConcurrentJobs = $global:MaxConcurrentJobs }
    $PowerShell = $null

    # LIFECYCLE OPS REQUIRE AN EXPLICIT PAYLOAD. This validation is BEFORE the try/runspace work on
    # purpose: raised inside the try it would be caught by the runspace-failure handler, which would
    # paint the row 'Failed to initialize' with a misleading message and abandon a runspace. A caller
    # error must refuse, not corrupt the row.
    if (-not $Payload -and $Op -in @('Restart', 'RemoveOffline', 'ServiceAction')) {
        Write-ErrorLog "Refused '$Op' for $($ComputerItem.Computer): a lifecycle op requires an explicit -Payload"
        return $false
    }
    
    try {
        # FAST PRE-CHECK, BEFORE ANY RUNSPACE WORK. `SessionStateProxy.SetVariable` on a BUSY runspace
        # throws "A pipeline is already running. Concurrent SessionStateProxy method calls are not
        # allowed." - and that throw lands in the catch below, which reports "Runspace creation failed"
        # and paints the row Error. So a second Check while one is still running must be REFUSED here,
        # before the runspace is created or touched. (Measured: the operator's second click during a
        # running check produced exactly that Error.)
        if (Test-WuuComputerBusy -Row $ComputerItem) {
            $preOwner = if ($ComputerItem.PSObject.Properties['OperationId']) { [string]$ComputerItem.OperationId } else { '' }
            $preRefusal = "computer is already running an operation ($preOwner)"
            Write-InfoLog "Submission for $($ComputerItem.Computer) refused: $preRefusal"
            try { Update-WuuRefusalRecord -Row $ComputerItem -Reason $preRefusal | Out-Null } catch { }
            # Do NOT write Status here: the row is BUSY, so this message would overwrite the running
            # operation's live progress text ("Checking for updates...") and the operator would see a
            # refusal notice instead of the work in progress. The visible signal is that row's own
            # status; the refusal is recorded for the phase gate.
            return $false
        }

        # CREDENTIAL-EPOCH REBUILD (T009.1, R04). A per-computer runspace is created ONCE and captures the
        # credential globals AT CREATION, so after the operator changes the credentials every existing
        # row would keep resolving its identity from the runspace's stale copies - a submitted operation
        # would silently run under the OLD account. The documented mechanism (see Update-WuuCredentialEpoch)
        # is to stamp the row's epoch when its runspace is built and REBUILD when the current epoch
        # differs, so an operation always runs under the identity configured AT SUBMISSION.
        $currentEpoch = -1
        try { if ($global:CredentialEpoch) { $currentEpoch = [int]$global:CredentialEpoch } } catch { $currentEpoch = -1 }
        $rowEpoch = -1
        if ($ComputerItem.PSObject.Properties['CredentialEpoch']) { $rowEpoch = [int]$ComputerItem.CredentialEpoch }
        if ($ComputerItem.Runspace -and $rowEpoch -ne $currentEpoch) {
            $staleRunspace = $ComputerItem.Runspace
            # Detach FIRST, then close: the funnel/cleanup also detach on release, and closing a runspace
            # this row no longer references avoids a later double-close.
            $ComputerItem.Runspace = $null
            try { $staleRunspace.Close() } catch { }
            try { $staleRunspace.Dispose() } catch { }
            Write-InfoLog "Credential epoch changed ($rowEpoch -> $currentEpoch) for $($ComputerItem.Computer); runspace rebuilt"
        }

        if (-not $ComputerItem.Runspace) {
            $ComputerItem.Runspace = New-ComputerRunspace -ComputerItem $ComputerItem
            # Stamp the epoch this runspace was built with, so the NEXT submission can detect a change.
            if ($ComputerItem.PSObject.Properties['CredentialEpoch']) { $ComputerItem.CredentialEpoch = $currentEpoch }
        }

        # The claim below is only real if the row HAS the engine contract: the funnel's field writer
        # skips a property that does not exist, so a bare property-bag row would be reported as
        # stamped while carrying no identity. Production backfills at every ListView add site; this
        # covers rows that arrived another way (a test harness, or a future caller).
        if (-not $ComputerItem.PSObject.Properties['OperationId'] -or -not $ComputerItem.PSObject.Properties['OpState']) {
            Set-WuuRowEngineDefaults -Row $ComputerItem | Out-Null
        }

        # MINT THE OPERATION IDENTITY AND PREPARE THE PIPELINE (T006/T007 step B).
        #
        # The identity is not yet claimed - that happens under the admission section below. Minting
        # here keeps the runspace creation and the (comparatively expensive) pipeline composition
        # outside the critical section.
        $opId = New-WuuOperationId -Computer $ComputerItem.Computer
        $PowerShell = [powershell]::Create()
        try { $PowerShell.Runspace = $ComputerItem.Runspace } catch { }
        # $WuuOperationId is NOT stamped here: SessionStateProxy rejects writes while a pipeline is
        # active, so it is stamped inside the admission section below, after the busy re-test has
        # proven the runspace idle.

        # A lifecycle op with no payload would silently fall through to a plain Check under that op's
        # name (and its deadline). Refused above, before any runspace work.

        if ($Payload) {
            foreach ($step in $Payload) {
                $PowerShell.AddScript($step.Script) | Out-Null
                # A payload step may be a hashtable (ContainsKey) or a plain object (a property bag).
                # Assuming ContainsKey throws "method not found" on the latter, which would surface as
                # the misleading runspace-failure path.
                $stepArguments = $null
                if ($step -is [System.Collections.IDictionary]) {
                    if ($step.Contains('Arguments')) { $stepArguments = $step['Arguments'] }
                } elseif ($step.PSObject.Properties['Arguments']) {
                    $stepArguments = $step.Arguments
                }
                if ($null -ne $stepArguments) {
                    foreach ($stepArgument in @($stepArguments)) { $PowerShell.AddArgument($stepArgument) | Out-Null }
                }
            }
        } else {
            switch ($Op) {
                'Download'           { $PowerShell.AddScript($ctx.DownloadUpdates).AddArgument($ComputerItem).AddArgument($Op) | Out-Null }
                'InstallAndRecheck'  {
                    $PowerShell.AddScript($ctx.InstallUpdates).AddArgument($ComputerItem) | Out-Null
                    $PowerShell.AddScript($ctx.RestartComputer).AddArgument($ComputerItem).AddArgument($true) | Out-Null
                    $PowerShell.AddScript($GetUpdates).AddArgument($ComputerItem) | Out-Null
                }
                'AutoFlow'           {
                    # Full unattended chain: download, then install/reboot/recheck. DownloadUpdates'
                    # own auto-install tail is suppressed by the $Op argument.
                    $PowerShell.AddScript($ctx.DownloadUpdates).AddArgument($ComputerItem).AddArgument($Op) | Out-Null
                    $PowerShell.AddScript($ctx.InstallUpdates).AddArgument($ComputerItem) | Out-Null
                    $PowerShell.AddScript($ctx.RestartComputer).AddArgument($ComputerItem).AddArgument($true) | Out-Null
                    $PowerShell.AddScript($GetUpdates).AddArgument($ComputerItem) | Out-Null
                }
                default              { $PowerShell.AddScript($GetUpdates).AddArgument($ComputerItem) | Out-Null }   # 'Check'
            }
        }
        $PowerShell.Runspace = $ComputerItem.Runspace

        # ADMISSION PRECEDES THE START (T011.1 / remediation G3).
        #
        # MEASURED DEFECT THIS CLOSES: the job entry used to be created by BeginInvoke BEFORE the row
        # was claimed, and a refused claim was only logged ("the job still runs"). So a submission
        # against a computer that already had a live operation started a second payload on the same
        # runspace: its work is discarded by the engine (a second BeginInvoke on a busy pipeline is
        # accepted and then discarded) while its writes were unattributed and therefore permitted.
        # The submission did not even consume a capacity slot before the claim, so the global cap was
        # tested at a different moment from the one at which capacity was consumed.
        #
        # The section holds no I/O, no dispatcher wait and no remote call: it re-tests per-computer
        # ownership, re-tests the global cap, stamps the claim, starts the pipeline and appends the
        # complete job entry. Monitor is re-entrant, so a nested submission on the same thread cannot
        # deadlock here, and a caller that cannot acquire the lock treats it as "no capacity" and
        # refuses (recoverable: the row stays Pending and the scheduler retries).
        $admissionRefusal = ''
        $lockHeld = Enter-WuuSubmissionLock
        if (-not $lockHeld) {
            $admissionRefusal = 'admission lock unavailable (another submission holds it)'
        }
        try {
            if (-not $admissionRefusal) {
                if (Test-WuuComputerBusy -Row $ComputerItem) {
                    $owningOp = if ($ComputerItem.PSObject.Properties['OperationId']) { [string]$ComputerItem.OperationId } else { '' }
                    $admissionRefusal = "computer is already running an operation ($owningOp)"
                } elseif (-not (Test-WuuConcurrencyAvailable -Jobs $jobs -MaxConcurrentJobs $MaxConcurrentJobs)) {
                    $admissionRefusal = "concurrency cap reached ($($jobs.Count)/$MaxConcurrentJobs)"
                }
            }

            if (-not $admissionRefusal) {
                $stamp = Update-WuuOperationState -Row $ComputerItem -OperationIdNew $opId -OpState 'Running' -OpStartedAt (Get-Date) -OpName $Op
                if (-not $stamp.Applied) {
                    $admissionRefusal = "claim refused: $($stamp.Reason)"
                }
            }

            if (-not $admissionRefusal) {
                # STAMP THE PER-OPERATION DEADLINE AT SUBMISSION (SS5). Without this the row carries no
                # TimeoutExpiresAt, so the cleanup loop could only fall back to a flat number and the
                # per-op table ($global:OperationTimeoutSeconds - AutoFlow 4 h, Restart 45 m, ...) was
                # dead configuration: an AutoFlow would be force-stopped at the flat 10 minutes. Stamping
                # here also makes the promise INSPECTABLE while the job runs. The row is freshly claimed,
                # so no other writer can race this.
                try { $null = Set-WuuOperationDeadline -Row $ComputerItem -Op $Op } catch { }
                # Stamp the operation identity NOW. The busy re-test above proved the runspace idle, so
                # this SessionStateProxy write cannot hit "A pipeline is already running"; the payload
                # reads $WuuOperationId to attribute its writes.
                try { $PowerShell.Runspace.SessionStateProxy.SetVariable('WuuOperationId', $opId) } catch { }
                # Only an accepted claim reaches BeginInvoke. If the start itself fails the claim is
                # rolled back (a SubmissionFailure reset retires the identity) so the row does not
                # stay permanently busy after a job that never ran.
                try {
                    $handle = $PowerShell.BeginInvoke()
                } catch {
                    $startError = $_.Exception.Message
                    # Guard the rollback by ownership: the reset itself is unconditional, so passing
                    # the identity keeps a future caller outside this lock from resetting a replacement.
                    $null = Update-WuuOperationState -Row $ComputerItem -OperationId $opId -ResetOperation (New-WuuResetOperationContext -Source 'SubmissionFailure' -Reason "start failed: $startError") -State 'Error'
                    $admissionRefusal = "start failed: $startError"
                }
                if (-not $admissionRefusal) {
                    # OperationId is carried on the JOB record so the cleanup loop can compare it
                    # against the row before retiring the identity - a job releases only what it owns.
                    $temp = New-Object PSObject -Property @{
                        PowerShell = $PowerShell
                        Runspace = $handle
                        StartTime = Get-Date
                        Computer = $ComputerItem.Computer
                        OperationId = $opId
                    }
                    $jobs.Add($temp) | Out-Null
                }
            }
        } finally {
            Exit-WuuSubmissionLock
        }

        if ($admissionRefusal) {
            Write-InfoLog "Submission for $($ComputerItem.Computer) (op $opId) refused: $admissionRefusal"
            # RECORD THE REFUSAL ON THE ROW (D14 follow-up). A refusal is NOT an error - the operation
            # never started - so it must not be reported as a failure. But it must be VISIBLE, or a row
            # refused every tick is indistinguishable from a row waiting its turn, and the phase gate
            # would wait for ever on a computer that can never be admitted. This is the recorder the
            # phase gate reads (Update-WuuRefusalRecord / Test-WuuRefusalStalled).
            try { Update-WuuRefusalRecord -Row $ComputerItem -Reason $admissionRefusal | Out-Null } catch { }
            # A refusal must be VISIBLE on the row, not only in the debug log: in the default
            # configuration EnableDebugLogging is $false, so Write-InfoLog above is a silent no-op and
            # an operator's one-shot menu action would look like it did nothing.
            #
            # ONLY WHEN THE ROW IS NOT BUSY. A BUSY row's refusal must NOT overwrite the RUNNING
            # operation's live progress text - the same rule the fast pre-check above follows. A busy
            # refusal is already visible as the running operation's own status; a cap/lock refusal on a
            # non-busy row is what needs the message.
            try {
                if (-not (Test-WuuComputerBusy -Row $ComputerItem) -and $ComputerItem.PSObject.Properties['Status']) {
                    $ComputerItem.Status = "Submission refused: $admissionRefusal"
                }
            } catch { }
            try { $PowerShell.Dispose() } catch { }
            return $false
        }
        # Admitted: an operation got in, so the consecutive-refusal count restarts.
        try { Update-WuuRefusalRecord -Row $ComputerItem -Admitted | Out-Null } catch { }

        return $true
    } catch {
        # In a catch block $_ is the ErrorRecord, not the computer item
        $errorMessage = $_.Exception.Message
        Write-ErrorLog "Runspace creation failed for $($ComputerItem.Computer): $errorMessage"
        
        # Cleanup on failure - dispose PowerShell instance to prevent leaks
        if ($PowerShell) {
            try {
                $PowerShell.Stop()
                $PowerShell.Dispose()
            } catch {
                Write-WarningLog "Failed to cleanup PowerShell instance for $($ComputerItem.Computer): $($_.Exception.Message)"
            }
        }
        
        # Paint the failed-init state on the ENGINE row, not the ListView (T006.1). The grid holds
        # detached view rows now, so an EditItem/CommitEdit on $ComputerItem would edit nothing and the
        # ContainerFromItem colouring is dead. Resolve the row from the STORE by key and write the
        # display fields directly; the `Color` field drives the fill via ui\MainWindow.xaml.
        try {
            $failRow = $ComputerItem
            if ($stateStore) {
                $liveFailRow = $stateStore.ByName[[string]$ComputerItem.Computer.ToLowerInvariant()]
                if ($liveFailRow) { $failRow = $liveFailRow }
            }
            if ($failRow.PSObject.Properties['Status'])        { $failRow.Status        = "Failed to initialize: $errorMessage" }
            if ($failRow.PSObject.Properties['UpdatesStatus']) { $failRow.UpdatesStatus = 'Error' }
            if ($failRow.PSObject.Properties['State'])         { $failRow.State         = 'Error' }
            if ($failRow.PSObject.Properties['Color'])         { $failRow.Color         = 'Error' }
            if ($stateStore) { $stateStore.Touch() }
        } catch { }
        return $false
    }
}

function Start-PendingUpdateCheck {
    $ctx = $script:WuuCtx
    $backgroundProcessing = $ctx.BackgroundProcessing
    $jobs = $ctx.Jobs
    # SOURCE AND DRIVE THE ENGINE STORE, NOT THE LISTVIEW (T006.1). The ListView now holds detached VIEW
    # rows, so a scheduler that read/wrote `$uiHash.Listview.Items` would silently: never promote a
    # Phase-E retry, never submit a queued op, and never see the phase - auto-flow would simply stop
    # working. The store is authoritative; every write signals a repaint via Touch().
    # Resolved from the context, then the global store, exactly as the funnel does.
    $stateStore = $ctx.StateStore
    if (-not $stateStore) { try { $stateStore = $global:stateStore } catch { $stateStore = $null } }
    # Mirror the submission path's defensive fallback: $jobs.Count -ge $null coerces $null to 0,
    # i.e. refuse everything, so an absent context value must not silently stop the scheduler.
    $MaxConcurrentJobs = $ctx.MaxConcurrentJobs
    if ($null -eq $MaxConcurrentJobs) { $MaxConcurrentJobs = $global:MaxConcurrentJobs }
    if ($backgroundProcessing.Suspended) { return }
    if (-not $stateStore) { return }
    # Promote due Phase-E timeout retries (RetryAt set by $GetUpdates) back into the pending queue.
    # GATED (review M-1): these are plain read-modify-writes on shared row state, and a payload may be
    # writing the same row from its own thread. Take the SAME shared store gate the fenced writers use.
    $retryGateHeld = Enter-WuuStateLock -Store $stateStore
    if ($retryGateHeld) {
        try {
            $now = [DateTime]::Now
            foreach ($item in @($stateStore.Rows)) {
                if ($item.PSObject.Properties['RetryAt'] -and $item.RetryAt -and $item.RetryAt -le $now) {
                    $item.RetryAt = $null
                    $item.Pending = $true
                }
            }
        } finally { Exit-WuuStateLock -Store $stateStore }
    }
    $pendingItems = @($stateStore.Rows | Where-Object { $_.Pending })
    foreach ($item in $pendingItems) {
        if ($jobs.Count -ge $MaxConcurrentJobs) { break }
        if (-not (Test-PhaseReady -Phase $item.Phase)) {
            if ($item.Status -notlike 'Waiting for previous phase*') {
                # GATED (M-1) - the phase-wait display write is shared row state.
                $waitGateHeld = Enter-WuuStateLock -Store $stateStore
                if ($waitGateHeld) {
                    try {
                        $item.Status = "Waiting for previous phase to complete. Current phase: $($item.Phase)"
                        if ($item.PSObject.Properties['State']) { $item.State = 'Queued' }
                    } finally { Exit-WuuStateLock -Store $stateStore }
                }
                $stateStore.Touch()
            }
            continue
        }
        # CONSUME THE ONE-SLOT QUEUE UNDER THE GATE (M-1). This read-and-clear is exactly the side of the
        # `Set-WuuPendingOperation` race: a payload queuing a follow-up from its own thread must not be
        # able to interleave between reading the op and clearing the slot, or the operator's queued
        # request is lost. Released BEFORE Start-UpdateCheckJob, which takes the submission lock and the
        # state gate itself - nesting them would invert the lock order.
        $op = 'Check'
        $consumeGateHeld = Enter-WuuStateLock -Store $stateStore
        if ($consumeGateHeld) {
            try {
                $item.Pending = $false
                # Consume and clear any queued follow-up op so this item starts the right chain.
                if ($item.PSObject.Properties['PendingOp'] -and $item.PendingOp) {
                    $op = $item.PendingOp
                    $item.PendingOp = $null
                }
            } finally { Exit-WuuStateLock -Store $stateStore }
        }
        # RE-ARM ON REFUSAL (D14 follow-up). A refusal is recoverable and means "not yet", not
        # "never": the tick must put the request back so the NEXT tick retries it. Without this the
        # follow-up was consumed and lost - e.g. the auto-install tail queues 'InstallAndRecheck'
        # while the download is still Running, the next tick clears it, admission refuses because the
        # row is busy, and the install silently never ran. The refusal record makes a permanently
        # refused row visible to the phase gate instead of an invisible stall.
        $stateStore.Touch()
        $admitted = Start-UpdateCheckJob -ComputerItem $item -Op $op
        if (-not $admitted) {
            # GATED (M-1) - the re-arm restores shared queue state.
            $rearmGateHeld = Enter-WuuStateLock -Store $stateStore
            if ($rearmGateHeld) {
                try {
                    if ($item.PSObject.Properties['Pending']) { $item.Pending = $true }
                    if ($item.PSObject.Properties['PendingOp'] -and $op -ne 'Check') { $item.PendingOp = $op }
                } finally { Exit-WuuStateLock -Store $stateStore }
            }
            $stateStore.Touch()
        }
    }
}

function Test-PhaseCompletion {
    param([string]$Phase)
    # SOURCE FROM THE ENGINE STORE (T006.1) - the ListView holds detached view rows, so phase gating
    # read against it would see no computers and report every phase complete.
    $stateStore = $script:WuuCtx.StateStore
    if (-not $stateStore) { try { $stateStore = $global:stateStore } catch { $stateStore = $null } }
    $phaseComputers = @()
    if ($stateStore) { $phaseComputers = @($stateStore.Rows | Where-Object { $_.Phase -eq $Phase }) }
    
    if ($phaseComputers.Count -eq 0) {
        return $true  # No computers in this phase, consider it complete
    }

    # READ THE CONFIGURED FAILURE POLICY (SS9 / review M-4). This loop used to SKIP errored/timed-out
    # rows unconditionally, i.e. it always behaved as ContinueOnFailure - the UNSAFE option - while the
    # store defaulted to BlockOnFailure. A failed canary therefore silently permitted the next phase, and
    # the setting was inert. The policy now decides.
    $policy = 'BlockOnFailure'
    try {
        if ($stateStore -and $stateStore.Settings -and $stateStore.Settings['PhaseFailurePolicy']) {
            $policy = [string]$stateStore.Settings['PhaseFailurePolicy']
        }
    } catch { $policy = 'BlockOnFailure' }

    foreach ($computer in $phaseComputers) {
        # A settled FAILED/TIMED-OUT row: does it block the next phase? The policy answers; an unknown
        # policy blocks (Test-WuuPhaseFailureBlocks is fail-safe). A settled failure that does NOT block
        # is SKIPPED - not treated as outstanding work, which is the bug that made "settled but failed"
        # look like "still to do" and blocked the phase for ever.
        $settledBad = ($computer.UpdatesStatus -eq 'Error' -or $computer.UpdatesStatus -eq 'Timeout' -or
                       $computer.State -eq 'Error' -or $computer.State -eq 'Timeout')
        if ($settledBad) {
            if (Test-WuuPhaseFailureBlocks -Row $computer -Policy $policy) { return $false }
            continue
        }
        # Not yet checked (queued for the job scheduler)
        if ($computer.Pending) {
            return $false
        }
        if ($computer.Available -gt 0 -or $computer.Downloaded -gt 0 -or $computer.RebootRequired -or $computer.UpdatesStatus -ne 'All updates installed') {
            return $false
        }
    }
    
    return $true
}

function Get-NextAvailablePhase {
    $maxPhase = 5
    for ($phase = 1; $phase -le $maxPhase; $phase++) {
        $phaseComplete = Test-PhaseCompletion -Phase "Phase $phase"
        if (-not $phaseComplete) {
            return $phase
        }
    }
    return $null  # All phases complete
}

function Test-PhaseReady {
    param([string]$Phase)
    
    if ($Phase -eq "Phase 1") {
        return $true  # Phase 1 is always ready
    }
    
    # Check if previous phase is complete
    $phaseNumber = [int]($Phase -replace "Phase ", "")
    $previousPhase = "Phase $($phaseNumber - 1)"
    
    return Test-PhaseCompletion -Phase $previousPhase
}

Export-ModuleMember -Function @('Initialize-WuuWindowsUpdateContext','New-ComputerRunspace','Start-UpdateCheckJob','Start-PendingUpdateCheck','Test-PhaseCompletion','Get-NextAvailablePhase','Test-PhaseReady')

