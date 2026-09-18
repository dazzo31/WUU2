#Requires -Version 5.1
<#
.DESCRIPTION
Thread-safe debug logging and level wrappers.
#>

function Write-DebugLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [string]$Computer = '',
        [switch]$ToConsole
    )
    
    # Skip logging if debug logging is disabled
    if (-not $global:EnableDebugLogging) {
        return
    }
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logEntry = "[$timestamp] [$Level]$(if($Computer){" [$Computer]"}) $Message"
    
    # Thread-safe logging
    [System.Threading.Monitor]::Enter($global:LogLock)
    try {
        Add-Content -Path $global:LogPath -Value $logEntry -Force
    } finally {
        [System.Threading.Monitor]::Exit($global:LogLock)
    }
    
    if ($ToConsole) {
        Write-Host $logEntry -ForegroundColor $(switch($Level){
            'ERROR' {'Red'}
            'WARN' {'Yellow'}
            'SUCCESS' {'Green'}
            'DEBUG' {'Cyan'}
            default {'White'}
        })
    }
}

function Write-InfoLog {
    param([string]$Message, [string]$Computer = '')
    Write-DebugLog $Message -Level 'INFO' -Computer $Computer
}

function Write-WarningLog {
    param([string]$Message, [string]$Computer = '')
    Write-DebugLog $Message -Level 'WARN' -Computer $Computer
}

function Write-ErrorLog {
    param([string]$Message, [string]$Computer = '')
    Write-DebugLog $Message -Level 'ERROR' -Computer $Computer
}

function Write-SuccessLog {
    param([string]$Message, [string]$Computer = '')
    Write-DebugLog $Message -Level 'SUCCESS' -Computer $Computer
}

Export-ModuleMember -Function @('Write-DebugLog', 'Write-InfoLog', 'Write-WarningLog', 'Write-ErrorLog', 'Write-SuccessLog')

