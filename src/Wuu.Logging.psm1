#Requires -Version 5.1
<#
.DESCRIPTION
Thread-safe debug logging and level wrappers.
#>

function Write-WuuLogEntry {
    <#
    .SYNOPSIS
    Fault-tolerant append of one log line. NEVER throws into the caller.
    .DESCRIPTION
    Debug logs written into OneDrive-synced folders hit "Stream was not
    readable" when the sync engine transiently locks/hydrates the file
    mid-write (PS 5.1 Add-Content opens with restrictive sharing). A logging
    failure must never kill a timer tick, a runspace creation, or a worker
    payload, so: take $LogLock, retry briefly, swallow the rest.
    Inline payload writes should delegate here instead of raw Add-Content.
    .NOTES
    Reads $global:LogPath / $global:LogLock (main session); callers inside
    isolated runspaces should pass -LogPath/-LogLock explicitly.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$LogPath = $global:LogPath,
        [object]$LogLock = $global:LogLock,
        [int]$MaxAttempts = 3
    )
    
    if (-not $LogPath) { return }
    if (-not $LogLock) { $LogLock = New-Object System.Object }
    
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $lockTaken = $false
        try {
            [System.Threading.Monitor]::Enter($LogLock); $lockTaken = $true
            Add-Content -Path $LogPath -Value $Message -Force
            return
        } catch {
            if ($attempt -ge $MaxAttempts) { return }   # give up silently
            Start-Sleep -Milliseconds (100 * $attempt)   # brief backoff
        } finally {
            if ($lockTaken) { [System.Threading.Monitor]::Exit($LogLock) }
        }
    }
}

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
    
    # Fault-tolerant append (never throws - see Write-WuuLogEntry)
    Write-WuuLogEntry -Message $logEntry
    
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

Export-ModuleMember -Function @('Write-WuuLogEntry', 'Write-DebugLog', 'Write-InfoLog', 'Write-WarningLog', 'Write-ErrorLog', 'Write-SuccessLog')

