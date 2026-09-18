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
    
    $cimJob = $null
    
    try {
        $cimJob = Start-Job -ScriptBlock {
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
                return @{ Success = $false; Error = $_.Exception.Message }
            } finally {
                if ($cimSession) { Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue }
            }
        } -ArgumentList $ComputerName, $ClassName, $Credential
        
        $jobCompleted = Wait-Job -Job $cimJob -Timeout $TimeoutSeconds
        if ($jobCompleted) {
            $cimResult = Receive-Job -Job $cimJob
            if ($cimResult -and $cimResult.Success) {
                return @{ Success = $true; Result = $cimResult.Result }
            } else {
                $errorMsg = if ($cimResult -and $cimResult.Error) { $cimResult.Error } else { 'Unknown error' }
                return @{ Success = $false; Error = $errorMsg }
            }
        } else {
            return @{ Success = $false; Error = "$Operation timed out after $TimeoutSeconds seconds" }
        }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    } finally {
        if ($cimJob) {
            Remove-Job -Job $cimJob -Force -ErrorAction SilentlyContinue
        }
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
    
    $serviceJob = $null
    
    try {
        $serviceJob = Start-Job -ScriptBlock {
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
        } -ArgumentList $ComputerName, $ServiceName, $Action, $PostActionDelay
        
        $jobCompleted = Wait-Job -Job $serviceJob -Timeout $TimeoutSeconds
        if ($jobCompleted) {
            $serviceResult = Receive-Job -Job $serviceJob
            if ($serviceResult) {
                return $serviceResult
            } else {
                return @{ Success = $false; Error = 'No result returned from job' }
            }
        } else {
            return @{ Success = $false; Error = "Service $Action timed out after $TimeoutSeconds seconds" }
        }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    } finally {
        if ($serviceJob) {
            Remove-Job -Job $serviceJob -Force -ErrorAction SilentlyContinue
        }
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
        $rpcTest = $null
        $rpcJob = Start-Job -ScriptBlock { 
            param($comp, [bool]$useDomainCreds, [PSCredential]$altCreds, [hashtable]$credCache)
            
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
            
            # Check if we have cached credentials for this computer
            if ($credCache.ContainsKey($comp)) {
                $result = Test-RemoteCredentials -computerName $comp -credential $credCache[$comp]
                if ($result) { return $result }
            }
            
            # Try domain credentials first
            if ($useDomainCreds) {
                $result = Test-RemoteCredentials -computerName $comp -credential $null
                if ($result) { return $result }
            }
            
            # Try alternate credentials if available
            if ($altCreds) {
                $result = Test-RemoteCredentials -computerName $comp -credential $altCreds
                if ($result) { return $result }
            }
            
            return $null
        } -ArgumentList $ComputerName, $script:UseDomainCredentials, $script:AlternateCredentials, $global:CredentialCache
        if (Wait-Job -Job $rpcJob -Timeout 10) {
            $rpcTest = Receive-Job -Job $rpcJob
            if ($rpcTest) {
                $dependencies['RPC'] = $true
            }
        }
        Remove-Job -Job $rpcJob -Force -ErrorAction SilentlyContinue
        
        # Test services with timeout
        if ($dependencies['RPC']) {
            $serviceJob = Start-Job -ScriptBlock { 
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
            } -ArgumentList $ComputerName
            
            if (Wait-Job -Job $serviceJob -Timeout 10) {
                $services = Receive-Job -Job $serviceJob
                if ($services) {
                    $wuService = $services | Where-Object { $_.Name -eq 'wuauserv' }
                    $regService = $services | Where-Object { $_.Name -eq 'RemoteRegistry' }
                    
                    $dependencies['WindowsUpdate'] = $wuService -and $wuService.Status -eq 'Running'
                    $dependencies['RemoteRegistry'] = $regService -and $regService.Status -eq 'Running'
                }
            }
            Remove-Job -Job $serviceJob -Force -ErrorAction SilentlyContinue
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
        $job = if ($ArgumentList) {
            Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
        } else {
            Start-Job -ScriptBlock $ScriptBlock
        }
        
        $completed = $false
        $timeoutCounter = 0
        
        while (-not $completed -and $timeoutCounter -lt $TimeoutSeconds) {
            if ($job.State -eq 'Completed') {
                $result = Receive-Job -Job $job
                $completed = $true
                Remove-Job -Job $job -Force
                return @{ Success = $true; Result = $result; Error = $null }
            } elseif ($job.State -eq 'Failed') {
                $jobError = Receive-Job -Job $job 2>&1
                Remove-Job -Job $job -Force
                return @{ Success = $false; Result = $null; Error = "$OperationName failed: $($jobError | Out-String)" }
            } else {
                Start-Sleep -Seconds 2
                $timeoutCounter += 2
            }
        }
        
        # Timeout occurred
        Remove-Job -Job $job -Force
        return @{ Success = $false; Result = $null; Error = "$OperationName timed out after $($TimeoutSeconds/60) minutes" }
        
    } catch {
        return @{ Success = $false; Result = $null; Error = "$OperationName error: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function @('Invoke-CimWithTimeout', 'Invoke-ServiceWithTimeout', 'Test-SystemDependencies', 'Invoke-WithTimeout')

