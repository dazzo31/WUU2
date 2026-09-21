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
        # Skip credential handling for local computer
        if ($ComputerName -eq 'localhost' -or $ComputerName -eq $env:COMPUTERNAME) {
            $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | 
                   Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average
            
            $memory = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $memoryUsed = [math]::Round(($memory.TotalVisibleMemorySize - $memory.FreePhysicalMemory) / 1024, 2)
        } else {
            # Get appropriate credentials for remote computer
            $credential = Get-RemoteCredentials -ComputerName $ComputerName -Operation 'performance monitoring'
            
            if ($credential) {
                # Use alternate credentials
                $cimSessionOptions = New-CimSessionOption -Protocol DCOM
                $cimSession = New-CimSession -ComputerName $ComputerName -SessionOption $cimSessionOptions -Credential $credential -ErrorAction Stop
                
                $cpu = Get-CimInstance -CimSession $cimSession -ClassName Win32_Processor -ErrorAction Stop | 
                       Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average
                
                $memory = Get-CimInstance -CimSession $cimSession -ClassName Win32_OperatingSystem -ErrorAction Stop
                $memoryUsed = [math]::Round(($memory.TotalVisibleMemorySize - $memory.FreePhysicalMemory) / 1024, 2)
                
                Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
            } else {
                # Use domain credentials
                $cimSessionOptions = New-CimSessionOption -Protocol DCOM
                $cimSession = New-CimSession -ComputerName $ComputerName -SessionOption $cimSessionOptions -ErrorAction Stop
                
                $cpu = Get-CimInstance -CimSession $cimSession -ClassName Win32_Processor -ErrorAction Stop | 
                       Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average
                
                $memory = Get-CimInstance -CimSession $cimSession -ClassName Win32_OperatingSystem -ErrorAction Stop
                $memoryUsed = [math]::Round(($memory.TotalVisibleMemorySize - $memory.FreePhysicalMemory) / 1024, 2)
                
                Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
            }
        }
        
        $ping = Test-Connection -ComputerName $ComputerName -Count 1 -ErrorAction Stop
        $latency = $ping.ResponseTime
        
        return @{
            CPUPercent = $cpu
            MemoryUsedMB = $memoryUsed
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

