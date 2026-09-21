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
        $cimResult = Invoke-WithPoolTimeout -ScriptBlock {
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
        } -ArgumentList @($ComputerName, $ClassName, $Credential) -TimeoutSeconds $TimeoutSeconds -OperationName $Operation
        
        if ($cimResult.Success) {
            return @{ Success = $true; Result = $cimResult.Result }
        } else {
            return @{ Success = $false; Error = $cimResult.Error }
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

Export-ModuleMember -Function @('Invoke-CimWithTimeout', 'Invoke-ServiceWithTimeout', 'Test-SystemDependencies', 'Invoke-WithTimeout')

