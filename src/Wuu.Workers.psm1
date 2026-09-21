#Requires -Version 5.1
<#
.DESCRIPTION
Bounded remote operations executed on a module-scoped runspace pool.

Replaces the per-call create/wait/receive/destroy pattern:
    $job = Start-Job ... ; Wait-Job -Timeout ... ; Receive-Job ... ; Remove-Job ...
which spawns a full child PowerShell process (its own runspace, profile-less
but heavyweight) for EVERY bounded probe. The pool pays that cost once: worker
runspaces are created lazily on first use and reused across operations.

Threading model mirrors New-ComputerRunspace (Wuu.WindowsUpdate.psm1):
    InitialSessionState::CreateDefault(), STA, UseNewThread.

All public helpers return @{ Success = <bool>; Result = <object>; Error = <string> }.
Result/Error may be $null when Success is $true/$false respectively - callers
already follow this convention (see Invoke-CimWithTimeout callers).

PowerShell 5.1 compatibility notes:
- No ForEach-Object -Parallel (PS7+). Pools + BeginInvoke/EndInvoke only.
- RunspacePool max is clamped by MAX_POOL_SIZE; PS 5.1 has no MinRunspaces=0
  lazy option, so MinRunspaces=2 keeps cold-start cost bounded.

IMPORTANT: never route Windows Update COM (WUA) objects through this pool.
Those objects carry live COM interfaces that cannot cross runspace/process
boundaries - WUA work stays in the per-computer runspaces in
Wuu.WindowsUpdate.psm1 (see the Start-Job note at Wuu.Core.psm1 ~line 1749).
This pool is for bounded remote WMI/CIM/service/ping/network operations only.
#>

# --- Pool configuration -----------------------------------------------------
# MAX_POOL_SIZE bounds concurrency of bounded probes. These run INSIDE
# per-computer worker runspaces (up to $MaxConcurrentJobs), so pool capacity
# must comfortably exceed it to avoid starving workers; 8 was chosen to
# throttle per-machine child-process count while staying cheap in-memory.
# $MaxConcurrentJobs default is 10; if a deployment raises it, raise this too.
# The pool is created LAZILY on first use (Get-WuuWorkerPool) so import cost
# stays zero until the first bounded probe actually runs.
[int]$script:MaxPoolSize = 8
[int]$script:MinPoolSize = 2

# --- Pool state (module scope) ----------------------------------------------
$script:WorkerPool = $null
# Abandoned wrappers from uninterruptible-timeout paths (see Invoke-WithPoolTimeout).
# Kept referenced so the GC finalizer - which calls Stop() and could block a
# finalizer thread - never runs while a pipeline is still stuck.
$script:Abandoned = $null

function Initialize-WuuWorkerPool {
    <#
    .SYNOPSIS
    Creates the module-scoped runspace pool. Idempotent: an open pool is reused.
    #>
    if ($script:WorkerPool -and $script:WorkerPool.RunspacePoolStateInfo.State -eq 'Opened') {
        return $script:WorkerPool
    }
    if ($script:WorkerPool) {
        # Previous pool exists but is broken/closed - discard and rebuild
        try { $script:WorkerPool.Dispose() } catch { }
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    # PS 5.1 has no (min, max, ISS) overload; the verified working recipe is
    # the 4-arg overload with the LIVE $host (probed 2026-09-21: null host is
    # rejected, InitialSessionState property is read-only after construction).
    $pool = [runspacefactory]::CreateRunspacePool($script:MinPoolSize, $script:MaxPoolSize, $iss, $host)
    $pool.ApartmentState = 'STA'
    $pool.Open()
    $script:WorkerPool = $pool
    return $pool
}

function Get-WuuWorkerPool {
    <#
    .SYNOPSIS
    Returns the module-scoped pool, creating it on first use.
    #>
    if (-not $script:WorkerPool -or $script:WorkerPool.RunspacePoolStateInfo.State -ne 'Opened') {
        return (Initialize-WuuWorkerPool)
    }
    return $script:WorkerPool
}

function Invoke-WithPoolTimeout {
    <#
    .SYNOPSIS
    Executes a scriptblock on the shared worker pool with a hard timeout.
    .DESCRIPTION
    The pool equivalent of the Start-Job/Wait-Job/Receive-Job/Remove-Job dance.
    Returns @{ Success; Result; Error }. On timeout the PowerShell instance is
    stopped (the runspace survives and returns to the pool - its pipeline is
    aborted, which is the same guarantee Remove-Job -Force gave us).
    .NOTES
    A pooled runspace keeps session state between invocations. That means
    variables leaked by an earlier ScriptBlock (e.g. $cimSession from a CIM
    probe) PERSIST in that runspace until it is disposed. The ScriptBlocks
    passed here must therefore be self-cleaning: create resources in try/finally
    with Remove-* / Dispose calls (the existing helpers already do this - see
    Invoke-CimWithTimeout's finally { Remove-CimSession }).
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory=$false)]
        [object]$ArgumentList = $null,

        [Parameter(Mandatory=$false)]
        [int]$TimeoutSeconds = 300,

        [Parameter(Mandatory=$false)]
        [string]$OperationName = 'Pooled operation'
    )

    $ps = $null
    $abandoned = $false
    try {
        $pool = Get-WuuWorkerPool
        $ps = [powershell]::Create()
        # CRITICAL: bind the instance to the pool BEFORE BeginInvoke - without
        # this line it spins up its own private runspace and the pool silently
        # does nothing.
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($ScriptBlock)
        if ($null -ne $ArgumentList) {
            # Positional binding, mirroring Start-Job -ArgumentList semantics:
            # array -> one parameter per element; scalar -> single parameter.
            $argItems = if ($ArgumentList -is [array]) { $ArgumentList } else { @($ArgumentList) }
            foreach ($arg in $argItems) { [void]$ps.AddArgument($arg) }
        }

        $handle = $ps.BeginInvoke()

        $completed = $handle.AsyncWaitHandle.WaitOne([System.TimeSpan]::FromSeconds($TimeoutSeconds))
        if ($completed) {
            $result = $ps.EndInvoke($handle)
            # PSDataCollection flattening: 0 -> $null, 1 -> the item, N -> keep collection
            $resultValue = if ($result.Count -eq 1) { $result[0] } elseif ($result.Count -eq 0) { $null } else { $result }
            return @{ Success = $true; Result = $resultValue; Error = $null }
        }

        # Hard timeout. The old Start-Job pattern killed the whole child process
        # (Remove-Job -Force) - instant, guaranteed reclamation. In-process we
        # cannot kill a thread, so: request a bounded stop, and if the pipeline
        # refuses to abort (black-holed DCOM/RPC call), ABANDON the wrapper
        # instead of blocking. The caller still gets its timeout error exactly
        # as before; the busy runspace frees itself whenever the OS call returns
        # and pool capacity shrinks by one in the meantime (8 >> 0, graceful).
        $stopHandle = $ps.BeginStop($null, $null)
        if ($stopHandle.AsyncWaitHandle.WaitOne([System.TimeSpan]::FromSeconds(10))) {
            try { $ps.EndStop($stopHandle) } catch { }
        } else {
            $abandoned = $true
            if (-not $script:Abandoned) { $script:Abandoned = [System.Collections.Generic.List[object]]::new() }
            $script:Abandoned.Add($ps)
            if ($script:Abandoned.Count -gt 32) { $script:Abandoned.RemoveAt(0) }
        }
        return @{ Success = $false; Result = $null; Error = "$OperationName timed out after $TimeoutSeconds seconds" }
    } catch {
        return @{ Success = $false; Result = $null; Error = "$OperationName error: $($_.Exception.Message)" }
    } finally {
        # Disposing a still-running instance calls Stop() synchronously - the
        # exact block we must avoid - so never dispose an abandoned wrapper.
        if ($ps -and -not $abandoned) { $ps.Dispose() }
    }
}

function Close-WuuWorkerPool {
    <#
    .SYNOPSIS
    Tears down the pool (app shutdown / tests). Safe to call repeatedly.
    #>
    if ($script:WorkerPool) {
        try {
            if ($script:WorkerPool.RunspacePoolStateInfo.State -eq 'Opened') {
                $script:WorkerPool.Close()
            }
            $script:WorkerPool.Dispose()
        } catch { }
        $script:WorkerPool = $null
    }
}

function New-PooledInvokeScript {
    <#
    .SYNOPSIS
    Returns an unbound scriptblock for injection into isolated per-computer
    runspaces (New-ComputerRunspace), mirroring Invoke-WithPoolTimeout.
    .DESCRIPTION
    Isolated runspaces have default session state - they cannot resolve this
    module's functions ("command not found"). Inject this script and the pool
    OBJECT (as $WuuWorkerPool) via SessionStateProxy.SetVariable, then call:
        & $InvokePooledScript -Pool $WuuWorkerPool -ScriptBlock {...} `
            -ArgumentList @($ComputerName) -TimeoutSeconds 5 -OperationName '...'
    Returns @{ Success; Result; Error } identical to Invoke-WithPoolTimeout.
    #>
    return [scriptblock]::Create(@'
param($Pool, $ScriptBlock, $ArgumentList, $TimeoutSeconds, $OperationName)
$ps = $null
$abandoned = $false
try {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Pool
    [void]$ps.AddScript($ScriptBlock)
    if ($null -ne $ArgumentList) {
        $argItems = if ($ArgumentList -is [array]) { $ArgumentList } else { @($ArgumentList) }
        foreach ($arg in $argItems) { [void]$ps.AddArgument($arg) }
    }
    $handle = $ps.BeginInvoke()
    if ($handle.AsyncWaitHandle.WaitOne([System.TimeSpan]::FromSeconds($TimeoutSeconds))) {
        $result = $ps.EndInvoke($handle)
        $resultValue = if ($result.Count -eq 1) { $result[0] } elseif ($result.Count -eq 0) { $null } else { $result }
        return @{ Success = $true; Result = $resultValue; Error = $null }
    }
    $stopHandle = $ps.BeginStop($null, $null)
    if ($stopHandle.AsyncWaitHandle.WaitOne([System.TimeSpan]::FromSeconds(10))) {
        try { $ps.EndStop($stopHandle) } catch { }
    } else {
        # Uninterruptible native call: abandon the wrapper; keep a reference
        # per-runspace so the GC finalizer never blocks on Stop().
        $abandoned = $true
        $script:AbandonedPoolWrappers = @($script:AbandonedPoolWrappers) + @($ps)
        if ($script:AbandonedPoolWrappers.Count -gt 32) {
            $script:AbandonedPoolWrappers = $script:AbandonedPoolWrappers[-32..-1]
        }
    }
    return @{ Success = $false; Result = $null; Error = "$OperationName timed out after $TimeoutSeconds seconds" }
} catch {
    return @{ Success = $false; Result = $null; Error = "$OperationName error: $($_.Exception.Message)" }
} finally {
    if ($ps -and -not $abandoned) { $ps.Dispose() }
}
'@)
}

function Test-WuuWorkerPool {
    <#
    .SYNOPSIS
    Self-check: verifies bounded success AND bounded timeout. Returns $true
    when both behave. Used by tests/Test-WorkerPool.ps1 and Validate-Release.
    #>
    try {
        $ok = Invoke-WithPoolTimeout -ScriptBlock { param($n) Start-Sleep -Milliseconds 200; "ok-$n" } `
            -ArgumentList 42 -TimeoutSeconds 10 -OperationName 'Pool self-check'
        if (-not $ok.Success -or $ok.Result -ne 'ok-42') { return $false }

        $slow = Invoke-WithPoolTimeout -ScriptBlock { Start-Sleep -Seconds 30 } `
            -TimeoutSeconds 1 -OperationName 'Pool timeout-check'
        if ($slow.Success) { return $false }
        if ($slow.Error -notlike '*timed out*') { return $false }
        return $true
    } catch {
        return $false
    }
}

Export-ModuleMember -Function @(
    'Initialize-WuuWorkerPool',
    'Get-WuuWorkerPool',
    'Invoke-WithPoolTimeout',
    'Close-WuuWorkerPool',
    'New-PooledInvokeScript',
    'Test-WuuWorkerPool'
)