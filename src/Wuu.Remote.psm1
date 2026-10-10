#Requires -Version 5.1
<#
.DESCRIPTION
Bounded remote WMI/CIM and service operations with hard timeouts.
#>

function Invoke-CimWithTimeout {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,
        
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$ClassName = 'Win32_ComputerSystem',
        
        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 5,
        
        [Parameter(Mandatory=$false)]
        [PSCredential]$Credential = $null,
        
        [Parameter(Mandatory=$false)]
        [string]$Operation = 'CIM operation'
    )
    
    try {
        # Pool-based bounded execution (was Start-Job - one child process per probe).
        # The inner scriptblock is UNCHANGED: DCOM session logic and [pscredential]
        # typing preserved exactly - only the bounding mechanism is replaced.
        #
        # Captured as $poolResult, NOT $cimResult: the pool envelope and the inner result are two
        # different objects, and the unwrap block below reads BOTH. Assigning the envelope to
        # $cimResult and then resetting $cimResult to $null (to unwrap) left the envelope unreadable
        # and made EVERY probe - including the localhost happy path - return 'no result'.
        $poolResult = Invoke-WithPoolTimeout -ScriptBlock {
            # $Cred is always a PSCredential (or $null for default credentials) -
            # typed so a plain-string password can never be passed as a credential.
            # NOTE: PS 5.1's Get-CimInstance has NO -Credential parameter; alternate
            # credentials must go through New-CimSession (DCOM to match the old
            # Get-WmiObject behavior) and Get-CimInstance -CimSession.
            # DCOM for BOTH paths: Get-CimInstance -ComputerName implies WinRM/WSMAN, which
            # fails on hosts without a WinRM listener even though DCOM/WMI works (legacy
            # Get-WmiObject used DCOM) - such hosts were misreported as WMI timeouts.
            param([string]$ComputerName, [string]$ClassName, [pscredential]$Cred)
            $cimSession = $null
            try {
                $sessionArgs = @{ ComputerName = $ComputerName; SessionOption = (New-CimSessionOption -Protocol DCOM) }
                if ($Cred) { $sessionArgs['Credential'] = $Cred }
                $cimSession = New-CimSession @sessionArgs -ErrorAction Stop
                $result = Get-CimInstance -CimSession $cimSession -ClassName $ClassName -ErrorAction Stop
                return @{ Success = $true; Result = $result }
            } catch {
                # CAPTURE THE MACHINE-READABLE CODE (D10). `$_.Exception.Message` alone is a LOCALIZED
                # string, so the recovery branch downstream could only have matched English text.
                # HResult / FullyQualifiedErrorId survive localization, so they are carried out of the
                # worker instead. The -2146233088 (0x80131500, COR_E_EXCEPTION) value is a generic
                # PowerShell wrapper HRESULT with no diagnostic meaning - it is ignored rather than
                # allowed to masquerade as an RPC code.
                $errId = if ($_.FullyQualifiedErrorId) { [string]$_.FullyQualifiedErrorId } else { '' }
                $hres = $null
                if ($errId -match '0x([0-9A-Fa-f]{8})') {
                    try { $hres = [Convert]::ToInt32($matches[1], 16) } catch { }
                } elseif ($_.Exception -and $_.Exception.HResult -and $_.Exception.HResult -ne -2146233088) {
                    $hres = [int]$_.Exception.HResult
                }
                return @{
                    Success = $false
                    Error   = $_.Exception.Message
                    HResult = $hres
                    ErrorId = $errId
                }
            } finally {
                if ($cimSession) { Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue }
            }
        } -ArgumentList @($ComputerName, $ClassName, $Credential) -TimeoutSeconds $TimeoutSeconds -OperationName $Operation
        
        # ---------------------------------------------------------------------------------------
        # UNWRAP THE POOL WRAPPER (defect fix, verified 2026-10-06).
        #
        # Invoke-WithPoolTimeout returns @{ Success; Result; Error } where Success means "THE
        # SCRIPTBLOCK RAN TO COMPLETION", not "the CIM call succeeded". The scriptblock above
        # deliberately CATCHES its own errors and returns @{ Success = $false; Error = ... }, so on
        # failure the pool wrapper is Success=$true with the failure nested one level down.
        #
        # Reading the wrapper's Success (as this function previously did) therefore reported EVERY
        # FAILED PROBE AND EVERY FAILED AUTHENTICATION AS A SUCCESS. Verified by probe against a
        # name that cannot resolve: Success=$true, Error='', while the real cause ('The RPC server is
        # unavailable') sat in Result.Error. That silently defeated every caller that branches on
        # .Success - most importantly credential verification, which could therefore never fail and
        # so could never enforce the "no fallback to another identity" rule (R04).
        #
        # The inner result is now the authority. A wrapper failure (timeout, terminated pipeline) or
        # an unexpected shape is a failure with the wrapper's reason.
        # ---------------------------------------------------------------------------------------
        $cimResult = $null
        if ($poolResult -and $poolResult.Success -and $poolResult.Result -is [System.Collections.IDictionary]) {
            $cimResult = $poolResult.Result
        }
        if ($null -eq $cimResult) {
            $wrapperError = 'the CIM probe returned no result'
            if ($poolResult -and $poolResult.Error) { $wrapperError = [string]$poolResult.Error }
            return @{ Success = $false; Error = $wrapperError }
        }
        
        if ($cimResult.Success) {
            return @{ Success = $true; Result = $cimResult.Result }
        } else {
            # -----------------------------------------------------------------------------------
            # RECOVERY HOOK FOR RPC-CLASS ERRORS (D10).
            #
            # Previously this branch matched an `0x…` HRESULT out of the ERROR MESSAGE TEXT. On a
            # genuine failure the message is a LOCALIZED sentence ('The RPC server is unavailable.',
            # measured) with no hex code in it, so `$hresult` stayed $null and the branch could never
            # fire - and the call it guards, `Invoke-AutoRecovery`, was neither exported nor reachable
            # from this module anyway.
            #
            # The code now comes from the structured fields the worker returns (HResult, then
            # ErrorId), falling back to the message only for legacy/shaped messages. The localized
            # sentence cannot be relied on, so it is deliberately NOT the primary signal; it is kept
            # as a last resort because dropping it would make an already-narrow branch narrower.
            # -----------------------------------------------------------------------------------
            $errorMsg = $cimResult.Error
            $errorId = if ($cimResult.PSObject.Properties['ErrorId']) { [string]$cimResult.ErrorId } else { '' }
            $hresult = $null
            if ($cimResult.PSObject.Properties['HResult'] -and $cimResult.HResult) {
                $hresult = [int]$cimResult.HResult
            }
            if (-not $hresult -and $cimResult.PSObject.Properties['ErrorId'] -and $cimResult.ErrorId -match '0x([0-9A-Fa-f]{8})') {
                try { $hresult = [Convert]::ToInt32($matches[1], 16) } catch { }
            }
            if (-not $hresult -and $errorMsg -match '0x([0-9A-Fa-f]{8})') {
                try { $hresult = [Convert]::ToInt32($matches[1], 16) } catch { }
            }
            if (-not $hresult) {
                if ($errorMsg -match 'RPC server is unavailable') { $hresult = 0x800706ba }
                elseif ($errorMsg -match 'RPC.*?failed') { $hresult = 0x800706be }
            }
            if ($hresult -eq 0x800706ba -or $hresult -eq 0x800706be) {
                try {
                    $errCode = if ($hresult -eq 0x800706ba) { '800706ba' } else { '800706be' }
                    $recoverySucceeded = Invoke-AutoRecovery -ComputerName $ComputerName -ErrorCode $errCode -ErrorAction SilentlyContinue
                    if ($recoverySucceeded) {
                        Start-Sleep -Seconds 2   # brief pause before retry
                        # Retry once after recovery
                        $retryResult = Invoke-WithPoolTimeout -ScriptBlock {
                            param([string]$ComputerName, [string]$ClassName, [pscredential]$Cred)
                            $cimSession = $null
                            try {
                                $sessionArgs = @{ ComputerName = $ComputerName; SessionOption = (New-CimSessionOption -Protocol DCOM) }
                                if ($Cred) { $sessionArgs['Credential'] = $Cred }
                                $cimSession = New-CimSession @sessionArgs -ErrorAction Stop
                                $result = Get-CimInstance -CimSession $cimSession -ClassName $ClassName -ErrorAction Stop
                                return @{ Success = $true; Result = $result }
                            } catch {
                                return @{ Success = $false; Error = $_.Exception.Message }
                            } finally {
                                if ($cimSession) { Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue }
                            }
                        } -ArgumentList @($ComputerName, $ClassName, $Credential) -TimeoutSeconds $TimeoutSeconds -OperationName "$Operation (post-recovery retry)"

                        if ($retryResult.Success) {
                            # The retry has the SAME double-envelope shape as the primary attempt: the
                            # wrapper's Success means "the scriptblock ran", and the operation's real
                            # outcome is nested in .Result. Returning $retryResult.Result directly would
                            # re-introduce the original defect on the recovery path - a failed retry
                            # would be reported as Success = $true carrying a failure hashtable.
                            $retryInner = $retryResult.Result
                            if ($retryInner -and $retryInner.Success) {
                                return @{ Success = $true; Result = $retryInner.Result; RecoveredAfterRpcError = $true }
                            }
                            if ($retryInner -and $retryInner.Error) { $errorMsg = $retryInner.Error }
                        } elseif ($retryResult.Error) {
                            $errorMsg = $retryResult.Error
                        }
                        # Fall through to failure if retry also failed
                    }
                } catch {
                    # Recovery itself failed - fall through to original error
                }
            }
            # THE STRUCTURED CODE REACHES THE CALLER, not just the internal recovery branch. A caller
            # that must tell an RPC failure from an access-denied failure should not have to re-parse a
            # localized sentence - that reliance on message text is exactly what this defect was made
            # of. `$hresult` is the numeric code (or $null when none could be determined); `$errorId`
            # preserves the original PowerShell error identity for diagnosis.
            return @{ Success = $false; Error = $errorMsg; HResult = $hresult; ErrorId = $errorId }
        }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Invoke-ServiceWithTimeout {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,
        
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$ServiceName = 'wuauserv',
        
        [Parameter(Mandatory=$false)]
        [ValidateSet('Check', 'Start', 'Stop', 'Restart')]
        [string]$Action = 'Check',
        
        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 5,
        
        [Parameter(Mandatory=$false)]
        [ValidateRange(0, 60)]
        [int]$PostActionDelay = 5
    )
    
    try {
        # Pool-based bounded execution (was Start-Job - one child process per probe).
        # The inner scriptblock is UNCHANGED - only the bounding mechanism is replaced.
        $serviceResult = Invoke-WithPoolTimeout -ScriptBlock {
            param($ComputerName, $ServiceName, $Action, $Delay)
            try {
                $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop
                
                switch ($Action) {
                    'Start' {
                        $service | Start-Service -ErrorAction Stop
                        Start-Sleep -Seconds $Delay
                        $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop
                        $success = ($service.Status -eq 'Running')
                    }
                    'Stop' {
                        $service | Stop-Service -ErrorAction Stop
                        Start-Sleep -Seconds $Delay
                        $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop
                        $success = ($service.Status -eq 'Stopped')
                    }
                    'Restart' {
                        $service | Restart-Service -ErrorAction Stop
                        Start-Sleep -Seconds $Delay
                        $service = Get-Service -Name $ServiceName -ComputerName $ComputerName -ErrorAction Stop
                        $success = ($service.Status -eq 'Running')
                    }
                    default { # Check
                        $success = $true
                    }
                }
                
                if ($service) {
                    return @{ Success = $success; Service = $service; Status = $service.Status }
                } else {
                    return @{ Success = $false; Error = "Service not found or inaccessible" }
                }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            }
        } -ArgumentList @($ComputerName, $ServiceName, $Action, $PostActionDelay) -TimeoutSeconds $TimeoutSeconds -OperationName "Service $Action"
        
        if ($serviceResult.Success) {
            if ($serviceResult.Result) {
                return $serviceResult.Result
            } else {
                return @{ Success = $false; Error = 'No result returned from job' }
            }
        } else {
            return @{ Success = $false; Error = $serviceResult.Error }
        }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Test-SystemDependencies {
    param([string]$ComputerName)
    
    $dependencies = @{
        'RPC' = $false
        'WinRM' = $false
        'WindowsUpdate' = $false
        'RemoteRegistry' = $false
    }
    
    try {
        # Test RPC with timeout and credential handling
        # Pool-based bounded execution (was Start-Job - one child process per probe).
        $rpcResult = Invoke-WithPoolTimeout -ScriptBlock { 
            param($comp, [bool]$useCustomCreds, [PSCredential]$customCreds, [hashtable]$credCache)
            
            # Guard mirrors GetRemoteCredentialsScript: app initializes the cache,
            # but a probe must never crash on a $null cache (crash = false negative).
            if (-not $credCache) { $credCache = @{} }
            
            # Helper function to test credentials
            function Test-RemoteCredentials {
                param([string]$computerName, [PSCredential]$credential)
                try {
                    if ($credential) {
                        $cimSessionOptions = New-CimSessionOption -Protocol DCOM
                        $cimSession = New-CimSession -ComputerName $computerName -SessionOption $cimSessionOptions -Credential $credential -ErrorAction Stop
                        $result = Get-CimInstance -CimSession $cimSession -ClassName Win32_ComputerSystem -ErrorAction Stop
                        Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
                        return $result
                    } else {
                        if ($computerName -eq 'localhost' -or $computerName -eq $env:COMPUTERNAME) {
                            return Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
                        } else {
                            $cimSessionOptions = New-CimSessionOption -Protocol DCOM
                            $cimSession = New-CimSession -ComputerName $computerName -SessionOption $cimSessionOptions -ErrorAction Stop
                            $result = Get-CimInstance -CimSession $cimSession -ClassName Win32_ComputerSystem -ErrorAction Stop
                            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
                            return $result
                        }
                    }
                } catch {
                    return $null
                }
            }
            
            # Credential resolution mirrors GetRemoteCredentialsScript (the app's
            # real model): cache hit -> custom -> default. The old parameter names
            # ($script:UseDomainCredentials/$script:AlternateCredentials) were NEVER
            # defined after the module split - this exported function silently
            # reported RPC unreachable for every machine if anyone called it.
            # Check if we have cached credentials for this computer
            if ($credCache.ContainsKey($comp)) {
                $result = Test-RemoteCredentials -computerName $comp -credential $credCache[$comp]
                if ($result) { return $result }
            }
            
            # Try custom credentials if configured
            if ($useCustomCreds -and $customCreds) {
                $result = Test-RemoteCredentials -computerName $comp -credential $customCreds
                if ($result) { return $result }
            }
            
            # Fall back to default credentials
            $result = Test-RemoteCredentials -computerName $comp -credential $null
            if ($result) { return $result }
            
            return $null
        } -ArgumentList @($ComputerName, [bool]$global:UseCustomCredentials, $global:CustomCredentials, $global:CredentialCache) -TimeoutSeconds 10 -OperationName 'RPC dependency probe'
        if ($rpcResult.Success -and $rpcResult.Result) {
            $dependencies['RPC'] = $true
        }
        
        # Test services with timeout
        if ($dependencies['RPC']) {
            $svcResult = Invoke-WithPoolTimeout -ScriptBlock { 
                param($comp) 
                try {
                    if ($comp -eq 'localhost' -or $comp -eq $env:COMPUTERNAME) {
                        $services = Get-Service -Name 'wuauserv', 'RemoteRegistry' -ErrorAction Stop
                    } else {
                        $services = Invoke-Command -ComputerName $comp -ScriptBlock {
                            Get-Service -Name 'wuauserv', 'RemoteRegistry' -ErrorAction Stop
                        } -ErrorAction Stop
                    }
                    return $services
                } catch {
                    return $null
                }
            } -ArgumentList $ComputerName -TimeoutSeconds 10 -OperationName 'Service dependency check'
            
            $services = if ($svcResult.Success) { $svcResult.Result } else { $null }
            if ($services) {
                $wuService = $services | Where-Object { $_.Name -eq 'wuauserv' }
                $regService = $services | Where-Object { $_.Name -eq 'RemoteRegistry' }
                
                $dependencies['WindowsUpdate'] = $wuService -and $wuService.Status -eq 'Running'
                $dependencies['RemoteRegistry'] = $regService -and $regService.Status -eq 'Running'
            }
        }
        
        return $dependencies
    } catch {
        # Return false dependencies if any error occurs
        return $dependencies
    }
}

function Invoke-WithTimeout {
    param(
        [ScriptBlock]$ScriptBlock,
        [int]$TimeoutSeconds = 300,
        [string]$OperationName = 'Operation',
        [object]$ArgumentList = $null
    )
    
    try {
        # Pool-based bounded execution (was a polled Start-Job loop).
        # No callers in the codebase today, but the contract is preserved
        # exactly in case future code (or the exported name) is used.
        return Invoke-WithPoolTimeout -ScriptBlock $ScriptBlock `
            -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds `
            -OperationName $OperationName
    } catch {
        return @{ Success = $false; Result = $null; Error = "$OperationName error: $($_.Exception.Message)" }
    }
}

function Invoke-WuuRemoteTask {
    <#
    .SYNOPSIS
    Runs a script on a remote computer as SYSTEM via a one-off scheduled task over a DCOM CIM session.
    WUA download/install refuse remote callers, so the work must run on the target.
    The script reports progress/result as JSON in HKLM\SOFTWARE\WUU2\Jobs\<RunId>\State (read via StdRegProv).
    Injected into worker runspaces as text - built-in cmdlets only.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Operation,
        [pscredential]$Credential = $null,
        [scriptblock]$ProgressCallback = $null,
        [int]$TimeoutMinutes = 240,
        [int]$PollSeconds = 5
    )

    $runId = [guid]::NewGuid().ToString('N')
    $taskPath = '\WUU2\'
    $taskName = "WUU2_${Operation}_$runId"
    $jobsKey = 'SOFTWARE\WUU2\Jobs'
    $hklm = [uint32]2147483650
    $cim = $null
    $registered = $false

    $readState = {
        param([string]$Id)
        try {
            $r = Invoke-CimMethod -CimSession $cim -Namespace 'root/default' -ClassName 'StdRegProv' -MethodName 'GetStringValue' `
                -Arguments @{ hDefKey = $hklm; sSubKeyName = "$jobsKey\$Id"; sValueName = 'State' } -ErrorAction Stop
            if ($r.ReturnValue -eq 0 -and $r.sValue) { return ($r.sValue | ConvertFrom-Json) }
        } catch { }
        return $null
    }
    $removeState = {
        param([string]$Id)
        try {
            [void](Invoke-CimMethod -CimSession $cim -Namespace 'root/default' -ClassName 'StdRegProv' -MethodName 'DeleteKey' `
                -Arguments @{ hDefKey = $hklm; sSubKeyName = "$jobsKey\$Id" } -ErrorAction Stop)
        } catch { }
    }

    try {
        $sessionArgs = @{ ComputerName = $ComputerName; SessionOption = (New-CimSessionOption -Protocol Dcom); OperationTimeoutSec = 60 }
        if ($Credential) { $sessionArgs['Credential'] = $Credential }
        $cim = New-CimSession @sessionArgs -ErrorAction Stop

        # Remove leftovers from runs whose controller died (e.g. GUI closed mid-install)
        $orphanCutoff = (Get-Date).AddMinutes(-($TimeoutMinutes + 30))
        foreach ($old in @(Get-ScheduledTask -CimSession $cim -TaskPath $taskPath -ErrorAction SilentlyContinue)) {
            if ($old.State -eq 'Running') { continue }
            $oldInfo = Get-ScheduledTaskInfo -CimSession $cim -TaskName $old.TaskName -TaskPath $taskPath -ErrorAction SilentlyContinue
            if (-not $oldInfo -or -not $oldInfo.LastRunTime -or $oldInfo.LastRunTime -gt $orphanCutoff) { continue }
            Unregister-ScheduledTask -CimSession $cim -TaskName $old.TaskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
            & $removeState ($old.TaskName -replace '^.*_', '')
        }

        $scriptText = "`$RunId = '$runId'`r`n" + (Get-Content -Path $ScriptPath -Raw -ErrorAction Stop)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes $TimeoutMinutes)

        Register-ScheduledTask -CimSession $cim -TaskName $taskName -TaskPath $taskPath -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        $registered = $true
        Start-ScheduledTask -CimSession $cim -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
        $startedAt = Get-Date
        $deadline = $startedAt.AddMinutes($TimeoutMinutes + 5)

        while ($true) {
            Start-Sleep -Seconds $PollSeconds
            $state = & $readState $runId
            if ($state -and $ProgressCallback) { try { $null = & $ProgressCallback $state } catch { } }

            $task = Get-ScheduledTask -CimSession $cim -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
            if ((Get-Date) -gt $deadline) {
                throw "Remote $Operation task on $ComputerName timed out after $TimeoutMinutes minutes"
            }
            if ($task.State -eq 'Running' -or $task.State -eq 'Queued') { continue }

            # 0x41303 = task has not run yet; allow the scheduler a minute to pick it up
            $info = Get-ScheduledTaskInfo -CimSession $cim -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
            if ($info.LastTaskResult -eq 0x41303 -and ((Get-Date) - $startedAt).TotalSeconds -lt 60) { continue }
            break
        }

        $state = & $readState $runId
        $exitCode = [int64]$info.LastTaskResult
        if ($state -and $state.Result -eq 'Success') {
            return @{ Success = $true; Count = [int]$state.Count; Total = [int]$state.Total; RebootRequired = [bool]$state.RebootRequired; ExitCode = $exitCode; Error = $null }
        }
        $errorText = if ($state -and $state.ErrorMessage) { $state.ErrorMessage } else { "Remote $Operation task ended without a result (task result 0x{0:X})" -f $exitCode }
        return @{ Success = $false; Count = 0; Total = 0; RebootRequired = $false; ExitCode = $exitCode; Error = $errorText }
    } finally {
        if ($cim) {
            if ($registered) {
                Unregister-ScheduledTask -CimSession $cim -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
            }
            & $removeState $runId
            Remove-CimSession -CimSession $cim -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-AutoRecovery {
    <#
    .SYNOPSIS
    Attempts automatic recovery for known RPC-class failures (D10).
    .DESCRIPTION
    Restarts RpcSs and starts RemoteRegistry on the target when the error is a known auto-recoverable
    RPC condition (0x800706BA / 0x800706BE).

    WHY THIS COPY EXISTS - IT IS NOT REDUNDANT. Wuu.Core already defines an Invoke-AutoRecovery, and
    the injected payload defines a third one. Neither is reachable from HERE: this module's caller is
    Wuu.Remote's own Invoke-CimWithTimeout, and a module cannot resolve another module's private
    functions. That was the original defect - the call was present, unqualified, and silently
    unreachable via -ErrorAction SilentlyContinue. The module that makes the call must therefore own
    the function. Wuu.Core's copy continues to serve its own direct caller (the interactive
    connectivity loop), which is why it is left alone rather than deleted.

    DIVERGENCE IS DELIBERATE AND DOCUMENTED: the Core copy waits 5s after restarting RpcSs and a
    further 3s before returning; this copy waits 2s. This copy is the one on the automatic probe path,
    where the caller is already bounded by an operation deadline, so a longer sleep would eat the
    budget the retry needs. If the copies are ever unified, that deadline interaction is the thing to
    preserve - not the constant.

    HONEST LIMITATION: recovery is keyed on RPC conditions only. Access-denied (0x80070005) and
    unknown errors return $false without touching the target, so this cannot 'fix' a credentials or
    permissions problem by restarting a service.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        # Accepts an error code, a hex HRESULT, or a message. Normalized before the switch.
        [Parameter(Mandatory = $true)]
        [string]$ErrorCode
    )

    # NORMALIZE FIRST. The caller may pass '800706ba', '0x800706BA', or a whole message. Matching the
    # raw argument in the switch below is what made the CLI's equivalent return $false for every
    # input until its own defect was raised - the switch patterns are bare hex without the 0x prefix.
    $code = $ErrorCode
    if ($ErrorCode -match '0x([0-9A-Fa-f]{8})') {
        $code = $matches[1].ToLowerInvariant()
    } elseif ($ErrorCode -match '\b([0-9A-Fa-f]{8})\b') {
        $code = $matches[1].ToLowerInvariant()
    } elseif ($ErrorCode -match 'RPC server is unavailable') {
        $code = '800706ba'
    } elseif ($ErrorCode -match 'RPC.*?failed') {
        $code = '800706be'
    }

    # Only the two known RPC conditions are auto-recoverable. Everything else is refused here rather
    # than falling through to a service restart.
    if ($code -notin @('800706ba', '800706be')) { return $false }

    try {
        if ($code -eq '800706ba') {
            if ($ComputerName -eq 'localhost' -or $ComputerName -eq $env:COMPUTERNAME -or $ComputerName -eq '127.0.0.1') {
                Get-Service -Name 'RpcSs' -ErrorAction Stop | Restart-Service -ErrorAction Stop
                Start-Sleep -Seconds 2
                Get-Service -Name 'RemoteRegistry' -ErrorAction Stop | Start-Service -ErrorAction Stop
            } else {
                Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                    Get-Service -Name 'RpcSs' -ErrorAction Stop | Restart-Service -ErrorAction Stop
                    Start-Sleep -Seconds 2
                    Get-Service -Name 'RemoteRegistry' -ErrorAction Stop | Start-Service -ErrorAction Stop
                } -ErrorAction Stop
            }
            return $true
        }

        # 800706be (RPC_S_CALL_FAILED) needs a pause for the RPC endpoint to come back, not a restart.
        Start-Sleep -Seconds 5
        return $true
    } catch {
        return $false
    }
}

Export-ModuleMember -Function @('Invoke-CimWithTimeout', 'Invoke-ServiceWithTimeout', 'Test-SystemDependencies', 'Invoke-WithTimeout', 'Invoke-WuuRemoteTask', 'Invoke-AutoRecovery')

