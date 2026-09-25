#Requires -Version 5.1
<#
.DESCRIPTION
Remote performance sampling and bounded remote COM operations.
#>

function Invoke-RemoteComWithTimeout {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,
        
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock,
        
        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 30
    )
    
    # Pool-based bounded execution (was Start-Job - one child process per call).
    # Callers consume the 'Output' key (3 sites in Wuu.Core.psm1: eventShowInstalledUpdates,
    # eventAuditWSUSUpdates, eventShowUpdateHistory) - contract preserved exactly.
    # WUA COM safety: callers project COM results to PSCustomObject INSIDE the
    # scriptblock, so no live COM interface ever crosses the runspace boundary.
    try {
        $result = Invoke-WithPoolTimeout -ScriptBlock $ScriptBlock `
            -ArgumentList $ComputerName -TimeoutSeconds $TimeoutSeconds `
            -OperationName 'Remote COM operation'
        
        if ($result.Success) {
            return @{ Success = $true; Output = $result.Result }
        } else {
            return @{ Success = $false; Error = $result.Error }
        }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Get-SystemPerformance {
    param([string]$ComputerName)
    try {
        # Use pool-bounded CIM queries to avoid unbounded hangs on unresponsive hosts.
        # $global:PerformanceTimeoutSeconds is set by Wuu.Core config (default 60).
        $timeoutSec = if ($global:PerformanceTimeoutSeconds) { $global:PerformanceTimeoutSeconds } else { 60 }

        $perfScript = {
            param($TargetComputer)
            $result = @{
                CPUPercent = 0
                MemoryUsedMB = 0
                Success = $false
                Error = $null
            }
            try {
                if ($TargetComputer -eq 'localhost' -or $TargetComputer -eq $env:COMPUTERNAME) {
                    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop |
                           Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average
                    $memory = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                    $result.CPUPercent = $cpu
                    $result.MemoryUsedMB = [math]::Round(($memory.TotalVisibleMemorySize - $memory.FreePhysicalMemory) / 1024, 2)
                    $result.Success = $true
                } else {
                    # Get credentials inside the pool so the runspace inherits them
                    $credential = Get-RemoteCredentials -ComputerName $TargetComputer -Operation 'performance monitoring'
                    $sessionOpts = New-CimSessionOption -Protocol DCOM
                    $cimSession = $null
                    try {
                        if ($credential) {
                            $cimSession = New-CimSession -ComputerName $TargetComputer -SessionOption $sessionOpts -Credential $credential -ErrorAction Stop
                        } else {
                            $cimSession = New-CimSession -ComputerName $TargetComputer -SessionOption $sessionOpts -ErrorAction Stop
                        }

                        $cpu = Get-CimInstance -CimSession $cimSession -ClassName Win32_Processor -ErrorAction Stop |
                               Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average
                        $memory = Get-CimInstance -CimSession $cimSession -ClassName Win32_OperatingSystem -ErrorAction Stop
                        $result.CPUPercent = $cpu
                        $result.MemoryUsedMB = [math]::Round(($memory.TotalVisibleMemorySize - $memory.FreePhysicalMemory) / 1024, 2)
                        $result.Success = $true
                    } finally {
                        if ($cimSession) { Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue }
                    }
                }
            } catch {
                $result.Error = $_.Exception.Message
            }
            return $result
        }

        $invocation = Invoke-WithPoolTimeout -ScriptBlock $perfScript -ArgumentList $ComputerName -TimeoutSeconds $timeoutSec -OperationName "Perf query $ComputerName"

        if (-not $invocation.Success) {
            return @{
                CPUPercent = 0
                MemoryUsedMB = 0
                NetworkLatencyMs = 9999
                Status = if ($invocation.Error -match 'timed out') {
                    "Timeout: Performance query exceeded ${timeoutSec}s on $ComputerName"
                } else {
                    "Error: $($invocation.Error)"
                }
            }
        }

        $perfResult = $invocation.Result
        if (-not $perfResult.Success) {
            return @{
                CPUPercent = 0
                MemoryUsedMB = 0
                NetworkLatencyMs = 9999
                Status = "Error: $($perfResult.Error)"
            }
        }

        $ping = Test-Connection -ComputerName $ComputerName -Count 1 -ErrorAction Stop
        $latency = $ping.ResponseTime

        return @{
            CPUPercent = $perfResult.CPUPercent
            MemoryUsedMB = $perfResult.MemoryUsedMB
            NetworkLatencyMs = $latency
            Status = 'Success'
        }
    } catch {
        return @{
            CPUPercent = 0
            MemoryUsedMB = 0
            NetworkLatencyMs = 9999
            Status = "Error: $($_.Exception.Message)"
        }
    }
}

Export-ModuleMember -Function @('Invoke-RemoteComWithTimeout', 'Get-SystemPerformance')

