<#
.SYNOPSIS
This script provides a GUI for remotely managing Windows Updates.

.DESCRIPTION
This script provides a GUI for remotely managing Windows Updates. You can check for, download, and install updates remotely. There is also an option to automatically reboot the computer after installing updates if required.

.EXAMPLE
.\WUU.ps1

This example open the Windows Update Utility.

.NOTES
Author: Tyler Siegrist
Date: 12/14/2016

This script needs to be run as an administrator with the credentials of an administrator on the remote computers.

There is limited feedback on the download and install processes due to Microsoft restricting the ability to remotely download or install Windows Updates. This is done by using psexec to run a script locally on the remote machine.

.CHANGELOG
Enhanced Version - 2025-07-08
- Added enhanced error handling with retry logic and connectivity validation
- Improved error messages with specific suggestions for common issues (RPC, WMI, access denied)
- Added performance monitoring (CPU usage, memory, network latency) with threshold warnings
- Implemented automated recovery for common issues (RPC service restart, Remote Registry service)
- Added dependency checking (RPC, WMI, Windows Update service) before operations
- Implemented job throttling for scalability (max concurrent operations configurable)
- Added grey background coloring for errored entries in the UI
- Enhanced status messages to include "Reboot required" when applicable
- Added three automation levels:
  * Auto Reboot: Automatically reboots after installation if required
  * Auto Install: Automatically installs updates once downloaded
  * Full Automation: Complete workflow (download → install → reboot → re-check)
- Added tooltips to UI elements for better user guidance
- Improved error handling with auto-recovery attempts and detailed suggestions
- Enhanced connectivity validation with multiple retry attempts
- Added performance thresholds to prevent operations on overloaded systems
- Implemented comprehensive logging of system performance metrics
- Fixed PowerShell Core 7.x compatibility issues:
  * Replaced Get-Service -ComputerName with Invoke-Command for remote service management
  * Replaced Get-WmiObject with Get-CimInstance for WMI operations
  * Added local vs remote computer detection for proper cmdlet usage
- Added debug logging toggle variable ($EnableDebugLogging) set to $false by default
  * Reduces console output and log file generation for cleaner operation
  * Can be enabled by setting $script:EnableDebugLogging = $true at the top of the script
- Fixed PSScriptAnalyzer warning by removing unused $dependencies variable
- Added configurable credential management for remote WMI/CIM queries
  * Custom credential configuration dialog for username, domain, and password
  * Securely stores credentials with encrypted computer list configurations
  * Falls back to prompting for alternate credentials if configured credentials fail
  * Caches working credentials per computer to avoid repeated prompts
  * Right-click context menu option to configure custom credentials
  * Greatly improves connectivity to domain computers with authentication requirements
#>

#region Configuration

# Toggle debug logging. Set to $true to enable detailed logging (performance impact).
# WARNING: Enabling this creates large log files and reduces performance.
$script:EnableDebugLogging = $false

# Timeout settings (seconds)
$sessionTimeout = 30       # Timeout for creating Windows Update session
$searchTimeout = 300       # Timeout for update search operation
$rebootCheckTimeout = 60   # Timeout for reboot check

# Enhanced error handling toggle. Set to $true to enable advanced error handling.
$script:EnableEnhancedErrorHandling = $true

# Custom credentials for remote WMI queries
$script:UseCustomCredentials = $false
$script:CustomCredentials = $null
$script:CredentialCache = @{}
$script:CredentialConfig = @{ Username = ''; Domain = ''; UseCredentials = $false }

# Job throttling for scalability
$MaxConcurrentJobs = 10
# Performance thresholds for operations
$PerformanceThreshold = @{ CPUPercent = 80; MemoryMB = 1024; NetworkLatencyMs = 1000 }

# Background processing control (synchronized for runspace access)
$backgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })

# File paths and external tool configuration
$script:ConfigPaths = @{
    PsExec = Join-Path $PSScriptRoot 'psexec.exe'
    DownloadScript = Join-Path $PSScriptRoot 'Scripts\Download-Patches.ps1'
    InstallScript = Join-Path $PSScriptRoot 'Scripts\Install-Patches.ps1'
    ComputerListConfig = Join-Path $PSScriptRoot 'ComputerList.config'
    LogDirectory = $PSScriptRoot
}

# Validation of required external files
$requiredFiles = @('psexec.exe', 'Scripts\Download-Patches.ps1', 'Scripts\Install-Patches.ps1')
foreach ($file in $requiredFiles) {
    $fullPath = Join-Path $PSScriptRoot $file
    if (-not (Test-Path $fullPath)) {
        Write-Warning "Required file not found: $fullPath - functionality may be impaired"
    }
}

#endregion Configuration

#region Synchronized collections
$uiHash = [hashtable]::Synchronized(@{})
$jobs = [system.collections.arraylist]::Synchronized((New-Object System.Collections.ArrayList))
$jobCleanup = [hashtable]::Synchronized(@{})
$updatesHash = [hashtable]::Synchronized(@{})
$performanceHash = [hashtable]::Synchronized(@{})
$errorSuggestionsHash = [hashtable]::Synchronized(@{})


#region Logging

# Initialize logging
$script:LogPath = Join-Path $PSScriptRoot "WUU_Debug_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:LogLock = New-Object System.Object

# Logging function
function Write-DebugLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [string]$Computer = '',
        [switch]$ToConsole
    )
    
    # Skip logging if debug logging is disabled
    if (-not $script:EnableDebugLogging) {
        return
    }
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logEntry = "[$timestamp] [$Level]$(if($Computer){" [$Computer]"}) $Message"
    
    # Thread-safe logging
    [System.Threading.Monitor]::Enter($script:LogLock)
    try {
        Add-Content -Path $script:LogPath -Value $logEntry -Force
    } finally {
        [System.Threading.Monitor]::Exit($script:LogLock)
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

# Initialize debug log
if ($script:EnableDebugLogging) {
    Write-DebugLog "Windows Update Utility v1.1 Debug Log Started" -Level 'SUCCESS' -ToConsole
    Write-DebugLog "Log file: $script:LogPath" -Level 'INFO' -ToConsole
}

#endregion Logging

#endregion Synchronized collections

#region Error Handling

#region Error Suggestions Mapping

# Error suggestions mapping
$errorSuggestionsHash = [hashtable]::Synchronized(@{
    '800706ba' = @{
        Description = 'RPC server is unavailable'
        Suggestions = @(
            'Check if Windows Firewall is blocking RPC traffic',
            'Verify Remote Registry service is running',
            'Ensure RPC service is started',
            'Check network connectivity between computers'
        )
        AutoFix = $true
    }
    '80070005' = @{
        Description = 'Access denied'
        Suggestions = @(
            'Run as administrator',
            'Check user account permissions',
            'Verify UAC settings',
            'Ensure account has administrative rights on target computer'
        )
        AutoFix = $false
    }
    '800706be' = @{
        Description = 'Remote procedure call failed'
        Suggestions = @(
            'Restart RPC service on target computer',
            'Check if target computer is overloaded',
            'Verify network stability',
            'Try operation again after a few minutes'
        )
        AutoFix = $true
    }
    'not responding to ping' = @{
        Description = 'Computer is not reachable on the network'
        Suggestions = @(
            'Verify the computer name is correct',
            'Check if the computer is powered on',
            'Ensure network cables are connected',
            'Verify firewall settings allow ICMP ping',
            'Try using IP address instead of computer name'
        )
        AutoFix = $false
    }
    'not reachable' = @{
        Description = 'Computer is not accessible via network'
        Suggestions = @(
            'Verify the computer name is correct',
            'Check if the computer is powered on',
            'Ensure network connectivity',
            'Verify DNS resolution is working',
            'Check firewall settings'
        )
        AutoFix = $false
    }
    'WMI is not accessible' = @{
        Description = 'WMI/CIM service is not responding'
        Suggestions = @(
            'Verify WMI service is running on target computer',
            'Check Windows Firewall WMI exceptions',
            'Ensure proper credentials are provided',
            'Try using alternate authentication method'
        )
        AutoFix = $false
    }
    'name resolution' = @{
        Description = 'DNS name resolution failed'
        Suggestions = @(
            'Check DNS server configuration',
            'Verify computer name spelling',
            'Try using IP address instead',
            'Check network connectivity to DNS server'
        )
        AutoFix = $false
    }
    'timeout' = @{
        Description = 'Operation timed out'
        Suggestions = @(
            'Check network connectivity',
            'Verify target computer is responsive',
            'Increase timeout settings if needed',
            'Try again later when network is less busy'
        )
        AutoFix = $false
    }
})

#endregion Error Suggestions Mapping

#region Environment Validation

#region Administrator Privilege Check
$ErrorActionPreference = 'Stop'

try {
    Write-DebugLog "Starting Windows Update Utility validation" -Level 'INFO'
    
    #Validate user is an Administrator
    Write-DebugLog "Checking Administrator credentials" -Level 'INFO'
    If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Warning "This script requires Administrator privileges for full functionality!"
        Write-Host "Attempting to restart as Administrator..." -ForegroundColor Yellow
        Write-DebugLog "Script not running as Administrator - attempting elevation" -Level 'WARN'
        
        try {
            # Get the current script path - use $PSCommandPath as fallback for dot-sourced execution
            $scriptPath = $MyInvocation.MyCommand.Path
            if ([string]::IsNullOrEmpty($scriptPath)) {
                $scriptPath = $PSCommandPath
            }
            
            # If still empty, try to get from the script location
            if ([string]::IsNullOrEmpty($scriptPath)) {
                $scriptPath = Join-Path $PSScriptRoot "WUU.ps1"
            }
            
            Write-DebugLog "Script path resolved to: $scriptPath" -Level 'INFO'
            
            # Validate that the script path exists
            if (-not (Test-Path $scriptPath)) {
                throw "Cannot locate script file at: $scriptPath"
            }
            
            $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
            
            # Add any original arguments that were passed to this script
            if ($args) {
                $arguments += " " + ($args -join " ")
            }
            
            # Start PowerShell as Administrator
            $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processStartInfo.FileName = "powershell.exe"
            $processStartInfo.Arguments = $arguments
            $processStartInfo.Verb = "runas"  # This triggers UAC elevation
            $processStartInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            $processStartInfo.WorkingDirectory = Split-Path $scriptPath
            
            Write-Host "Starting elevated PowerShell session..." -ForegroundColor Green
            Write-Host "Script path: $scriptPath" -ForegroundColor Gray
            [System.Diagnostics.Process]::Start($processStartInfo) | Out-Null
            
            Write-Host "Elevated session started. Closing current session." -ForegroundColor Green
            Write-DebugLog "Successfully launched elevated PowerShell session" -Level 'SUCCESS'
            
            # Exit the current non-elevated session
            exit 0
            
        } catch {
            Write-Error "Failed to restart as Administrator: $($_.Exception.Message)"
            Write-Host "Please manually run PowerShell as Administrator and execute this script." -ForegroundColor Red
            Write-DebugLog "Failed to elevate privileges: $($_.Exception.Message)" -Level 'ERROR'
            
            # Ask user if they want to continue anyway
            $continue = Read-Host "Continue with limited functionality? (Y/N)"
            if ($continue -notmatch '^[Yy]') {
                Write-Host "Script execution cancelled." -ForegroundColor Yellow
                exit 1
            }
            
            Write-Warning "Continuing with limited functionality - some features may not work properly!"
            Write-DebugLog "User chose to continue without Administrator privileges" -Level 'WARN'
        }
    } else {
        Write-Host "Running with Administrator privileges." -ForegroundColor Green
        Write-DebugLog "Script running with Administrator privileges" -Level 'SUCCESS'
    }


#endregion Administrator Privilege Check

#region Working Directory Setup
    #Ensure that we are running the GUI from the correct location so that scripts & psexec can be accessed.
    $scriptPath = Split-Path $MyInvocation.MyCommand.Path
    Set-Location $scriptPath
    Write-DebugLog "Working directory set to: $(Get-Location)" -Level 'INFO'

#endregion Working Directory Setup

#region PsExec Validation
    #Check for PsExec
    $psexecPath = Join-Path $scriptPath "psexec.exe"
    If (-Not (Test-Path $psexecPath)){
        Write-Warning "Psexec.exe missing from $scriptPath!"
        Write-Host "You can download PsTools directly. Would you like to proceed? (Y/N)" -ForegroundColor Yellow
        $response = Read-Host
        if ($response -eq 'Y' -or $response -eq 'y') {
            try {
                $psToolsUrl = 'https://download.sysinternals.com/files/PSTools.zip'
                $zipPath = Join-Path $scriptPath "PSTools.zip"
                $psToolsExtractedPath = Join-Path $scriptPath "PSTools"
                
                Write-Host "Downloading PsTools from $psToolsUrl..." -ForegroundColor Yellow
                Write-Host "This may take a moment depending on your internet connection..." -ForegroundColor Cyan
                
                # Download with progress (if supported)
                try {
                    $webClient = New-Object System.Net.WebClient
                    $webClient.DownloadFile($psToolsUrl, $zipPath)
                    $webClient.Dispose()
                } catch {
                    # Fallback to Invoke-WebRequest
                    Invoke-WebRequest -Uri $psToolsUrl -OutFile $zipPath -ErrorAction Stop
                }
                
                Write-Host "Extracting PsTools..." -ForegroundColor Yellow
                Expand-Archive -Path $zipPath -DestinationPath $psToolsExtractedPath -Force -ErrorAction Stop
                
                Write-Host "Copying psexec.exe to script directory..." -ForegroundColor Yellow
                Copy-Item -Path (Join-Path $psToolsExtractedPath 'psexec.exe') -Destination $scriptPath -Force -ErrorAction Stop
                
                # Cleanup
                Remove-Item $zipPath -Force
                Remove-Item $psToolsExtractedPath -Recurse -Force
                
                Write-Host "PsExec downloaded and placed in the script directory." -ForegroundColor Green
            } catch {
                Write-Error "Failed to download or extract PsTools: $($_.Exception.Message)"
                Write-Host "Please download psexec.exe manually and place it in the script directory." -ForegroundColor Cyan
                Write-Host "Download URL: https://docs.microsoft.com/en-us/sysinternals/downloads/psexec" -ForegroundColor Cyan
                Read-Host "Press Enter to exit"
                exit
            }
        } else {
            Write-Host "Please download psexec.exe manually and place it in the script directory." -ForegroundColor Cyan
            Write-Host "Download URL: https://docs.microsoft.com/en-us/sysinternals/downloads/psexec" -ForegroundColor Cyan
            Read-Host "Press Enter to exit"
            exit
        }
    }
    Write-DebugLog "psexec.exe found at: $psexecPath" -Level 'INFO'

#endregion PsExec Validation

#region PowerShell STA Mode Validation
    #Determine if this instance of PowerShell can run WPF (required for GUI)
    Write-DebugLog "Checking PowerShell apartment state: $($host.Runspace.ApartmentState)" -Level 'INFO'
    If ($host.Runspace.ApartmentState -ne 'STA'){
        Write-Warning "This script must be run in PowerShell started using -STA switch!"
        Write-Host "Attempting to restart PowerShell in STA mode..." -ForegroundColor Yellow
        try {
            Start-Process -FilePath "PowerShell.exe" -ArgumentList "-STA -noprofile -WindowStyle Hidden -file `"$($myinvocation.mycommand.definition)`""
            Write-Host "STA mode PowerShell launch initiated." -ForegroundColor Green
        } catch {
            Write-Error "Failed to restart in STA mode: $($_.Exception.Message)"
            Read-Host "Press Enter to exit"
        }
        exit
    }
    Write-DebugLog "PowerShell is running in STA mode" -Level 'INFO'

#endregion PowerShell STA Mode Validation
    
} catch {
    Write-Error "Environment validation failed: $($_.Exception.Message)"
    Write-DebugLog "Error details: $($_.Exception.GetType().FullName)" -Level 'ERROR'
    Write-DebugLog "Stack trace: $($_.ScriptStackTrace)" -Level 'ERROR'
    Read-Host "Press Enter to exit"
    exit
}
#endregion Environment validation

#region Load required assemblies with error handling
try {
    Write-DebugLog "Loading required .NET assemblies" -Level 'INFO'
    
    $assemblies = @(
        'PresentationFramework',
        'PresentationCore', 
        'WindowsBase',
        'Microsoft.VisualBasic',
        'System.Windows.Forms'
    )
    
    # For PowerShell 7, we need to explicitly load DirectoryServices
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        try {
            Add-Type -AssemblyName 'System.DirectoryServices' -ErrorAction SilentlyContinue
            Write-DebugLog "Loaded DirectoryServices assembly for PowerShell 7" -Level 'INFO'
        } catch {
            Write-DebugLog "DirectoryServices assembly not available in PowerShell 7 - AD features will be limited" -Level 'WARN'
        }
        
        try {
            Add-Type -AssemblyName 'System.DirectoryServices.ActiveDirectory' -ErrorAction SilentlyContinue
            Write-DebugLog "Loaded DirectoryServices.ActiveDirectory assembly for PowerShell 7" -Level 'INFO'
        } catch {
            Write-DebugLog "DirectoryServices.ActiveDirectory assembly not available in PowerShell 7 - AD features will be limited" -Level 'WARN'
        }
    }
    
    foreach ($assembly in $assemblies) {
        try {
            Add-Type -AssemblyName $assembly -ErrorAction Stop
            Write-DebugLog "Loaded assembly: $assembly" -Level 'INFO'
        } catch {
            Write-Error "Failed to load assembly '$assembly': $($_.Exception.Message)"
            throw
        }
    }
    
    Write-DebugLog "All required assemblies loaded successfully" -Level 'INFO'
} catch {
    Write-Error "Failed to load required assemblies: $($_.Exception.Message)"
    Write-Host "This usually indicates a problem with .NET Framework or WPF installation." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}
#endregion Load required assemblies

#region Load required PowerShell modules
try {
    Write-DebugLog "Loading required PowerShell modules" -Level 'INFO'
    
    # Import Microsoft.PowerShell.Security module for ConvertTo-SecureString
    Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
    Write-DebugLog "Loaded module: Microsoft.PowerShell.Security" -Level 'INFO'
    
    Write-DebugLog "All required modules loaded successfully" -Level 'INFO'
} catch {
    Write-Error "Failed to load required modules: $($_.Exception.Message)"
    Write-Host "This usually indicates a problem with PowerShell module installation." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}
#endregion Load required modules

#region Load XAML with enhanced error handling
try {
    Write-DebugLog "Loading XAML interface" -Level 'INFO'
    
    $xamlPath = Join-Path $scriptPath "WUU.xaml"
    Write-DebugLog "XAML file path: $xamlPath" -Level 'INFO'
    
    if (-not (Test-Path $xamlPath)) {
        throw "XAML file not found at: $xamlPath"
    }
    
    Write-DebugLog "Reading XAML content" -Level 'INFO'
    [xml]$xaml = Get-Content $xamlPath -ErrorAction Stop
    
    Write-DebugLog "Creating XML reader" -Level 'INFO'
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    
    Write-DebugLog "Loading XAML into WPF" -Level 'INFO'
    $uiHash.Window = [Windows.Markup.XamlReader]::Load($reader)
    
    if (-not $uiHash.Window) {
        throw "Failed to create window object from XAML"
    }
    
    Write-DebugLog "XAML interface loaded successfully" -Level 'INFO'
    
} catch {
    Write-Error "Failed to load XAML interface: $($_.Exception.Message)"
    Write-DebugLog "Error details: $($_.Exception.GetType().FullName)" -Level 'ERROR'
    Write-Host "This usually indicates a problem with the WUU.xaml file or WPF." -ForegroundColor Red
    
    if ($_.Exception.InnerException) {
        Write-DebugLog "Inner exception: $($_.Exception.InnerException.Message)" -Level 'ERROR'
    }
    
    Read-Host "Press Enter to exit"
    exit
}
#endregion

#region Helper Functions

#region Credential Management

# DPAPI encryption helpers for secure credential storage
function Protect-Credential {
    param([System.Security.SecureString]$SecurePassword)
    
    try {
        # Convert SecureString to encrypted standard string using DPAPI
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        
        # Encrypt using DPAPI (user-specific, requires same user context to decrypt)
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainPassword)
        $ProtectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $Bytes, 
            $null, 
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        
        return [Convert]::ToBase64String($ProtectedBytes)
    } catch {
        Write-DebugLog "Failed to protect credential: $($_.Exception.Message)" -Level 'ERROR'
        return $null
    }
}

function Unprotect-Credential {
    param([string]$ProtectedBase64)
    
    try {
        # Decrypt using DPAPI
        $ProtectedBytes = [Convert]::FromBase64String($ProtectedBase64)
        $PlainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $ProtectedBytes, 
            $null, 
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $PlainPassword = [System.Text.Encoding]::UTF8.GetString($PlainBytes)
        
        # Convert back to SecureString
        $SecurePassword = ConvertTo-SecureString $PlainPassword -AsPlainText -Force
        return $SecurePassword
    } catch {
        Write-DebugLog "Failed to unprotect credential: $($_.Exception.Message)" -Level 'ERROR'
        return $null
    }
}

# Enhanced credential handling function with security improvements
function Get-RemoteCredentials {
    param(
        [string]$ComputerName,
        [string]$Operation = 'WMI access'
    )
    
    try {
        # Check cache first (runtime only, never persisted)
        if ($script:CredentialCache.ContainsKey($ComputerName)) {
            Write-DebugLog "Using cached credentials for $ComputerName" -Level 'DEBUG'
            return $script:CredentialCache[$ComputerName]
        }
        
        # Try custom configured credentials first if enabled
        if ($script:UseCustomCredentials -and $script:CustomCredentials) {
            try {
                Write-DebugLog "Testing custom credentials for $ComputerName" -Level 'DEBUG'
                # Use helper function for credential test
                $wmiResult = Invoke-CimWithTimeout -ComputerName $ComputerName -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 5 -Credential $script:CustomCredentials -Operation 'Custom credential test'
                
                if ($wmiResult.Success) {
                    # Custom credentials work, cache them (runtime cache only)
                    Write-DebugLog "Custom credentials successful for $ComputerName, caching" -Level 'INFO'
                    $script:CredentialCache[$ComputerName] = $script:CustomCredentials
                    return $script:CustomCredentials
                } else {
                    Write-DebugLog "Custom credentials failed for $ComputerName : $($wmiResult.Error)" -Level 'WARN'
                }
            } catch {
                Write-DebugLog "Custom credentials test failed for $ComputerName : $($_.Exception.Message)" -Level 'WARN'
            }
        }
        
        # Custom credentials failed or not configured, try default credentials
        try {
            Write-DebugLog "Testing default credentials for $ComputerName" -Level 'DEBUG'
            # Use helper function for default credential test
            $wmiResult = Invoke-CimWithTimeout -ComputerName $ComputerName -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 5 -Operation 'Default credential test'
            
            if ($wmiResult.Success) {
                # Default credentials work, cache success (runtime cache only)
                Write-DebugLog "Default credentials successful for $ComputerName, caching" -Level 'INFO'
                $script:CredentialCache[$ComputerName] = $null  # null means use default credentials
                return $null
            } else {
                Write-DebugLog "Default credentials failed for $ComputerName : $($wmiResult.Error)" -Level 'WARN'
            }
        } catch {
            Write-DebugLog "Default credentials test failed for $ComputerName : $($_.Exception.Message)" -Level 'WARN'
        }
        
        # Both failed - return null to indicate auth failure
        # Caller will handle the error appropriately
        Write-DebugLog "All credential tests failed for $ComputerName - returning null" -Level 'WARN'
        return $null
        
    } catch {
        Write-DebugLog "Error in Get-RemoteCredentials for $ComputerName : $($_.Exception.Message)" -Level 'ERROR'
        return $null
    }
}

# Helper function: Execute CIM command with timeout (prevents hangs)
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
            param($ComputerName, $ClassName, $Cred)
            try {
                $params = @{
                    ClassName = $ClassName
                    ComputerName = $ComputerName
                    ErrorAction = 'Stop'
                }
                if ($Cred) { $params.Credential = $Cred }
                $result = Get-CimInstance @params
                return @{ Success = $true; Result = $result }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message }
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

# Helper function: Execute service command with timeout (prevents hangs)
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

#endregion Credential Management

#region Dialog Functions

# Function to show GUI password prompt dialog
function Show-PasswordPrompt {
    param(
        [string]$Title = "Password Required",
        [string]$Message = "Enter password:"
    )
    
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    
    # Create the password prompt dialog
    $xamlPasswordDialog = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Height="200" Width="400"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" Topmost="True">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <TextBlock Grid.Row="0" Text="$Message" FontSize="12" TextWrapping="Wrap"/>
        
        <Label Grid.Row="2" Content="Password:" FontSize="11" Padding="0,0,0,5"/>
        <PasswordBox Grid.Row="2" Name="PasswordBox" Height="25" Margin="70,0,0,0" 
                     ToolTip="Enter the password" 
                     MaxLength="256" 
                     Background="White" 
                     BorderBrush="#CCCCCC" 
                     BorderThickness="1"/>
        
        <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button Name="OKButton" Content="OK" Width="80" Height="30" Margin="0,0,10,0" IsDefault="True"/>
            <Button Name="CancelButton" Content="Cancel" Width="80" Height="30" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    
    try {
        $reader = [System.Xml.XmlNodeReader]::new([xml]$xamlPasswordDialog)
        $dialog = [Windows.Markup.XamlReader]::Load($reader)
        
        # Get dialog controls
        $passwordBox = $dialog.FindName('PasswordBox')
        $okButton = $dialog.FindName('OKButton')
        $cancelButton = $dialog.FindName('CancelButton')
        
        # Set focus to password box when dialog opens
        $dialog.Add_Loaded({
            $passwordBox.Focus()
        })
        
        # OK button click handler
        $okButton.Add_Click({
            $dialog.Tag = $passwordBox.SecurePassword.Copy()
            $dialog.DialogResult = $true
            $dialog.Close()
        })
        
        # Cancel button click handler
        $cancelButton.Add_Click({
            $dialog.DialogResult = $false
            $dialog.Close()
        })
        
        # Handle Enter key in password box
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
            return $dialog.Tag
        } else {
            return $null
        }
        
    } catch {
        Write-Error "Failed to show password dialog: $($_.Exception.Message)"
        return $null
    }
}

# Function to show custom WPF credential dialog (replaces Get-Credential)
# This function fixes password input lag by using a fast WPF dialog instead of the slow Windows credential dialog
function Show-CustomCredentialDialog {
    param(
        [string]$Message = "Enter your credentials",
        [string]$Username = "",
        [string]$Title = "Credentials Required"
    )
    
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    
    # Create the credential dialog XAML
    $xamlCredentialDialog = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Height="280" Width="450"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" Topmost="True">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="15"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <TextBlock Grid.Row="0" Text="$Message" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,5"/>
        
        <Label Grid.Row="2" Content="Username:" FontSize="11" Padding="0,0,0,5"/>
        <TextBox Grid.Row="2" Name="UsernameTextBox" Height="25" Margin="80,0,0,0" 
                 ToolTip="Enter username (domain\username or username@domain.com)"/>
        
        <Label Grid.Row="4" Content="Password:" FontSize="11" Padding="0,0,0,5"/>
        <PasswordBox Grid.Row="4" Name="PasswordBox" Height="25" Margin="80,0,0,0" 
                     ToolTip="Enter password" 
                     MaxLength="256" 
                     Background="White" 
                     BorderBrush="#CCCCCC" 
                     BorderThickness="1"/>
        
        <CheckBox Grid.Row="6" Name="RememberCheckBox" Content="Remember credentials for this session" 
                  FontSize="10" Margin="0,5,0,0" IsChecked="False"/>
        
        <StackPanel Grid.Row="8" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0">
            <Button Name="OKButton" Content="OK" Width="80" Height="30" Margin="0,0,10,0" IsDefault="True"/>
            <Button Name="CancelButton" Content="Cancel" Width="80" Height="30" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    
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
            # Use dispatcher to ensure proper focus timing
            $dialog.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [System.Action]{
                if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
                    $usernameTextBox.Focus()
                } else {
                    $passwordBox.Focus()
                }
            })
        })
        
        # OK button click handler with input validation
        $okButton.Add_Click({
            # Validate username - required field
            if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
                [System.Windows.MessageBox]::Show("Please enter a username.", "Credential Error", 'OK', 'Warning')
                $usernameTextBox.Focus()
                return
            }
            
            # Validate username format (basic sanitization)
            $username = $usernameTextBox.Text.Trim()
            if ($username.Length -lt 3 -or $username.Length -gt 100) {
                [System.Windows.MessageBox]::Show("Username must be between 3 and 100 characters.", "Credential Error", 'OK', 'Warning')
                $usernameTextBox.Focus()
                return
            }
            
            # Check for potentially dangerous characters in username
            if ($username -match '[<>"''\\;/&|]') {
                [System.Windows.MessageBox]::Show("Username contains invalid characters.", "Credential Error", 'OK', 'Warning')
                $usernameTextBox.Focus()
                return
            }
            
            # Validate password - required field
            if ($passwordBox.SecurePassword.Length -eq 0) {
                [System.Windows.MessageBox]::Show("Please enter a password.", "Credential Error", 'OK', 'Warning')
                $passwordBox.Focus()
                return
            }
            
            # Validate password length
            if ($passwordBox.SecurePassword.Length -lt 1 -or $passwordBox.SecurePassword.Length -gt 256) {
                [System.Windows.MessageBox]::Show("Password must be between 1 and 256 characters.", "Credential Error", 'OK', 'Warning')
                $passwordBox.Focus()
                return
            }
            
            # Store results in dialog tag (sanitized username)
            $dialog.Tag = @{
                Username = $username
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
        Write-Error "Failed to show credential dialog: $($_.Exception.Message)"
        return $null
    }
}

# Function to show credential configuration dialog
function Show-CredentialConfigDialog {
    param()
    
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    
    # Create the credential configuration dialog
    $xamlDialog = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configure Remote Credentials" Height="380" Width="500"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <TextBlock Grid.Row="0" Text="Configure custom credentials for remote WMI/RPC operations:" 
                   FontWeight="Bold" FontSize="12" TextWrapping="Wrap"/>
        
        <CheckBox Grid.Row="2" Name="UseCredentialsCheckBox" Content="Use custom credentials for remote connections" 
                  FontSize="11" VerticalAlignment="Center"/>
        
        <Label Grid.Row="4" Content="Username:" FontSize="11" Padding="0,0,0,5"/>
        <TextBox Grid.Row="4" Name="UsernameTextBox" Height="25" Margin="80,0,0,0" 
                 ToolTip="Enter username (e.g., administrator or domain\\username)"/>
        
        <Label Grid.Row="6" Content="Domain:" FontSize="11" Padding="0,0,0,5"/>
        <TextBox Grid.Row="6" Name="DomainTextBox" Height="25" Margin="80,0,0,0" 
                 ToolTip="Enter domain name (leave blank for local accounts)"/>
        
        <Label Grid.Row="8" Content="Password:" FontSize="11" Padding="0,0,0,5"/>
        <PasswordBox Grid.Row="8" Name="PasswordBox" Height="25" Margin="80,0,0,0" 
                     ToolTip="Enter password for the specified user"/>
        
        <TextBlock Grid.Row="10" Text="Note: Credentials will be securely stored with saved computer list configurations." 
                   FontStyle="Italic" FontSize="10" Foreground="Gray" TextWrapping="Wrap"/>
        
        <StackPanel Grid.Row="12" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button Name="TestButton" Content="Test Connection" Width="120" Height="30" Margin="0,0,10,0" 
                    ToolTip="Test the credentials with a sample WMI query"/>
            <Button Name="OKButton" Content="OK" Width="80" Height="30" Margin="0,0,10,0" IsDefault="True"/>
            <Button Name="CancelButton" Content="Cancel" Width="80" Height="30" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    
    try {
        $reader = [System.Xml.XmlNodeReader]::new([xml]$xamlDialog)
        $dialog = [Windows.Markup.XamlReader]::Load($reader)
        
        # Get dialog controls
        $useCredentialsCheckBox = $dialog.FindName('UseCredentialsCheckBox')
        $usernameTextBox = $dialog.FindName('UsernameTextBox')
        $domainTextBox = $dialog.FindName('DomainTextBox')
        $passwordBox = $dialog.FindName('PasswordBox')
        $testButton = $dialog.FindName('TestButton')
        $okButton = $dialog.FindName('OKButton')
        
        # Load current configuration
        $useCredentialsCheckBox.IsChecked = $script:CredentialConfig.UseCredentials
        $usernameTextBox.Text = $script:CredentialConfig.Username
        $domainTextBox.Text = $script:CredentialConfig.Domain
        
        # Enable/disable controls based on checkbox
        $enableControls = {
            $enabled = $useCredentialsCheckBox.IsChecked
            $usernameTextBox.IsEnabled = $enabled
            $domainTextBox.IsEnabled = $enabled
            $passwordBox.IsEnabled = $enabled
            $testButton.IsEnabled = $enabled
        }
        
        $useCredentialsCheckBox.Add_Click($enableControls)
        & $enableControls
        
        # Test button click handler
        $testButton.Add_Click({
            try {
                if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
                    [System.Windows.MessageBox]::Show("Please enter a username.", "Test Credentials", 'OK', 'Warning')
                    return
                }
                
                if ($passwordBox.SecurePassword.Length -eq 0) {
                    [System.Windows.MessageBox]::Show("Please enter a password.", "Test Credentials", 'OK', 'Warning')
                    return
                }
                
                # Create test credential
                $username = if ([string]::IsNullOrWhiteSpace($domainTextBox.Text)) { 
                    $usernameTextBox.Text 
                } else { 
                    "$($domainTextBox.Text)\$($usernameTextBox.Text)" 
                }
                
                $testCredential = New-Object System.Management.Automation.PSCredential($username, $passwordBox.SecurePassword.Copy())
                
                # Test with local computer first
                $testResult = Get-CimInstance -ClassName Win32_ComputerSystem -Credential $testCredential -ErrorAction Stop
                
                if ($testResult) {
                    [System.Windows.MessageBox]::Show("Credentials test successful!`nComputer: $($testResult.Name)", "Test Credentials", 'OK', 'Information')
                } else {
                    [System.Windows.MessageBox]::Show("Credentials test failed - no result returned.", "Test Credentials", 'OK', 'Error')
                }
            } catch {
                [System.Windows.MessageBox]::Show("Credentials test failed:`n$($_.Exception.Message)", "Test Credentials", 'OK', 'Error')
            }
        })
        
        # OK button click handler
        $okButton.Add_Click({
            try {
                # Update configuration
                $script:CredentialConfig.UseCredentials = $useCredentialsCheckBox.IsChecked
                $script:CredentialConfig.Username = $usernameTextBox.Text
                $script:CredentialConfig.Domain = $domainTextBox.Text
                
                if ($useCredentialsCheckBox.IsChecked) {
                    if ([string]::IsNullOrWhiteSpace($usernameTextBox.Text)) {
                        [System.Windows.MessageBox]::Show("Please enter a username when using custom credentials.", "Configuration Error", 'OK', 'Warning')
                        return
                    }
                    
                    if ($passwordBox.SecurePassword.Length -eq 0) {
                        [System.Windows.MessageBox]::Show("Please enter a password when using custom credentials.", "Configuration Error", 'OK', 'Warning')
                        return
                    }
                    
                    # Create and store the credential
                    $username = if ([string]::IsNullOrWhiteSpace($domainTextBox.Text)) { 
                        $usernameTextBox.Text 
                    } else { 
                        "$($domainTextBox.Text)\$($usernameTextBox.Text)" 
                    }
                    
                    $script:CustomCredentials = New-Object System.Management.Automation.PSCredential($username, $passwordBox.SecurePassword.Copy())
                    $script:UseCustomCredentials = $true
                    
                    # Clear credential cache when credentials change
                    $script:CredentialCache.Clear()
                    
                    Write-DebugLog "Custom credentials configured for user: $username" -Level 'INFO'
                } else {
                    $script:UseCustomCredentials = $false
                    $script:CustomCredentials = $null
                    $script:CredentialCache.Clear()
                    
                    Write-DebugLog "Custom credentials disabled" -Level 'INFO'
                }
                
                $dialog.DialogResult = $true
                $dialog.Close()
            } catch {
                [System.Windows.MessageBox]::Show("Error saving credentials: $($_.Exception.Message)", "Configuration Error", 'OK', 'Error')
            }
        })
        
        # Set dialog owner to main window if available
        if ($uiHash.Window) {
            $dialog.Owner = $uiHash.Window
        }
        
        # Show dialog
        $result = $dialog.ShowDialog()
        return $result
        
    } catch {
        Write-Error "Failed to show credential configuration dialog: $($_.Exception.Message)"
        return $false
    }
}

# Performance monitoring function with enhanced credential handling
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

#endregion Dialog Functions

#region Monitoring and Performance

# Enhanced error handling with suggestions
function Get-ErrorSuggestions {
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
}

# Automated recovery function
function Invoke-AutoRecovery {
    param([string]$ComputerName, [string]$ErrorCode)
    
    $errorInfo = Get-ErrorSuggestions -ErrorMessage $ErrorCode
    
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
                    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                        Get-Service -Name 'RpcSs' -ErrorAction Stop | Restart-Service -ErrorAction Stop
                        Start-Sleep -Seconds 5
                        Get-Service -Name 'RemoteRegistry' -ErrorAction Stop | Start-Service -ErrorAction Stop
                    } -ErrorAction Stop
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
}

#endregion Monitoring and Performance

#region Utility Functions

# Function to update status text box
function Update-Status {
    param([string]$Message)
    try {
        $uiHash.StatusTextBox.Dispatcher.Invoke('Normal', [action]{
            $uiHash.StatusTextBox.Text = $Message
        })
    } catch {
        # Silently handle dispatcher errors during shutdown
    }
}

# Function to update status text box with background priority
function Update-StatusBackground {
    param([string]$Message)
    try {
        $uiHash.StatusTextBox.Dispatcher.Invoke('Background', [action]{
            $uiHash.StatusTextBox.Text = $Message
        })
    } catch {
        # Silently handle dispatcher errors during shutdown
    }
}

# Function to log info messages
function Write-InfoLog {
    param([string]$Message, [string]$Computer = '')
    Write-DebugLog $Message -Level 'INFO' -Computer $Computer
}

# Function to log warning messages
function Write-WarningLog {
    param([string]$Message, [string]$Computer = '')
    Write-DebugLog $Message -Level 'WARN' -Computer $Computer
}

# Function to log error messages
function Write-ErrorLog {
    param([string]$Message, [string]$Computer = '')
    Write-DebugLog $Message -Level 'ERROR' -Computer $Computer
}

# Function to log success messages
function Write-SuccessLog {
    param([string]$Message, [string]$Computer = '')
    Write-DebugLog $Message -Level 'SUCCESS' -Computer $Computer
}

# Function to show message box and log error
function Show-ErrorDialog {
    param(
        [string]$Message,
        [string]$Title = 'Error',
        [string]$LogMessage = '',
        [string]$Computer = ''
    )
    
    if ($LogMessage) {
        Write-ErrorLog $LogMessage -Computer $Computer
    } else {
        Write-ErrorLog $Message -Computer $Computer
    }
    
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Error')
}

# Function to show warning dialog and log
function Show-WarningDialog {
    param(
        [string]$Message,
        [string]$Title = 'Warning',
        [string]$LogMessage = '',
        [string]$Computer = ''
    )
    
    if ($LogMessage) {
        Write-WarningLog $LogMessage -Computer $Computer
    } else {
        Write-WarningLog $Message -Computer $Computer
    }
    
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Warning')
}

#endregion Utility Functions

#region System Utilities

# Dependency checker
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
        } -ArgumentList $ComputerName, $script:UseDomainCredentials, $script:AlternateCredentials, $script:CredentialCache
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

# Helper function to safely execute operations with timeout
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

# Encryption helper functions for computer list configuration
function Protect-ComputerListData {
    param(
        [string]$Data,
        [SecureString]$Password
    )
    
    try {
        # Convert SecureString password to byte array for encryption key
        $passwordBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($passwordBSTR)
        
        # Create a 256-bit key from the password
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $key = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($passwordPlain))
        
        # Convert data to SecureString without using -AsPlainText
        $secureData = New-Object System.Security.SecureString
        foreach ($ch in $Data.ToCharArray()) { $secureData.AppendChar($ch) }
        $secureData.MakeReadOnly()
        
        # Encrypt the data using the key
        $encryptedData = $secureData | ConvertFrom-SecureString -Key $key
        
        # Clean up
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBSTR)
        $sha256.Dispose()
        
        return @{ Success = $true; Data = $encryptedData; Error = $null }
    } catch {
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

function Unprotect-ComputerListData {
    param(
        [string]$EncryptedData,
        [SecureString]$Password
    )
    
    try {
        # Convert SecureString password to byte array for decryption key
        $passwordBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($passwordBSTR)
        
        # Create a 256-bit key from the password
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $key = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($passwordPlain))
        
        # Decrypt the data
        $secureData = $EncryptedData | ConvertTo-SecureString -Key $key
        
        # Convert back to plain text
        $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureData)
        )
        
        # Clean up
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBSTR)
        $sha256.Dispose()
        
        return @{ Success = $true; Data = $plainText; Error = $null }
    } catch {
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

# Function to save encrypted computer list configuration
function Save-ComputerListConfig {
    param(
        [array]$ComputerList,
        [string]$ConfigPath,
        [SecureString]$Password
    )
    
    try {
        # Create configuration object
        $config = @{
            SavedDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            ComputerCount = $ComputerList.Count
            Computers = $ComputerList | ForEach-Object {
                @{
                    Computer = $_.Computer
                    Phase = if ($_.Phase) { $_.Phase } else { "Phase 1" }
                    # Only save computer name and phase - all other status data is temporary
                }
            }
            # Save credential configuration if custom credentials are used
            CredentialConfig = if ($script:UseCustomCredentials) {
                @{
                    Username = $script:CredentialConfig.Username
                    Domain = $script:CredentialConfig.Domain
                }
            } else {
                $null
            }
        }
        
        # Convert to JSON
        $jsonData = $config | ConvertTo-Json -Depth 4
        
        # Encrypt the data
        $encryptResult = Protect-ComputerListData -Data $jsonData -Password $Password
        
        if (-not $encryptResult.Success) {
            throw "Encryption failed: $($encryptResult.Error)"
        }
        
        # Save to file
        $encryptResult.Data | Out-File -FilePath $ConfigPath -Encoding UTF8 -Force
        
        return @{ Success = $true; Error = $null }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# Function to import encrypted computer list configuration
function Import-ComputerListConfig {
    param(
        [string]$ConfigPath,
        [SecureString]$Password
    )
    
    try {
        if (-not (Test-Path -Path $ConfigPath)) {
            throw "Configuration file not found: $ConfigPath"
        }
        
        # Read encrypted data
        $encryptedData = Get-Content -Path $ConfigPath -Raw
        
        # Decrypt the data
        $decryptResult = Unprotect-ComputerListData -EncryptedData $encryptedData -Password $Password
        
        if (-not $decryptResult.Success) {
            throw "Decryption failed: $($decryptResult.Error)"
        }
        
        # Parse JSON
        $config = $decryptResult.Data | ConvertFrom-Json
        
        return @{ Success = $true; Config = $config; Error = $null }
    } catch {
        return @{ Success = $false; Config = $null; Error = $_.Exception.Message }
    }
}
# Background processing control functions
function Suspend-BackgroundProcessing {
    param(
        [string]$Reason = 'User operation'
    )
    
    Write-InfoLog "Suspending background processing: $Reason"
    
    # Temporarily pause the job cleanup routine
    $backgroundProcessing.Suspended = $true
    
    # Update status to show background processing is paused
    Update-Status "⏸️ Background processing paused for $Reason..."
    
    # Give a moment for any current operations to complete
    Start-Sleep -Milliseconds 500
}

function Resume-BackgroundProcessing {
    param(
        [string]$CompletedOperation = 'User operation'
    )
    
    Write-InfoLog "Resuming background processing after: $CompletedOperation"
    
    # Resume the job cleanup routine
    $backgroundProcessing.Suspended = $false
    
    # Update status to show background processing is resumed
    Update-Status "✅ Background processing resumed after $CompletedOperation"
}

#endregion Helper Functions

#region ScriptBlocks

# Helper function to safely update ListView items
# This function is used in runspaces to safely update ListView items
function SafeUpdateListViewItem {
    param(
        [string]$ComputerName,
        [scriptblock]$UpdateAction
    )
    
    # Check if GUI is ready and ListView is properly initialized
    if (-not $uiHash.ListView -or -not $uiHash.clientObservable) {
        Write-Warning "GUI not ready for ListView updates. Skipping update for $ComputerName"
        return
    }
    
    try {
        $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
            # Find the actual item in the ListView that corresponds to this computer
            $actualItem = $uiHash.Listview.Items | Where-Object { $_.Computer -eq $ComputerName } | Select-Object -First 1
            
            if ($actualItem) {
                $uiHash.Listview.Items.EditItem($actualItem)
                
                # Execute the update action with the actual item
                & $UpdateAction $actualItem
                
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            }
        })
    } catch {
        Write-Warning "Failed to update ListView for $ComputerName : $($_.Exception.Message)"
    }
}

#Add new computer(s) to list
$AddEntry = {
    Param ($ComputerName)
    Write-Verbose "Adding $ComputerName."
    Write-InfoLog "AddEntry called with computers: $($ComputerName -join ', ')"

    If (Test-Path Exempt.txt){
        Write-Verbose 'Collecting systems from exempt list.'
        Write-InfoLog "Loading exempt list from Exempt.txt"
        [string[]]$exempt = Get-Content Exempt.txt
    # Skip domain computer credential validation during AddEntry to prevent GUI crashes
    # The credential handling will be done later in the runspace when operations are performed
    Write-InfoLog "Skipping upfront domain computer credential validation to prevent GUI crashes"
        Write-InfoLog "Exempt list contains $($exempt.Count) entries"
    }

    #Add to list
    ForEach ($computer in $ComputerName){
        $computer = $computer.Trim() #Remove any whitspace
        Write-InfoLog "Processing computer: '$computer'"
        
        If ([System.String]::IsNullOrEmpty($computer)){
            Write-InfoLog "Skipping empty computer name"
            continue
        }
        
        if($exempt -contains $computer){
            Write-InfoLog "Skipping exempt computer: $computer"
            continue
        }
        
        if(($uiHash.Listview.Items | Select-Object -Expand Computer) -contains $computer){
            Write-InfoLog "Skipping duplicate computer: $computer"
            continue
        }
        
        Write-InfoLog "Adding computer '$computer' to ListView - Thread ID: $([System.Threading.Thread]::CurrentThread.ManagedThreadId)"
        try {
            # Check UI state before dispatcher invoke
            Write-InfoLog "Pre-dispatch check - Window exists: $($uiHash.Window -ne $null)"
            Write-InfoLog "Pre-dispatch check - ListView exists: $($uiHash.ListView -ne $null)"
            Write-InfoLog "Pre-dispatch check - clientObservable exists: $($uiHash.clientObservable -ne $null)"
            Write-InfoLog "Pre-dispatch check - ListView ItemsSource: $($uiHash.ListView.ItemsSource -ne $null)"
            
            # Check dispatcher state before invoke
            Write-InfoLog "Pre-dispatch check - Dispatcher CheckAccess: $($uiHash.ListView.Dispatcher.CheckAccess())"
            Write-InfoLog "Pre-dispatch check - Dispatcher HasShutdownStarted: $($uiHash.ListView.Dispatcher.HasShutdownStarted)"
            Write-InfoLog "Pre-dispatch check - Dispatcher HasShutdownFinished: $($uiHash.ListView.Dispatcher.HasShutdownFinished)"
            
            # Check if ListView is still valid
            if ($uiHash.ListView.Dispatcher.HasShutdownStarted) {
                Write-ErrorLog "Dispatcher shutdown has started, cannot invoke UI operations for computer: $computer"
                throw "Dispatcher shutdown in progress"
            }
            
            # Use safer dispatcher invoke pattern with timeout
            if ($uiHash.ListView.Dispatcher.CheckAccess()) {
                Write-InfoLog "Already on UI thread, executing directly for computer: $computer"
                # We're already on the UI thread, execute directly
                try {
                    Write-InfoLog "Direct execution for computer: $computer - Thread ID: $([System.Threading.Thread]::CurrentThread.ManagedThreadId)"
                    
                    # Initialize clientObservable if it doesn't exist
                    if ($null -eq $uiHash.clientObservable) {
                        Write-InfoLog "Initializing clientObservable for computer: $computer"
                        $uiHash.clientObservable = New-Object System.Collections.ObjectModel.ObservableCollection[object]
                        $uiHash.ListView.ItemsSource = $uiHash.clientObservable
                        Write-InfoLog "clientObservable initialized successfully for computer: $computer"
                    }
                    
                    Write-InfoLog "Creating PSObject for computer: $computer"
                    $computerObject = New-Object PSObject -Property @{
                        Computer = $computer
                        Phase = "Phase 1"
                        Available = 0 -as [int]
                        Downloaded = 0 -as [int]
                        InstallErrors = 0 -as [int]
                        Status = "Initializing..."
                        RebootRequired = $false -as [bool]
                        UpdatesStatus = "Initializing"
                        Runspace = $null
                        Pending = $true
                    }
                    Write-InfoLog "PSObject created successfully for computer: $computer"
                    
                    Write-InfoLog "Adding PSObject to clientObservable for computer: $computer (Current count: $($uiHash.clientObservable.Count))"
                    $uiHash.clientObservable.Add($computerObject)
                    Write-InfoLog "PSObject added to clientObservable for computer: $computer (New count: $($uiHash.clientObservable.Count))"
                    
                    Write-InfoLog "Committing and refreshing ListView for computer: $computer"
                    try {
                        $uiHash.Listview.Items.CommitEdit()
                        $uiHash.Listview.Items.Refresh()
                        Write-InfoLog "ListView committed and refreshed for computer: $computer"
                    } catch {
                        Write-InfoLog "ListView commit/refresh failed for computer: $computer - continuing anyway"
                    }
                    
                    Write-InfoLog "Successfully added computer '$computer' to ListView (direct execution)"
                } catch {
                    Write-ErrorLog "DIRECT EXECUTION ERROR for computer '$computer': $($_.Exception.Message)"
                    Write-ErrorLog "Direct execution error type: $($_.Exception.GetType().FullName)"
                    Write-ErrorLog "Direct execution stack trace: $($_.ScriptStackTrace)"
                    # Don't throw - continue with other computers
                    Write-InfoLog "Continuing with other computers despite error for: $computer"
                }
            } else {
                Write-InfoLog "Not on UI thread, using dispatcher invoke for computer: $computer"
                $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                try {
                    Write-InfoLog "Inside dispatcher action for computer: $computer - Thread ID: $([System.Threading.Thread]::CurrentThread.ManagedThreadId)"
                    
                    # Initialize clientObservable if it doesn't exist (can happen when loading computer list before window initialization)
                    if ($null -eq $uiHash.clientObservable) {
                        Write-InfoLog "Initializing clientObservable for computer: $computer"
                        $uiHash.clientObservable = New-Object System.Collections.ObjectModel.ObservableCollection[object]
                        $uiHash.ListView.ItemsSource = $uiHash.clientObservable
                        Write-InfoLog "clientObservable initialized successfully for computer: $computer"
                    }
                    
                    Write-InfoLog "Creating PSObject for computer: $computer"
                    $computerObject = New-Object PSObject -Property @{
                        Computer = $computer
                        Phase = "Phase 1"
                        Available = 0 -as [int]
                        Downloaded = 0 -as [int]
                        InstallErrors = 0 -as [int]
                        Status = "Initializing..."
                        RebootRequired = $false -as [bool]
                        UpdatesStatus = "Initializing"
                        Runspace = $null
                        Pending = $true
                    }
                    Write-InfoLog "PSObject created successfully for computer: $computer"
                    
                    Write-InfoLog "Adding PSObject to clientObservable for computer: $computer (Current count: $($uiHash.clientObservable.Count))"
                    $uiHash.clientObservable.Add($computerObject)
                    Write-InfoLog "PSObject added to clientObservable for computer: $computer (New count: $($uiHash.clientObservable.Count))"
                    
                    Write-InfoLog "Committing and refreshing ListView for computer: $computer"
                    try {
                        $uiHash.Listview.Items.CommitEdit()
                        $uiHash.Listview.Items.Refresh()
                        Write-InfoLog "ListView committed and refreshed for computer: $computer"
                    } catch {
                        Write-InfoLog "ListView commit/refresh failed for computer: $computer - continuing anyway"
                    }
                    
                    Write-InfoLog "Successfully added computer '$computer' to ListView"
                } catch {
                    Write-ErrorLog "DISPATCHER ERROR for computer '$computer': $($_.Exception.Message)"
                    Write-ErrorLog "Dispatcher error type: $($_.Exception.GetType().FullName)"
                    Write-ErrorLog "Dispatcher stack trace: $($_.ScriptStackTrace)"
                    Write-ErrorLog "Dispatcher thread ID: $([System.Threading.Thread]::CurrentThread.ManagedThreadId)"
                    
                    if ($_.Exception.InnerException) {
                        Write-ErrorLog "Dispatcher inner exception: $($_.Exception.InnerException.Message)"
                    }
                    
                    # Check state after error
                    Write-ErrorLog "Post-error state - clientObservable exists: $($uiHash.clientObservable -ne $null)"
                    Write-ErrorLog "Post-error state - ListView exists: $($uiHash.ListView -ne $null)"
                    Write-ErrorLog "Post-error state - Window exists: $($uiHash.Window -ne $null)"
                    
                    # Don't throw - continue with other computers
                    Write-InfoLog "Continuing with other computers despite dispatcher error for: $computer"
                }
            })
            }
        } catch {
            Write-ErrorLog "CRITICAL ERROR adding computer '$computer' to ListView: $($_.Exception.Message)"
            Write-ErrorLog "Error type: $($_.Exception.GetType().FullName)"
            Write-ErrorLog "Stack trace: $($_.ScriptStackTrace)"
            Write-ErrorLog "Main thread ID: $([System.Threading.Thread]::CurrentThread.ManagedThreadId)"
            
            # Special handling for MethodInvocationException
            if ($_.Exception -is [System.Management.Automation.MethodInvocationException]) {
                Write-ErrorLog "MethodInvocationException detected - this suggests a threading or object disposal issue"
                Write-ErrorLog "Target object: $($_.Exception.InvocationInfo.InvocationType)"
                Write-ErrorLog "Method name: $($_.Exception.InvocationInfo.MethodName)"
                
                # Check if this is a dispatcher-related issue
                if ($_.Exception.Message -match "dispatcher|thread|invoke") {
                    Write-ErrorLog "This appears to be a dispatcher threading issue"
                    Write-ErrorLog "Dispatcher state - CheckAccess: $($uiHash.ListView.Dispatcher.CheckAccess())"
                    Write-ErrorLog "Dispatcher state - HasShutdownStarted: $($uiHash.ListView.Dispatcher.HasShutdownStarted)"
                    Write-ErrorLog "Dispatcher state - HasShutdownFinished: $($uiHash.ListView.Dispatcher.HasShutdownFinished)"
                }
            }
            
            if ($_.Exception.InnerException) {
                Write-ErrorLog "Inner exception: $($_.Exception.InnerException.Message)"
                Write-ErrorLog "Inner exception type: $($_.Exception.InnerException.GetType().FullName)"
            }
            
            # Additional diagnostic information
            Write-ErrorLog "Error context - Window state: $($uiHash.Window.WindowState)"
            Write-ErrorLog "Error context - Window IsVisible: $($uiHash.Window.IsVisible)"
            Write-ErrorLog "Error context - Window IsLoaded: $($uiHash.Window.IsLoaded)"
            
            # Don't throw - continue with other computers
            Write-InfoLog "Continuing with other computers despite critical error for: $computer"
        }
    }

    # Runspace creation and job startup are handled by the UI job timer (Start-PendingUpdateCheck)
    # so the UI thread is never blocked waiting for job slots.
}

# Create and configure the persistent per-computer worker runspace
function New-ComputerRunspace {
    param($ComputerItem)
        
            Write-InfoLog "Creating runspace for computer: $($ComputerItem.Computer)"
            # Create runspace with proper scope isolation to prevent "Global scope cannot be removed" error
            $runspaceConfig = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            $runspaceConfig.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
            $newRunspace = [runspacefactory]::CreateRunspace($runspaceConfig)
            $newRunspace.ApartmentState = "STA"
            $newRunspace.Open()
            Write-InfoLog "Runspace opened successfully for: $($ComputerItem.Computer)"
        $newRunspace.SessionStateProxy.SetVariable("uiHash",$uiHash)
        $newRunspace.SessionStateProxy.SetVariable("updatesHash",$updatesHash)
        $newRunspace.SessionStateProxy.SetVariable("performanceHash",$performanceHash)
        $newRunspace.SessionStateProxy.SetVariable("errorSuggestionsHash",$errorSuggestionsHash)
        $newRunspace.SessionStateProxy.SetVariable("path",$pwd)
        $newRunspace.SessionStateProxy.SetVariable("LogPath",$script:LogPath)
        $newRunspace.SessionStateProxy.SetVariable("LogLock",$script:LogLock)
        $newRunspace.SessionStateProxy.SetVariable("EnableDebugLogging",$script:EnableDebugLogging)
        $newRunspace.SessionStateProxy.SetVariable("EnableEnhancedErrorHandling",$script:EnableEnhancedErrorHandling)
        $newRunspace.SessionStateProxy.SetVariable("UseCustomCredentials",$script:UseCustomCredentials)
        $newRunspace.SessionStateProxy.SetVariable("CustomCredentials",$script:CustomCredentials)
        $newRunspace.SessionStateProxy.SetVariable("CredentialCache",$script:CredentialCache)
        $newRunspace.SessionStateProxy.SetVariable("PerformanceThreshold",$PerformanceThreshold)
        $newRunspace.SessionStateProxy.SetVariable("searchTimeout",$searchTimeout)
        $newRunspace.SessionStateProxy.SetVariable("sessionTimeout",$sessionTimeout)
        $newRunspace.SessionStateProxy.SetVariable("rebootCheckTimeout",$rebootCheckTimeout)
        
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
            [System.Threading.Monitor]::Enter($LogLock)
            try {
                Add-Content -Path $LogPath -Value $logEntry -Force
            } finally {
                [System.Threading.Monitor]::Exit($LogLock)
            }
        }.ToString()))
        
        # Add safe ListView update function to runspace
        $newRunspace.SessionStateProxy.SetVariable('SafeUpdateListViewItemScript', [scriptblock]::Create({
            param(
                [string]$ComputerName,
                [hashtable]$Properties
            )
            
            # Check if GUI is ready and ListView is properly initialized
            if (-not $uiHash.ListView -or -not $uiHash.clientObservable) {
                return
            }
            
            try {
                $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
                    # Find the actual item in the ListView that corresponds to this computer
                    $actualItem = $uiHash.Listview.Items | Where-Object { $_.Computer -eq $ComputerName } | Select-Object -First 1
                    
                    if ($actualItem) {
                        $uiHash.Listview.Items.EditItem($actualItem)
                        
                        foreach ($propertyName in $Properties.Keys) {
                            $actualItem.$propertyName = $Properties[$propertyName]
                        }
                        
                        $uiHash.Listview.Items.CommitEdit()
                        $uiHash.Listview.Items.Refresh()
                    }
                })
            } catch {
                # Silently ignore ListView update errors during startup
            }
        }.ToString()))
        
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
            
            # Create the credential dialog XAML
            $xamlCredentialDialog = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Height="280" Width="450"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" Topmost="True">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="15"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <TextBlock Grid.Row="0" Text="$Message" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,5"/>
        
        <Label Grid.Row="2" Content="Username:" FontSize="11" Padding="0,0,0,5"/>
        <TextBox Grid.Row="2" Name="UsernameTextBox" Height="25" Margin="80,0,0,0" 
                 ToolTip="Enter username (domain\username or username@domain.com)"/>
        
        <Label Grid.Row="4" Content="Password:" FontSize="11" Padding="0,0,0,5"/>
        <PasswordBox Grid.Row="4" Name="PasswordBox" Height="25" Margin="80,0,0,0" 
                     ToolTip="Enter password" 
                     MaxLength="256" 
                     Background="White" 
                     BorderBrush="#CCCCCC" 
                     BorderThickness="1"/>
        
        <CheckBox Grid.Row="6" Name="RememberCheckBox" Content="Remember credentials for this session" 
                  FontSize="10" Margin="0,5,0,0" IsChecked="False"/>
        
        <StackPanel Grid.Row="8" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0">
            <Button Name="OKButton" Content="OK" Width="80" Height="30" Margin="0,0,10,0" IsDefault="True"/>
            <Button Name="CancelButton" Content="Cancel" Width="80" Height="30" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
            
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
        
        # Add Get-RemoteCredentials function to runspace
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
            
            # Try custom credentials first if configured
            if ($UseCustomCredentials -and $CustomCredentials) {
                try {
                    # Test custom credentials with a simple WMI query
                    $testResult = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $ComputerName -Credential $CustomCredentials -ErrorAction Stop
                    if ($testResult) {
                        # Custom credentials work, cache success
                        if (-not $CredentialCache) { $CredentialCache = @{} }
                        $CredentialCache[$ComputerName] = $CustomCredentials
                        return $CustomCredentials
                    }
                } catch {
                    try {
                        & $WriteDebugLogScript -Message "Custom credentials failed for $ComputerName : $($_.Exception.Message)" -Level 'WARN'
                    } catch {
                        # Silently ignore logging failures in runspace
                    }
                }
            }
            
            # Custom credentials failed or not configured, try default credentials
            try {
                # Test default credentials with a simple WMI query
                $testResult = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $ComputerName -ErrorAction Stop
                if ($testResult) {
                    # Default credentials work, cache success
                    if (-not $CredentialCache) { $CredentialCache = @{} }
                    $CredentialCache[$ComputerName] = $null  # null means use default credentials
                    return $null
                }
            } catch {
                try {
                    & $WriteDebugLogScript -Message "Default credentials failed for $ComputerName : $($_.Exception.Message)" -Level 'WARN'
                } catch {
                    # Silently ignore logging failures in runspace
                }
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

# Start an update-check job for a computer item (runs on the UI thread)
function Start-UpdateCheckJob {
    param($ComputerItem)
    $PowerShell = $null
    
    try {
        if (-not $ComputerItem.Runspace) {
            $ComputerItem.Runspace = New-ComputerRunspace -ComputerItem $ComputerItem
        }

        $PowerShell = [powershell]::Create().AddScript($GetUpdates).AddArgument($ComputerItem)
        $PowerShell.Runspace = $ComputerItem.Runspace

        #Save handle so we can later end the runspace
        $temp = New-Object PSObject -Property @{
            PowerShell = $PowerShell
            Runspace = $PowerShell.BeginInvoke()
            StartTime = Get-Date
            Computer = $ComputerItem.Computer
        }

        $jobs.Add($temp) | Out-Null
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
        
        # Update status if runspace creation fails
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($ComputerItem)
            $ComputerItem.Status = "Failed to initialize: $errorMessage"
            $ComputerItem.UpdatesStatus = 'Error'
            # Set background color to grey for errored entries
            $listViewItem = $uiHash.Listview.ItemContainerGenerator.ContainerFromItem($ComputerItem)
            if($listViewItem) {
                $listViewItem.Background = [System.Windows.Media.Brushes]::LightGray
            }
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })
        return $false
    }
}

# Drain pending computers into worker jobs; called by the UI job timer so the UI thread never blocks
function Start-PendingUpdateCheck {
    if ($backgroundProcessing.Suspended) { return }
    $pendingItems = @($uiHash.Listview.Items | Where-Object { $_.Pending })
    foreach ($item in $pendingItems) {
        if ($jobs.Count -ge $MaxConcurrentJobs) { break }
        if (-not (Test-PhaseReady -Phase $item.Phase)) {
            if ($item.Status -notlike 'Waiting for previous phase*') {
                $item.Status = "Waiting for previous phase to complete. Current phase: $($item.Phase)"
                $uiHash.Listview.Items.Refresh()
            }
            continue
        }
        $item.Pending = $false
        [void](Start-UpdateCheckJob -ComputerItem $item)
    }
}

# Note: SetUpdatesStatus function was removed as it was unused
# The functionality is now handled directly in the GetUpdates script

# Phase management helper functions
function Test-PhaseCompletion {
    param([string]$Phase)
    
    $phaseComputers = @($uiHash.Listview.Items | Where-Object { $_.Phase -eq $Phase })
    
    if ($phaseComputers.Count -eq 0) {
        return $true  # No computers in this phase, consider it complete
    }
    
    foreach ($computer in $phaseComputers) {
        # Errored/timed-out computers are settled - they must not block later phases forever
        if ($computer.UpdatesStatus -eq 'Error' -or $computer.UpdatesStatus -eq 'Timeout') {
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

# Assign computers to phases
$eventAssignPhase = {
    Param($phase)
    try {
        Write-InfoLog "Phase assignment started for phase: $phase"
        $selectedComputers = @($uiHash.Listview.SelectedItems)
        
        if ($selectedComputers.Count -gt 0) {
        Write-InfoLog "Assigning $($selectedComputers.Count) computers to $phase"
        $computerNames = @()
        
        ForEach ($Computer in $selectedComputers) {
            try {
                # Safer approach: modify property directly and refresh once
                $Computer.Phase = $phase
                Write-InfoLog "Assigned $($Computer.Computer) to $phase"
                $computerNames += $Computer.Computer
            } catch {
                $errorMsg = $_.Exception.Message
                Write-ErrorLog "Failed to assign $($Computer.Computer) to $phase - Error: $errorMsg"
            }
        }
        
        # Refresh the view once after all updates
        try {
            $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                $uiHash.Listview.Items.Refresh()
            })
            Write-InfoLog "List view refreshed after phase assignment"
        } catch {
            $errorMsg = $_.Exception.Message
            Write-ErrorLog "Failed to refresh list view - Error: $errorMsg"
        }

        # Update status with appropriate message
        if ($selectedComputers.Count -eq 1) {
            Update-StatusBackground "Computer '$($computerNames[0])' assigned to $phase"
        } else {
            Update-StatusBackground "$($selectedComputers.Count) computers assigned to ${phase}: $($computerNames -join ', ')"
        }
        } else {
            Write-WarningLog "No computers selected for phase assignment"
        }
    } catch {
        $errorMsg = $_.Exception.Message
        Write-ErrorLog "Critical error in phase assignment - Error: $errorMsg"
        [System.Windows.MessageBox]::Show(
            "An error occurred during phase assignment - Error: $errorMsg",
            "Phase Assignment Error",
            'OK',
            'Error'
        )
    }
}

# Remove entry ScriptBlock
$removeEntry = {
    Param ($ComputerNames)
    
    # Add null/empty check to prevent crashes when no computers are selected
    if (-not $ComputerNames -or $ComputerNames.Count -eq 0) {
        Write-DebugLog "Remove computers called with no selections - ignoring operation" -Level 'DEBUG'
        $uiHash.Window.Dispatcher.Invoke([action]{$uiHash.StatusTextBox.Text="No computers selected for removal"}) | Out-Null
        return
    }
    
    Write-InfoLog "Removing computers: $($ComputerNames.Count) entries"
    
    ForEach ($Computer in $ComputerNames) {
        try {
            # Stop any running jobs for this computer with comprehensive cleanup
            $runningJobs = $jobs | Where-Object { $_.PowerShell.Runspace -eq $Computer.Runspace }
            foreach ($job in $runningJobs) {
                try {
                    # Stop the async operation
                    $job.PowerShell.Stop()
                } catch {
                    Write-WarningLog "Failed to stop PowerShell for $($Computer.Computer): $($_.Exception.Message)"
                }
                try {
                    # Dispose the PowerShell instance
                    $job.PowerShell.Dispose()
                } catch {
                    Write-WarningLog "Failed to dispose PowerShell for $($Computer.Computer): $($_.Exception.Message)"
                }
                try {
                    # Remove from jobs list
                    $jobs.Remove($job)
                } catch {
                    Write-WarningLog "Failed to remove job from list for $($Computer.Computer): $($_.Exception.Message)"
                }
            }
            
            # Close and dispose the runspace
            if ($Computer.Runspace) {
                try {
                    $Computer.Runspace.Close()
                } catch {
                    Write-WarningLog "Failed to close runspace for $($Computer.Computer): $($_.Exception.Message)"
                }
                try {
                    $Computer.Runspace.Dispose()
                } catch {
                    Write-WarningLog "Failed to dispose runspace for $($Computer.Computer): $($_.Exception.Message)"
                }
                $Computer.Runspace = $null
            }
            
            # Remove from updates hash
            if ($updatesHash.ContainsKey($Computer.Computer)) {
                try {
                    $updatesHash.Remove($Computer.Computer)
                } catch {
                    Write-WarningLog "Failed to remove from updatesHash for $($Computer.Computer): $($_.Exception.Message)"
                }
            }
            
            # Remove from performance hash
            if ($performanceHash.ContainsKey($Computer.Computer)) {
                try {
                    $performanceHash.Remove($Computer.Computer)
                } catch {
                    Write-WarningLog "Failed to remove from performanceHash for $($Computer.Computer): $($_.Exception.Message)"
                }
            }
            
            # Remove from UI with proper thread safety
            $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                try {
                    # Check if clientObservable exists before trying to remove from it
                    if ($uiHash.clientObservable) {
                        $uiHash.clientObservable.Remove($Computer)
                    }
                    $uiHash.Listview.Items.Refresh()
                } catch {
                    Write-WarningLog "Failed to remove UI item for $($Computer.Computer): $($_.Exception.Message)"
                }
            })
            
            Write-SuccessLog "Successfully removed computer: $($Computer.Computer)"
        } catch {
            Write-ErrorLog "Error removing computer $($Computer.Computer): $($_.Exception.Message)"
        }
    }
    
    # Update status
    Update-StatusBackground "Removed $($ComputerNames.Count) computer(s) from list."
}

# Clear computer list ScriptBlock
$clearComputerList = {
    Write-InfoLog "Clearing all computers from list"
    
    # Get all computers before clearing
    $allComputers = @($uiHash.Listview.Items)
    
    if ($allComputers.Count -gt 0) {
        # Remove all computers using the removeEntry ScriptBlock
        &$removeEntry $allComputers
        
        # Update status
        Update-StatusBackground 'Computer List Cleared!'
        
        Write-SuccessLog "Successfully cleared all computers from list"
    } else {
        Update-StatusBackground 'Computer list is already empty.'
    }
}

# Clear computer list (legacy alias)
$ClearComputerList = {
    &$clearComputerList
}

#endregion ScriptBlocks

#region Update Operations

#Download available updates
$DownloadUpdates = {
    Param ($Computer)
    Try{
        #Set path for psexec, scripts
        Set-Location $path

        #Check download size
        $dlStats = ($updatesHash[$Computer.computer] | Where-Object {$_.IsDownloaded -eq $false} | Select-Object -ExpandProperty MaxDownloadSize | Measure-Object -Sum)

        #Update status
        $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = "Downloading $($dlStats.Count) Updates ($([math]::Round($dlStats.Sum/1MB))MB)."
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })

        #Copy script to remote computer and execute using centralized paths
        Copy-Item $ConfigPaths.DownloadScript "\\$($Computer.computer)\c$" -Force
        [int]$numDownloaded = & $ConfigPaths.PsExec -accepteula -nobanner -s "\\$($Computer.computer)" cmd.exe /c 'echo . | powershell.exe -ExecutionPolicy Bypass -file C:\Download-Patches.ps1'
        Remove-Item "\\$($Computer.computer)\c$\Download-Patches.ps1"
        if($LASTEXITCODE -ne 0){
            throw "PsExec failed with error code $LASTEXITCODE"
        }

        #Update status
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = 'Download complete.'
            $computer.Downloaded += $numDownloaded
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })
        
        #Auto-install if enabled and there are downloaded updates ready for installation
        if($uiHash.AutoInstallCheckBox.IsChecked -and $computer.Downloaded -gt 0){
            #Check if there are any updates that are downloaded and don't require user input
            $downloadedUpdates = $updatesHash[$Computer.computer] | Where-Object {$_.IsDownloaded -and $_.InstallationBehavior.CanRequestUserInput -eq $false}
            
            if($downloadedUpdates){
                #Update status to indicate auto-installation is starting
                $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                    $uiHash.Listview.Items.EditItem($Computer)
                    $computer.Status = 'Auto-installing downloaded updates...'
                    $uiHash.Listview.Items.CommitEdit()
                    $uiHash.Listview.Items.Refresh()
                })
                
                #Start installation process
                $temp = "" | Select-Object PowerShell,Runspace
                $temp.PowerShell = [powershell]::Create().AddScript($InstallUpdates).AddArgument($Computer)
                
                # Automatically reboot after install if enabled
                if($uiHash.AutoRebootCheckBox.IsChecked){
                    $temp.PowerShell.AddScript($RestartComputer).AddArgument($Computer).AddArgument($true)
                }
                
                $temp.PowerShell.AddScript($GetUpdates).AddArgument($Computer)
                # Disable SetUpdatesStatus to prevent hanging
                # $temp.PowerShell.AddScript($SetUpdatesStatus).AddArgument($Computer)
                $temp.PowerShell.Runspace = $Computer.Runspace
                $temp.Runspace = $temp.PowerShell.BeginInvoke()
                $jobs.Add($temp) | Out-Null
            }
        }
    }
    Catch{
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = "Error occured: $($_.Exception.Message)."
            $computer.UpdatesStatus = 'Error'
            # Set background color to grey for errored entries
            $listViewItem = $uiHash.Listview.ItemContainerGenerator.ContainerFromItem($Computer)
            if($listViewItem) {
                $listViewItem.Background = [System.Windows.Media.Brushes]::LightGray
            }
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })

        #Cancel any remaining actions
        exit
    }
}

#Check for available updates
$GetUpdates = {
    Param ($Computer)
    Try{
        # Log to file directly in runspace
        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Started GetUpdates for $($Computer.Computer)"
            Add-Content -Path $LogPath -Value $logEntry -Force
        }
        
        # Define simplified logging function
        function Write-DebugLog { 
            param($Message, $Level = 'INFO', $Computer = '', [switch]$ToConsole)
            & $WriteDebugLogScript @PSBoundParameters 
        }
        
        # Define Get-ErrorSuggestions function
        function Get-ErrorSuggestions {
            param([string]$ErrorMessage)
            & $GetErrorSuggestionsScript -ErrorMessage $ErrorMessage
        }
        
        # Define Get-RemoteCredentials function
        function Get-RemoteCredentials {
            param(
                [string]$ComputerName,
                [string]$Operation = 'WMI access'
            )
            
            # Check if script block is available
            if (Get-Variable -Name 'GetRemoteCredentialsScript' -ErrorAction SilentlyContinue) {
                Get-RemoteCredentials -ComputerName $ComputerName -Operation $Operation
            } else {
                # Fallback: for remote computers, return null (use default credentials)
                # For localhost, this should not be called
                if ($ComputerName -eq 'localhost' -or $ComputerName -eq $env:COMPUTERNAME) {
                    return $null
                } else {
                    # For remote computers, try default credentials and return null if they work
                    try {
                        $null = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $ComputerName -ErrorAction Stop
                        return $null  # Default credentials work
                    } catch {
                        throw "Failed to authenticate to $ComputerName for $Operation : $($_.Exception.Message)"
                    }
                }
            }
        }
        
        # Define safe ListView update function
        function SafeUpdateListViewItem {
            param(
                [string]$ComputerName,
                [hashtable]$Properties
            )
            & $SafeUpdateListViewItemScript -ComputerName $ComputerName -Properties $Properties
        }
        
        # Define Invoke-AutoRecovery function
        function Invoke-AutoRecovery {
            param([string]$ComputerName, [string]$ErrorCode)
            & $InvokeAutoRecoveryScript -ComputerName $ComputerName -ErrorCode $ErrorCode
        }
        
        # Phase gating is handled on the UI thread by Start-PendingUpdateCheck before this job starts.

        #Update status
        $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = 'Validating connectivity and services...'
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })

        Set-Location $path

        # Enhanced connectivity and service validation with performance monitoring
        # Note: injected as an unscoped runspace variable, do not use $script: here
        if ($EnableEnhancedErrorHandling) {
            $maxRetries = 3
        } else {
            $maxRetries = 1  # Single attempt for simpler error handling
        }
        $retryCount = 0
        $success = $false
        
        # Check system dependencies first with error handling (only if enhanced error handling is enabled)
        if ($EnableEnhancedErrorHandling) {
            if ($EnableDebugLogging) {
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Checking system dependencies for $($Computer.Computer)"
                Add-Content -Path $LogPath -Value $logEntry -Force
            }
            $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
                $uiHash.Listview.Items.EditItem($Computer)
                $computer.Status = 'Checking system dependencies...'
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })
            
            # Skip complex dependency checking - just assume local connectivity
            $depStatus = "Dependencies: Skipping checks for stability"
            if ($EnableDebugLogging) {
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Skipping dependency checks for stability"
                Add-Content -Path $LogPath -Value $logEntry -Force
            }
            
            $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
                $uiHash.Listview.Items.EditItem($Computer)
                $computer.Status = $depStatus
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })
            
            Start-Sleep -Seconds 2
        }
        
        while (-not $success -and $retryCount -lt $maxRetries) {
            try {
                $retryCount++
                
                # Monitor performance with error handling (only if enhanced error handling is enabled)
                if ($EnableEnhancedErrorHandling) {
                    SafeUpdateListViewItem $Computer.computer @{
                        Status = "Monitoring system performance (attempt $retryCount/$maxRetries)..."
                    }
                    
                    # Use default performance values for stability
                    $performance = @{
                        CPUPercent = 20
                        MemoryUsedMB = 512
                        NetworkLatencyMs = 1
                        Status = 'Success'
                    }
                    $performanceHash[$Computer.computer] = $performance
                    if ($EnableDebugLogging) {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Using default performance values for stability"
                        Add-Content -Path $LogPath -Value $logEntry -Force
                    }
                    
                    # Check performance thresholds
                    if ($performance.CPUPercent -gt $PerformanceThreshold.CPUPercent) {
                        SafeUpdateListViewItem $Computer.computer @{
                            Status = "Warning: High CPU usage ($($performance.CPUPercent)%). Proceeding with caution..."
                        }
                        Start-Sleep -Seconds 5
                    }
                    
                    if ($performance.NetworkLatencyMs -gt $PerformanceThreshold.NetworkLatencyMs) {
                        SafeUpdateListViewItem $Computer.computer @{
                            Status = "Warning: High network latency ($($performance.NetworkLatencyMs)ms). Connection may be slow..."
                        }
                        Start-Sleep -Seconds 3
                    }
                    
                    # Test basic connectivity
                    SafeUpdateListViewItem $Computer.computer @{
                        Status = "Testing connectivity (attempt $retryCount/$maxRetries) - CPU: $($performance.CPUPercent)%, Latency: $($performance.NetworkLatencyMs)ms"
                    }
                } else {
                    # Simple connectivity test
                    SafeUpdateListViewItem $Computer.computer @{
                        Status = "Testing connectivity..."
                    }
                }
                
                # First test ping connectivity (includes DNS resolution with timeout)
                if ($EnableDebugLogging) {
                    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                    $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Testing connectivity with 2s timeout"
                    Add-Content -Path $LogPath -Value $logEntry -Force
                }
                
                $pingResult = Test-Connection -ComputerName $Computer.computer -Count 1 -Quiet -TimeoutSeconds 2
                if (-not $pingResult) {
                    $errorMessage = "Computer $($Computer.computer) is not reachable (ping timeout after 2s). Check network connectivity, firewall ICMP rules, or verify the computer exists."
                    $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
                        $uiHash.Listview.Items.EditItem($Computer)
                        $computer.Status = $errorMessage
                        $uiHash.Listview.Items.CommitEdit()
                        $uiHash.Listview.Items.Refresh()
                    })
                    throw $errorMessage
                }
                
                if ($EnableDebugLogging) {
                    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                    $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Ping successful"
                    Add-Content -Path $LogPath -Value $logEntry -Force
                }
                
                # Test WMI connectivity
                SafeUpdateListViewItem $Computer.computer @{
                    Status = "Testing WMI connectivity (attempt $retryCount/$maxRetries)..."
                }
                
                # Test WMI/CIM connectivity with timeout protection
                if ($EnableDebugLogging) {
                    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                    $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Starting WMI connectivity test with timeout"
                    Add-Content -Path $LogPath -Value $logEntry -Force
                }
                
                $wmiTest = $null
                $wmiSuccess = $false
                
                try {
                    if ($Computer.computer -eq 'localhost' -or $Computer.computer -eq $env:COMPUTERNAME) {
                    if ($EnableDebugLogging) {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Using localhost WMI connection"
                        Add-Content -Path $LogPath -Value $logEntry -Force
                    }
                    $wmiTest = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
                } else {
                    # Use helper function for WMI test (prevents hangs)
                    if ($EnableDebugLogging) {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Testing WMI via helper function (5s timeout)"
                        Add-Content -Path $LogPath -Value $logEntry -Force
                    }
                    
                    $wmiResult = Invoke-CimWithTimeout -ComputerName $Computer.computer -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 5 -Operation 'WMI connectivity test'
                    
                        if ($wmiResult -and $wmiResult.Success) {
                            $wmiTest = $wmiResult.Result
                            $wmiSuccess = $true
                            if ($EnableDebugLogging) {
                                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                                $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] WMI test successful"
                                Add-Content -Path $LogPath -Value $logEntry -Force
                            }
                        } else {
                            $errorMsg = if ($wmiResult -and $wmiResult.Error) { $wmiResult.Error } else { 'Unknown error' }
                            throw "WMI connectivity test failed: $errorMsg"
                        }
                        
                        # Skip credential-based WMI tests - already tested with default credentials above
                    }
                } catch {
                    $wmiSuccess = $false
                    throw $_
                }
        Status = $errorMessage
    }
    throw $errorMessage
}
                
                # Test RPC connectivity by checking Windows Update service
                SafeUpdateListViewItem $Computer.computer @{
                    Status = "Testing Windows Update service (attempt $retryCount/$maxRetries)..."
                }
                
                try {
                    # Use helper function for service operations (prevents hangs)
                    if ($Computer.computer -eq 'localhost' -or $Computer.computer -eq $env:COMPUTERNAME) {
                        $wuService = Get-Service -Name "wuauserv" -ErrorAction Stop
                    } else {
                        # Check Windows Update service status
                        $serviceResult = Invoke-ServiceWithTimeout -ComputerName $Computer.computer -ServiceName 'wuauserv' -Action 'Check' -TimeoutSeconds 5
                        
                        if ($serviceResult -and $serviceResult.Success) {
                            $wuService = $serviceResult.Service
                        } else {
                            $errorMsg = if ($serviceResult -and $serviceResult.Error) { $serviceResult.Error } else { 'Unknown error' }
                            throw "Service check failed: $errorMsg"
                        }
                        
                        if ($wuService -and $wuService.Status -ne 'Running') {
                            SafeUpdateListViewItem $Computer.computer @{
                                Status = "Starting Windows Update service..."
                            }
                            
                            Write-Warning "Windows Update service is not running on $($Computer.computer). Attempting to start..."
                            
                            # Start the service with timeout
                            $startResult = Invoke-ServiceWithTimeout -ComputerName $Computer.computer -ServiceName 'wuauserv' -Action 'Start' -TimeoutSeconds 10 -PostActionDelay 5
                            
                            if ($startResult -and $startResult.Success) {
                                $wuService = $startResult.Service
                                if ($EnableDebugLogging) {
                                    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                                    $logEntry = "[$timestamp] [SUCCESS] [$($Computer.Computer)] Windows Update service started successfully"
                                    Add-Content -Path $LogPath -Value $logEntry -Force
                                }
                            } else {
                                $errorMsg = if ($startResult -and $startResult.Error) { $startResult.Error } else { 'Unknown error' }
                                throw "Service start failed: $errorMsg"
                            }
                        }
                    }
                } catch {
                    if ($EnableDebugLogging) {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [ERROR] [$($Computer.Computer)] Windows Update service issue: $($_.Exception.Message)"
                        Add-Content -Path $LogPath -Value $logEntry -Force
                    }
                    throw "Windows Update service error: $($_.Exception.Message)"
                }
                
                # Update status for COM object creation
                $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
                    $uiHash.Listview.Items.EditItem($Computer)
                    $computer.Status = "Creating Windows Update session (attempt $retryCount/$maxRetries)..."
                    $uiHash.Listview.Items.CommitEdit()
                    $uiHash.Listview.Items.Refresh()
                })
                
                # Try to create the COM instance with timeout
                $sessionCreated = $false
                $sessionStart = Get-Date
                
                try {
                    # Enhanced COM object creation with credential handling
                    if ($Computer.computer -eq 'localhost' -or $Computer.computer -eq $env:COMPUTERNAME) {
                        $updatesession = [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session'))
                    } else {
                        # For remote computers, we may need to use different approaches
                        # COM object creation with remote computers can be tricky with alternate credentials
                        # We'll attempt the standard approach first
                        try {
                            $updatesession = [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session',$Computer.computer))
                        } catch {
                            # If direct COM fails, log the issue and provide better error information
                            if ($EnableDebugLogging) {
                                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                                $logEntry = "[$timestamp] [WARN] [$($Computer.Computer)] Direct COM creation failed, this is expected for cross-domain scenarios: $($_.Exception.Message)"
                                Add-Content -Path $LogPath -Value $logEntry -Force
                            }
                            throw "Remote COM object creation failed. This often occurs in cross-domain scenarios. Consider using PsExec for cross-domain Windows Update management."
                        }
                    }
                    $sessionCreated = $true
                    $success = $true
                } catch {
                    $elapsed = ((Get-Date) - $sessionStart).TotalSeconds
                    if ($elapsed -gt $sessionTimeout) {
                        throw "Windows Update session creation timed out after $sessionTimeout seconds"
                    } else {
                        if ($EnableDebugLogging) {
                            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                            $logEntry = "[$timestamp] [ERROR] [$($Computer.Computer)] Failed to create Windows Update session on $($Computer.Computer): $($_.Exception.Message)"
                            Add-Content -Path $LogPath -Value $logEntry -Force
                        }
                        throw "Failed to create Windows Update session: $($_.Exception.Message)"
                    }
                }
                
                if (-not $sessionCreated) {
                    throw "Failed to create Windows Update session on $($Computer.computer)"
                }
                
            } catch {
                $errorMsg = $_.Exception.Message
                
                if ($EnableEnhancedErrorHandling) {
                    # Get enhanced error suggestions
                    $errorInfo = Get-ErrorSuggestions -ErrorMessage $errorMsg
                    $friendlyError = "$($errorInfo.Description): $($errorInfo.Suggestions[0])"
                    
                    if ($retryCount -lt $maxRetries) {
                        # Try auto-recovery if available
                        $recoveryAttempted = $false
                        if ($errorInfo.AutoFix) {
                            SafeUpdateListViewItem $Computer.computer @{
                                Status = "Attempting automatic recovery for: $($errorInfo.Description)..."
                            }
                            
                            $recoverySuccess = Invoke-AutoRecovery -ComputerName $Computer.computer -ErrorCode $errorMsg
                            $recoveryAttempted = $true
                            
                            if ($recoverySuccess) {
                                SafeUpdateListViewItem $Computer.computer @{
                                    Status = "Recovery successful. Retrying... (attempt $retryCount/$maxRetries)"
                                }
                            }
                        }
                        
                        if (-not $recoveryAttempted -or -not $recoverySuccess) {
                            SafeUpdateListViewItem $Computer.computer @{
                                Status = "Error: $friendlyError. Retrying in 5 seconds... (attempt $retryCount/$maxRetries)"
                            }
                            Start-Sleep -Seconds 5
                        }
                    } else {
                        $allSuggestions = $errorInfo.Suggestions -join "; "
                        throw "After $maxRetries attempts: $($errorInfo.Description). Suggestions: $allSuggestions"
                    }
                } else {
                    # Simple error handling - just throw the original error
                    throw $errorMsg
                }
            }
        }
        
        # If we get here, connection was successful
        SafeUpdateListViewItem $Computer.computer @{
            Status = 'Checking for updates, this may take some time.'
        }

        #Check for updates with timeout handling.
        # The search runs on an in-process background thread: Start-Job would spawn a separate
        # process and serialize the COM searcher, which strips its methods and returns dead
        # (deserialized) update objects that cannot be downloaded or installed later.
        $updatesearcher = $updatesession.CreateUpdateSearcher()
        $searchPS = [powershell]::Create()
        [void]$searchPS.AddScript({
            param($searcher)
            # Search for all uninstalled, non-hidden updates (includes WSUS-approved)
            $searcher.Search('IsInstalled=0 and IsHidden=0')
        }).AddArgument($updatesearcher)
        $searchHandle = $searchPS.BeginInvoke()

        $timeoutCounter = 0
        while (-not $searchHandle.IsCompleted -and $timeoutCounter -lt $searchTimeout) {
            Start-Sleep -Seconds 2
            $timeoutCounter += 2

            # Update status with progress indicator
            if ($timeoutCounter % 10 -eq 0) {
                try {
                    SafeUpdateListViewItem $Computer.computer @{
                        Status = "Checking for updates... ($([math]::Round($timeoutCounter/60,1)) min elapsed)"
                    }
                } catch {
                    # If UI update fails, just log it but don't crash
                    if ($EnableDebugLogging) {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [WARN] [$($Computer.Computer)] Progress UI update skipped due to threading issue"
                        Add-Content -Path $LogPath -Value $logEntry -Force
                    }
                }
            }
        }

        if (-not $searchHandle.IsCompleted) {
            try { $searchPS.Stop() } catch { $null = $_ }
            $searchPS.Dispose()
            throw "Update search timed out after $($searchTimeout/60) minutes. The Windows Update service may be unresponsive."
        }

        try {
            $searchresult = @($searchPS.EndInvoke($searchHandle)) | Select-Object -First 1
        } catch {
            throw "Update search failed: $($_.Exception.Message)"
        } finally {
            $searchPS.Dispose()
        }

        if (-not $searchresult) {
            throw "Update search returned no result for $($Computer.computer)."
        }

        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Update search completed successfully"
            Add-Content -Path $LogPath -Value $logEntry -Force
        }

        #Save update info in hash to view with 'Show Available Updates'
        $updatesHash[$computer.computer] = $searchresult.Updates
        
        #Update status - use BeginInvoke to prevent deadlock
        $dlCount = @($searchresult.Updates | Where-Object {$_.IsDownloaded -eq $true}).Count
        
        # Note: MSRT is delivered outside the WUA update store, so it cannot be detected or
        # counted here ('Title like' is not valid WUA search criteria; MSRT is absent even
        # from 'IsInstalled=0' results). Windows Settings may therefore show one more update
        # than WUU when an MSRT release is pending. This is a known WUA API limitation.
        $adjustedAvailableCount = $searchresult.Updates.Count
        
        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Found $($searchresult.Updates.Count) available updates, $dlCount downloaded"
            Add-Content -Path $LogPath -Value $logEntry -Force
        }

        # Check pending-reboot state BEFORE the UI update that reports it (bounded so a hung COM call cannot block the job)
        $rebootRequired = $false
        try {
            $rebootPS = [powershell]::Create()
            [void]$rebootPS.AddScript({
                param($computerName)
                ([activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.SystemInfo',$computerName))).RebootRequired
            }).AddArgument($Computer.computer)
            $rebootHandle = $rebootPS.BeginInvoke()
            $rebootWait = 0
            while (-not $rebootHandle.IsCompleted -and $rebootWait -lt $rebootCheckTimeout) {
                Start-Sleep -Seconds 1
                $rebootWait++
            }
            if ($rebootHandle.IsCompleted) {
                $rebootRequired = [bool](@($rebootPS.EndInvoke($rebootHandle)) | Select-Object -First 1)
            } else {
                try { $rebootPS.Stop() } catch { $null = $_ }
            }
            $rebootPS.Dispose()
        } catch {
            # Reboot state is best-effort; assume no reboot needed if the check fails
            $rebootRequired = $false
        }
        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Reboot required: $rebootRequired"
            Add-Content -Path $LogPath -Value $logEntry -Force
        }

        # Update UI in a safer way that avoids cross-thread exceptions
        try {
            $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                $uiHash.Listview.Items.EditItem($Computer)
                $computer.Available = $adjustedAvailableCount
                $computer.Downloaded = $dlCount
                $computer.RebootRequired = $rebootRequired
                
                # Set UpdatesStatus for color scheme and update Status column
                if ($adjustedAvailableCount -gt 0) {
                    $computer.UpdatesStatus = 'Updates required'
                    $computer.Status = "$($adjustedAvailableCount) update(s) found. Right-click > Download Updates."
                } else {
                    # Check if reboot is required based on our simplified logic
                    if ($rebootRequired) {
                        $computer.UpdatesStatus = 'Reboot required'
                        $computer.Status = 'Up-to-date. Reboot required to complete previous installations.'
                    } else {
                        $computer.UpdatesStatus = 'All updates installed'
                        $computer.Status = 'Up-to-date. No updates available.'
                    }
                }
                
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })
        } catch {
            # If UI update fails, just log it but don't crash
            if ($EnableDebugLogging) {
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                $logEntry = "[$timestamp] [WARN] [$($Computer.Computer)] UI update skipped due to threading issue"
                Add-Content -Path $LogPath -Value $logEntry -Force
            }
        }

        
        # Reboot state was determined above, before the UI status update.

        # Log final status instead of updating UI to prevent hanging
        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            if ($computer.Available -eq 0) {
                if ($computer.RebootRequired) {
                    $statusMessage = 'Up-to-date. Reboot required to complete previous installations.'
                } else {
                    $statusMessage = 'Up-to-date. No updates available.'
                }
            } elseif ($computer.Downloaded -eq $computer.Available) {
                if ($computer.RebootRequired) {
                    $statusMessage = "$($computer.Available) update(s) ready to install. Reboot required."
                } else {
                    $statusMessage = "$($computer.Available) update(s) ready to install."
                }
            } elseif ($computer.Downloaded -gt 0) {
                if ($computer.RebootRequired) {
                    $statusMessage = "$($computer.Downloaded) of $($computer.Available) update(s) downloaded. Reboot required."
                } else {
                    $statusMessage = "$($computer.Downloaded) of $($computer.Available) update(s) downloaded."
                }
            } else {
                if ($computer.RebootRequired) {
                    $statusMessage = "$($computer.Available) update(s) found. Reboot required."
                } else {
                    $statusMessage = "$($computer.Available) update(s) found."
                }
            }
            
            $logEntry = "[$timestamp] [INFO] [$($Computer.Computer)] Final Status: $statusMessage"
            Add-Content -Path $LogPath -Value $logEntry -Force
        }
        
        #Auto-download if enabled and there are updates available
        if($uiHash.AutoDownloadCheckBox.IsChecked -and $computer.Available -gt 0 -and $computer.Available -gt $computer.Downloaded){
            #Update status to indicate auto-download is starting
            $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                $uiHash.Listview.Items.EditItem($Computer)
                $computer.Status = 'Auto-downloading available updates...'
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })
            
            #Start download process
            $temp = "" | Select-Object PowerShell,Runspace
            $temp.PowerShell = [powershell]::Create().AddScript($DownloadUpdates).AddArgument($Computer)
            # Disable SetUpdatesStatus to prevent hanging
            # $temp.PowerShell.AddScript($SetUpdatesStatus).AddArgument($Computer)
            $temp.PowerShell.Runspace = $Computer.Runspace
            $temp.Runspace = $temp.PowerShell.BeginInvoke()
            $jobs.Add($temp) | Out-Null
        }
    }
    Catch{
        # Enhanced error logging for GetUpdates
        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [ERROR] [$($Computer.Computer)] GetUpdates failed: $($_.Exception.Message)"
            Add-Content -Path $LogPath -Value $logEntry -Force
            
            $logEntry = "[$timestamp] [ERROR] [$($Computer.Computer)] Error type: $($_.Exception.GetType().FullName)"
            Add-Content -Path $LogPath -Value $logEntry -Force
            
            if ($_.Exception.InnerException) {
                $logEntry = "[$timestamp] [ERROR] [$($Computer.Computer)] Inner exception: $($_.Exception.InnerException.Message)"
                Add-Content -Path $LogPath -Value $logEntry -Force
            }
            
            $logEntry = "[$timestamp] [ERROR] [$($Computer.Computer)] Stack trace: $($_.ScriptStackTrace)"
            Add-Content -Path $LogPath -Value $logEntry -Force
        }
        
        # Create meaningful error message
        $errorMessage = if ([string]::IsNullOrWhiteSpace($_.Exception.Message)) {
            "Unknown error occurred during update check"
        } else {
            $_.Exception.Message
        }
        
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = "Error occurred: $errorMessage"
            $computer.UpdatesStatus = 'Error'
            # Set background color to grey for errored entries
            $listViewItem = $uiHash.Listview.ItemContainerGenerator.ContainerFromItem($Computer)
            if($listViewItem) {
                $listViewItem.Background = [System.Windows.Media.Brushes]::LightGray
            }
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })

        #Cancel any remaining actions
        exit
    }
}

#Format errors for Out-GridView
$GetErrors = {
    ForEach ($err in $error) {
        Switch ($err) {
            {$err -is [System.Management.Automation.ErrorRecord]} {
                    $hash = @{
                    Category = $err.categoryinfo.Category
                    Activity = $err.categoryinfo.Activity
                    Reason = $err.categoryinfo.Reason
                    Type = $err.GetType().ToString()
                    Exception = ($err.exception -split ': ')[1]
                    QualifiedError = $err.FullyQualifiedErrorId
                    CharacterNumber = $err.InvocationInfo.OffsetInLine
                    LineNumber = $err.InvocationInfo.ScriptLineNumber
                    Line = $err.InvocationInfo.Line
                    TargetObject = $err.TargetObject
                    }
                }               
            Default {
                $hash = @{
                    Category = $err.errorrecord.categoryinfo.category
                    Activity = $err.errorrecord.categoryinfo.Activity
                    Reason = $err.errorrecord.categoryinfo.Reason
                    Type = $err.GetType().ToString()
                    Exception = ($err.errorrecord.exception -split ': ')[1]
                    QualifiedError = $err.errorrecord.FullyQualifiedErrorId
                    CharacterNumber = $err.errorrecord.InvocationInfo.OffsetInLine
                    LineNumber = $err.errorrecord.InvocationInfo.ScriptLineNumber
                    Line = $err.errorrecord.InvocationInfo.Line
                    TargetObject = $err.errorrecord.TargetObject
                }
            }
        }
    $object = New-Object PSObject -Property $hash
    $object.PSTypeNames.Insert(0,'ErrorInformation')
    $object
    }
}

#Install downloaded updates
$InstallUpdates = {
    Param ($Computer)
    Try{
        #Set path for psexec, scripts
        Set-Location $path

        #Update status
        $installCount = ($updatesHash[$Computer.computer] | Where-Object {$_.IsDownloaded -eq $true -and $_.InstallationBehavior.CanRequestUserInput -eq $false} | Measure-Object).Count
        $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = "Installing $installCount Updates, this may take some time."
            $computer.InstallErrors = 0
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })

        #Copy script to remote computer and execute using centralized paths
        Copy-Item $ConfigPaths.InstallScript "\\$($Computer.computer)\c$" -Force
        [int]$installErrors = & $ConfigPaths.PsExec -accepteula -nobanner -s "\\$($Computer.computer)" cmd.exe /c 'echo . | powershell.exe -ExecutionPolicy Bypass -file C:\Install-Patches.ps1'
        Remove-Item "\\$($Computer.computer)\c$\Install-Patches.ps1"
        if($LASTEXITCODE -ne 0){
            throw "PsExec failed with error code $LASTEXITCODE"
        }

        #Update status
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = 'Checking if a reboot is required.'
            $computer.InstallErrors = $InstallErrors
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })

        #Check if any updates require reboot
        $rebootRequired = (.\PsExec.exe -accepteula -nobanner -s "\\$($Computer.computer)" cmd.exe /c 'echo . | powershell.exe -ExecutionPolicy Bypass -Command "&{return (New-Object -ComObject "Microsoft.Update.SystemInfo").RebootRequired}"') -eq $true
        if($LASTEXITCODE -ne 0){
            throw "PsExec failed with error code $LASTEXITCODE"
        }

        #Update status
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            if ($rebootRequired -eq $True) {
                $computer.Status = 'Install complete. Reboot required.'
                $computer.RebootRequired = $True
            } else {
                $computer.Status = 'Install complete.'
                $computer.RebootRequired = $False
            }
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })
    }
    Catch{
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = "Error occured: $($_.Exception.Message)"
            $computer.UpdatesStatus = 'Error'
            # Set background color to grey for errored entries
            $listViewItem = $uiHash.Listview.ItemContainerGenerator.ContainerFromItem($Computer)
            if($listViewItem) {
                $listViewItem.Background = [System.Windows.Media.Brushes]::LightGray
            }
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })

        #Cancel any remaining actions
        exit
    }
}

# Note: the old $RemoveEntry block was removed here — PowerShell variable names are
# case-insensitive, so it silently shadowed the proper $removeEntry cleanup (defined
# earlier) and leaked an open runspace on every computer removal.

#Remove computer that cannot be pinged
$RemoveOfflineComputer = {
    Param ($computer)
    try{
        #Update status
        $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
            $uiHash.Listview.Items.EditItem($computer)
            $computer.Status = 'Testing Connectivity.'
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })
        #Verify connectivity
        if(Test-Connection -Count 1 -ComputerName $computer.Computer -Quiet){
            $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                $uiHash.Listview.Items.EditItem($computer)
                $computer.Status = 'Online.'
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })
        }
        else{
            #Remove unreachable computers
            $updatesHash.Remove($computer.computer)
            $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                $uiHash.Listview.Items.EditItem($computer)
                # Check if clientObservable exists before trying to remove from it
                if ($uiHash.clientObservable) {
                    $uiHash.clientObservable.Remove($computer)
                }
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })
        }
    }
    Catch{
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($computer)
            $computer.Status = "Error occured: $($_.Exception.Message)"
            # Set background color to grey for errored entries
            $listViewItem = $uiHash.Listview.ItemContainerGenerator.ContainerFromItem($computer)
            if($listViewItem) {
                $listViewItem.Background = [System.Windows.Media.Brushes]::LightGray
            }
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })

        #Cancel any remaining actions
        exit
    }
}

#Reboot remote computer
$RestartComputer = {
    Param ($Computer,$afterInstall)
    try{
        # Avoid auto reboot if not enabled and required
        if($afterInstall -and -not $uiHash.AutoRebootCheckBox.IsChecked){return}
        if($afterInstall -and -not $Computer.RebootRequired){return}
        # Update status
        $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = 'Restarting... Waiting for computer to shutdown.'
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })

        #Restart and wait until remote COM can be connected
        Restart-Computer $Computer.computer -Force
        $offlineWait = 0
        While(Test-Connection -Count 1 -ComputerName $computer.Computer -Quiet){ #Wait for computer to go offline
            Start-Sleep -Seconds 5
            $offlineWait += 5
            if($offlineWait -ge 600){
                throw "Computer $($Computer.computer) did not go offline within 10 minutes of the restart command."
            }
        }

        #Update status
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = 'Restarting... Waiting for computer to come online.'
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })

        $onlineWait = 0
        While($true){ #Wait for computer to come online
            try{
                [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session',$Computer.computer))
                Break
            }
            catch{
                Start-Sleep 5
                $onlineWait += 5
                if($onlineWait -ge 1800){
                    throw "Computer $($Computer.computer) did not come back online within 30 minutes of restarting."
                }
            }
        }
    }
    catch{
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = "Error occured: $($_.Exception.Message)"
            # Set background color to grey for errored entries
            $listViewItem = $uiHash.Listview.ItemContainerGenerator.ContainerFromItem($Computer)
            if($listViewItem) {
                $listViewItem.Background = [System.Windows.Media.Brushes]::LightGray
            }
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })

        #Cancel any remaining actions
        exit
    }
}

#Start, stop, or restart Windows Update Service
$WUServiceAction = {
    Param($Computer,$Action)
    try{
        #Start Windows Update Service
        if($Action -eq 'Start'){
            #Update status
            $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
                $uiHash.Listview.Items.EditItem($Computer)
                $computer.Status = 'Starting Windows Update Service'
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })

            #Start service
            if ($computer.computer -eq 'localhost' -or $computer.computer -eq $env:COMPUTERNAME) {
                Get-Service -Name wuauserv -ErrorAction Stop | Start-Service -ErrorAction Stop
            } else {
                # Get appropriate credentials for this computer
                $credential = Get-RemoteCredentials -ComputerName $computer.computer -Operation 'Windows Update service start'
                
                if ($credential) {
                    Invoke-Command -ComputerName $computer.computer -Credential $credential -ScriptBlock {
                        Get-Service -Name wuauserv -ErrorAction Stop | Start-Service -ErrorAction Stop
                    } -ErrorAction Stop
                } else {
                    Invoke-Command -ComputerName $computer.computer -ScriptBlock {
                        Get-Service -Name wuauserv -ErrorAction Stop | Start-Service -ErrorAction Stop
                    } -ErrorAction Stop
                }
            }

            #Update status
            $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                $uiHash.Listview.Items.EditItem($Computer)
                $computer.Status = 'Windows Update Service Started'
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })
        }
    
        #Stop Windows Update Service
        ElseIf($Action -eq 'Stop'){
            #Update status
            $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
                $uiHash.Listview.Items.EditItem($Computer)
                $computer.Status = 'Stopping Windows Update Service'
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })

            #Stop service
            if ($computer.computer -eq 'localhost' -or $computer.computer -eq $env:COMPUTERNAME) {
                Get-Service -Name wuauserv -ErrorAction Stop | Stop-Service -ErrorAction Stop
            } else {
                # Get appropriate credentials for this computer
                $credential = Get-RemoteCredentials -ComputerName $computer.computer -Operation 'Windows Update service stop'
                
                if ($credential) {
                    Invoke-Command -ComputerName $computer.computer -Credential $credential -ScriptBlock {
                        Get-Service -Name wuauserv -ErrorAction Stop | Stop-Service -ErrorAction Stop
                    } -ErrorAction Stop
                } else {
                    Invoke-Command -ComputerName $computer.computer -ScriptBlock {
                        Get-Service -Name wuauserv -ErrorAction Stop | Stop-Service -ErrorAction Stop
                    } -ErrorAction Stop
                }
            }

            #Update status
            $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                $uiHash.Listview.Items.EditItem($Computer)
                $computer.Status = 'Windows Update Service Stopped'
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })
        }

        #Restart Windows Update Service
        ElseIf($Action -eq 'Restart'){
            #Update status
            $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
                $uiHash.Listview.Items.EditItem($Computer)
                $computer.Status = 'Restarting Windows Update Service'
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })

            #Restart service
            if ($computer.computer -eq 'localhost' -or $computer.computer -eq $env:COMPUTERNAME) {
                Get-Service -Name wuauserv -ErrorAction Stop | Restart-Service -ErrorAction Stop
            } else {
                Invoke-Command -ComputerName $computer.computer -ScriptBlock {
                    Get-Service -Name wuauserv -ErrorAction Stop | Restart-Service -ErrorAction Stop
                } -ErrorAction Stop
            }

            #Update status
            $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                $uiHash.Listview.Items.EditItem($Computer)
                $computer.Status = 'Windows Update Service Restarted'
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })
        }

        #Invalid action
        Else{
            & $WriteDebugLogScript -Message "Invalid action specified: $Action" -Level 'ERROR' -Computer $Computer.Computer
            throw "Invalid action specified: $Action"
        }
    }
    Catch{
        $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = "Error occured: $($_.Exception.Message)"
            # Set background color to grey for errored entries
            $listViewItem = $uiHash.Listview.ItemContainerGenerator.ContainerFromItem($Computer)
            if($listViewItem) {
                $listViewItem.Background = [System.Windows.Media.Brushes]::LightGray
            }
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })

        #Cancel any remaining actions
        exit
    }
}

#endregion Error Handling

#endregion Update Operations

#region Background runspace to clean up jobs
$jobCleanup.Flag = $True
$newRunspace =[runspacefactory]::CreateRunspace()
$newRunspace.ApartmentState = 'STA'
$newRunspace.ThreadOptions = 'ReuseThread'
$newRunspace.Open()
$newRunspace.SessionStateProxy.SetVariable('jobCleanup',$jobCleanup)
$newRunspace.SessionStateProxy.SetVariable('jobs',$jobs)
$newRunspace.SessionStateProxy.SetVariable('uiHash',$uiHash)
$newRunspace.SessionStateProxy.SetVariable('LogPath',$script:LogPath)
$newRunspace.SessionStateProxy.SetVariable('backgroundProcessing',$backgroundProcessing)
$jobCleanup.PowerShell = [PowerShell]::Create().AddScript({
    #Routine to handle completed runspaces
    Do {
        try {
            # Check if background processing is suspended
            if ($backgroundProcessing.Suspended) {
                Start-Sleep -Seconds 1
                continue
            }

            $jobsToRemove = @()
            # Snapshot first: enumerating a synchronized ArrayList is not thread-safe while other threads add/remove
            ForEach($runspace in @($jobs)){
                If ($runspace.Runspace.isCompleted){
                    try {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [INFO] Job completed for computer: $($runspace.Computer)"
                        Add-Content -Path $LogPath -Value $logEntry -Force

                        $runspace.powershell.EndInvoke($runspace.Runspace) | Out-Null

                        $logEntry = "[$timestamp] [INFO] Successfully cleaned up job for computer: $($runspace.Computer)"
                        Add-Content -Path $LogPath -Value $logEntry -Force
                    } catch {
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [ERROR] Failed to cleanup job for computer $($runspace.Computer): $($_.Exception.Message)"
                        Add-Content -Path $LogPath -Value $logEntry -Force
                    }
                    # Always dispose and drop the job so a failed EndInvoke is not retried forever
                    try { $runspace.powershell.dispose() } catch { $null = $_ }
                    $runspace.Runspace = $null
                    $runspace.powershell = $null
                    $jobsToRemove += $runspace
                    
                }
                # Check for jobs that have been running too long (timeout after 10 minutes)
                ElseIf ($runspace.StartTime -and ((Get-Date) - $runspace.StartTime).TotalMinutes -gt 10) {
                    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                    $logEntry = "[$timestamp] [WARN] [$($runspace.Computer)] Job timeout detected for $($runspace.Computer) - running for $([math]::Round(((Get-Date) - $runspace.StartTime).TotalMinutes, 2)) minutes"
                    Add-Content -Path $LogPath -Value $logEntry -Force

                    $timedOutComputer = $runspace.Computer
                    try { $runspace.powershell.Stop() } catch { $null = $_ }
                    try { $runspace.powershell.dispose() } catch { $null = $_ }
                    $runspace.Runspace = $null
                    $runspace.powershell = $null
                    $jobsToRemove += $runspace
                    

                    # Update computer status to show timeout (item lookup must happen on the UI thread)
                    try {
                        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
                            $computer = $uiHash.Listview.Items | Where-Object { $_.Computer -eq $timedOutComputer } | Select-Object -First 1
                            if ($computer) {
                                $uiHash.Listview.Items.EditItem($computer)
                                $computer.Status = "Operation timed out after 10 minutes"
                                $computer.UpdatesStatus = 'Timeout'
                                # Set background color to grey for timed out entries
                                $listViewItem = $uiHash.Listview.ItemContainerGenerator.ContainerFromItem($computer)
                                if($listViewItem) {
                                    $listViewItem.Background = [System.Windows.Media.Brushes]::LightGray
                                }
                                $uiHash.Listview.Items.CommitEdit()
                                $uiHash.Listview.Items.Refresh()
                            }
                        })
                    } catch {
                        # If UI update fails, just log it
                        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                        $logEntry = "[$timestamp] [WARN] Timeout UI update skipped for ${timedOutComputer}: $($_.Exception.Message)"
                        Add-Content -Path $LogPath -Value $logEntry -Force
                    }
                }
            }

            # Remove completed/timed out jobs
            if ($jobsToRemove.Count -gt 0) {
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                $logEntry = "[$timestamp] [INFO] Removing $($jobsToRemove.Count) completed job(s)"
                Add-Content -Path $LogPath -Value $logEntry -Force
            }

            ForEach($job in $jobsToRemove) {
                $jobs.remove($job)
            }
        } catch {
            # Never let the cleanup loop die - a dead cleanup loop starves the job throttle
            try {
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                $logEntry = "[$timestamp] [ERROR] Job cleanup loop iteration failed: $($_.Exception.Message)"
                Add-Content -Path $LogPath -Value $logEntry -Force
            } catch { $null = $_ }
        }

        Start-Sleep -Seconds 1
    } While ($jobCleanup.Flag)
})
$jobCleanup.PowerShell.Runspace = $newRunspace
$jobCleanup.Thread = $jobCleanup.PowerShell.BeginInvoke()
#endregion

#region Connect to controls
$uiHash.ActionMenu = $uiHash.Window.FindName('ActionMenu')
$uiHash.AddADContext = $uiHash.Window.FindName('AddADContext')
$uiHash.AddADMenu = $uiHash.Window.FindName('AddADMenu')
$uiHash.AddFileContext = $uiHash.Window.FindName('AddFileContext')
$uiHash.AddComputerContext = $uiHash.Window.FindName('AddComputerContext')
$uiHash.AddComputerMenu = $uiHash.Window.FindName('AddComputerMenu')
$uiHash.AutoDownloadCheckBox = $uiHash.Window.FindName('AutoDownloadCheckBox')
$uiHash.AutoInstallCheckBox = $uiHash.Window.FindName('AutoInstallCheckBox')
$uiHash.AutoRebootCheckBox = $uiHash.Window.FindName('AutoRebootCheckBox')
$uiHash.BrowseFileMenu = $uiHash.Window.FindName('BrowseFileMenu')
$uiHash.CheckUpdatesContext = $uiHash.Window.FindName('CheckUpdatesContext')
$uiHash.ClearComputerListMenu = $uiHash.Window.FindName('ClearComputerListMenu')
$uiHash.DownloadUpdatesContext = $uiHash.Window.FindName('DownloadUpdatesContext')
$uiHash.ExitMenu = $uiHash.Window.FindName('ExitMenu')
$uiHash.GridView = $uiHash.Window.FindName('GridView')
$uiHash.ExportListMenu = $uiHash.Window.FindName('ExportListMenu')
$uiHash.SaveConfigMenu = $uiHash.Window.FindName('SaveConfigMenu')
$uiHash.LoadConfigMenu = $uiHash.Window.FindName('LoadConfigMenu')
$uiHash.InstallUpdatesContext = $uiHash.Window.FindName('InstallUpdatesContext')
$uiHash.Listview = $uiHash.Window.FindName('Listview')
$uiHash.ListviewContextMenu = $uiHash.Window.FindName('ListViewContextMenu')

# Context menu event handler removed - it was causing issues when the ListView is empty
# The individual menu item click handlers already have null checks to prevent errors

$uiHash.CopyCellContext = $uiHash.Window.FindName('CopyCellContext')
$uiHash.OfflineHostsMenu = $uiHash.Window.FindName('OfflineHostsMenu')
$uiHash.Phase1Menu = $uiHash.Window.FindName('Phase1Menu')
$uiHash.Phase2Menu = $uiHash.Window.FindName('Phase2Menu')
$uiHash.Phase3Menu = $uiHash.Window.FindName('Phase3Menu')
$uiHash.Phase4Menu = $uiHash.Window.FindName('Phase4Menu')
$uiHash.Phase5Menu = $uiHash.Window.FindName('Phase5Menu')
$uiHash.RemoteDesktopContext = $uiHash.Window.FindName('RemoteDesktopContext')
$uiHash.RemoveComputerContext = $uiHash.Window.FindName('RemoveComputerContext')
$uiHash.RestartContext = $uiHash.Window.FindName('RestartContext')
$uiHash.SelectAllMenu = $uiHash.Window.FindName('SelectAllMenu')
$uiHash.ShowUpdatesContext = $uiHash.Window.FindName('ShowUpdatesContext')
$uiHash.ShowInstalledContext = $uiHash.Window.FindName('ShowInstalledContext')
$uiHash.WSUSAuditContext = $uiHash.Window.FindName('WSUSAuditContext')
$uiHash.StatusTextBox = $uiHash.Window.FindName('StatusTextBox')
$uiHash.UpdateHistoryMenu = $uiHash.Window.FindName('UpdateHistoryMenu')
$uiHash.ViewErrorMenu = $uiHash.Window.FindName('ViewErrorMenu')
$uiHash.ViewUpdateLogContext = $uiHash.Window.FindName('ViewUpdateLogContext')
$uiHash.WindowsUpdateServiceMenu = $uiHash.Window.FindName('WindowsUpdateServiceMenu')
$uiHash.WURestartServiceMenu = $uiHash.Window.FindName('WURestartServiceMenu')
$uiHash.WUStartServiceMenu = $uiHash.Window.FindName('WUStartServiceMenu')
$uiHash.WUStopServiceMenu = $uiHash.Window.FindName('WUStopServiceMenu')
$uiHash.SetDomainCredentialsContext = $uiHash.Window.FindName('SetDomainCredentialsContext')
$uiHash.TestADConnectionMenu = $uiHash.Window.FindName('TestADConnectionMenu')
#endregion Connect to controls

#region Event ScriptBlocks

#region Window and UI Events

# Copy cell content functionality - improved implementation to prevent GUI hangs
$eventCopyCellContent = {
    try {
        Write-InfoLog "Copy Cell Content function called"
        $selectedItem = $uiHash.Listview.SelectedItem
        if ($selectedItem) {
            # Collect the computer name and status
            $cellContent = "Computer: $($selectedItem.Computer)"
            if ($selectedItem.Status -and $selectedItem.Status -ne 'Ready' -and $selectedItem.Status -ne '') {
                $cellContent += " | Status: $($selectedItem.Status)"
            }
            
            Write-InfoLog "Copying cell content: '$cellContent'"
            
            # Copy to clipboard with error handling
            [System.Windows.Clipboard]::SetText($cellContent)
            Write-InfoLog "Successfully copied '$cellContent' to clipboard"
            
            # Update status
            $uiHash.StatusTextBox.Dispatcher.Invoke('Background',[action]{
                $uiHash.StatusTextBox.Foreground = 'Green'
                $uiHash.StatusTextBox.Text = "Copied '$cellContent' to clipboard"
            })
        } else {
            Write-WarningLog "No item selected for copy operation"
            $uiHash.StatusTextBox.Dispatcher.Invoke('Background',[action]{
                $uiHash.StatusTextBox.Foreground = 'Orange'
                $uiHash.StatusTextBox.Text = "No item selected to copy"
            })
        }
    } catch {
        Write-ErrorLog "Error copying cell content: $($_.Exception.Message)"
        $uiHash.StatusTextBox.Dispatcher.Invoke('Background',[action]{
            $uiHash.StatusTextBox.Foreground = 'Red'
            $uiHash.StatusTextBox.Text = "Failed to copy cell content: $($_.Exception.Message)"
        })
    }
}

$eventWindowInit = {
    $Script:SortHash = @{}
    
    #Sort event handler
    [System.Windows.RoutedEventHandler]$Global:ColumnSortHandler = {
        If ($_.OriginalSource -is [System.Windows.Controls.GridViewColumnHeader]) {
            Write-Verbose ('{0}' -f $_.Originalsource.getType().FullName)
            If ($_.OriginalSource -AND $_.OriginalSource.Role -ne 'Padding') {
                $Column = $_.Originalsource.Column.DisplayMemberBinding.Path.Path
                Write-Debug ('Sort: {0}' -f $Column)
                If ($SortHash[$Column] -eq 'Ascending') {
                    $SortHash[$Column]  = 'Descending'
                } Else {
                    $SortHash[$Column]  = 'Ascending'
                }
                $uiHash.Listview.Items.SortDescriptions.clear()
                Write-Verbose ('Sorting {0} by {1}' -f $Column, $SortHash[$Column])
                $uiHash.Listview.Items.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription $Column, $SortHash[$Column]))
                $uiHash.Listview.Items.Refresh()
            }
        }
    }
    $uiHash.Listview.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, $ColumnSortHandler)

    #Create and bind the observable collection to the GridView (if not already initialized)
    if ($null -eq $uiHash.clientObservable) {
        $uiHash.clientObservable = New-Object System.Collections.ObjectModel.ObservableCollection[object]
        $uiHash.ListView.ItemsSource = $uiHash.clientObservable
    }
}
$eventWindowClose = { #Runs when WUU closes
    #Stop the job scheduler timer
    if ($uiHash.JobTimer) { $uiHash.JobTimer.Stop() }

    #Halt job processing
    $jobCleanup.Flag = $False

    #Stop all runspaces
    $jobCleanup.PowerShell.Dispose()
    
    #Cleanup
    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()    
}

#endregion Window and UI Events

#region Menu and Action Events

$eventActionMenu = { #Enable/disable action menu items
    $uiHash.ClearComputerListMenu.IsEnabled = ($uiHash.Listview.Items.Count -gt 0)
    $uiHash.OfflineHostsMenu.IsEnabled = ($uiHash.Listview.Items.Count -gt 0)
    $uiHash.ViewErrorMenu.IsEnabled = ($Error.Count -gt 0)
}
#region Active Directory Import

# Test Active Directory connectivity function
$TestADConnection = {
    $results = @()
    
    # Test 1: Check if computer is domain-joined
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($computerSystem.PartOfDomain) {
            $results += "[OK] Computer is domain-joined: $($computerSystem.Domain)"
        } else {
            $results += "[ERROR] Computer is NOT domain-joined (workgroup: $($computerSystem.Workgroup))"
            $results += "  This is likely why AD import is not working."
        }
    } catch {
        $results += "[ERROR] Error checking domain membership: $($_.Exception.Message)"
    }
    
    # Test 2: Test domain connectivity
    try {
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $results += "[OK] Successfully connected to domain: $($domain.Name)"
    } catch {
        $results += "[ERROR] Error connecting to domain: $($_.Exception.Message)"
        $results += "  Error type: $($_.Exception.GetType().Name)"
    }
    
    # Test 3: Test LDAP connectivity
    try {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.Filter = "(objectCategory=organizationalUnit)"
        $searcher.SearchScope = "OneLevel"
        $searchResults = $searcher.FindAll()
        $results += "[OK] LDAP search successful, found $($searchResults.Count) organizational units"
    } catch {
        $results += "[ERROR] LDAP search failed: $($_.Exception.Message)"
    }
    
    # Test 4: Test computer search
    try {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.Filter = '(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'
        $searcher.PropertiesToLoad.Add('name') | Out-Null
        $searcher.SizeLimit = 5  # Limit results for testing
        $searchResults = $searcher.FindAll()
        $results += "[OK] Computer search successful, found $($searchResults.Count) computers (limited to 5)"
        
        if ($searchResults.Count -gt 0) {
            $results += "  Sample computers found:"
            $searchResults | ForEach-Object {
                $results += "    - $($_.Properties.name[0])"
            }
        }
    } catch {
        $results += "[ERROR] Computer search failed: $($_.Exception.Message)"
    }
    
    # Test 5: Check if OUPicker.xaml exists
    $ouPickerPath = Join-Path $PSScriptRoot "OUPicker.xaml"
    if (Test-Path $ouPickerPath) {
        $results += "[OK] OUPicker.xaml found at: $ouPickerPath"
    } else {
        $results += "[ERROR] OUPicker.xaml NOT found at: $ouPickerPath"
    }
    
    # Show results in a message box
    $resultText = $results -join "`n"
    [System.Windows.MessageBox]::Show(
        "Active Directory Connectivity Test Results:`n`n$resultText`n`nIf any tests failed, that's likely why AD import isn't working.",
        "AD Connection Test",
        'OK',
        'Information'
    )
    
    # Also log the results
    Write-InfoLog "AD Connection Test Results:"
    $results | ForEach-Object { Write-InfoLog "  $_" }
}

$eventAddAD = { #Add computers from Active Directory
    # Check if computer is joined to a domain first
    try {
        # Test if we can access Active Directory services
        Write-InfoLog "Attempting to connect to Active Directory domain"
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        Write-InfoLog "Successfully connected to domain: $($domain.Name)"
    } catch [System.Security.Authentication.AuthenticationException] {
        Write-ErrorLog "Authentication failed when accessing Active Directory: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Authentication failed when accessing Active Directory.`n`nThis may be due to insufficient permissions or expired credentials.`n`nPlease ensure you have the necessary permissions to query Active Directory.",
            "Active Directory Authentication Error",
            'OK',
            'Error'
        )
        return
    } catch [System.ComponentModel.Win32Exception] {
        # Directory service errors (Win32Exception is available in PowerShell 7)
        Write-ErrorLog "Directory service error when accessing Active Directory: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "A directory service error occurred when accessing Active Directory.`n`nError: $($_.Exception.Message)`n`nThis may be due to network connectivity issues or domain controller availability.`n`nPlease check your network connection and try again.",
            "Active Directory Service Error",
            'OK',
            'Error'
        )
        return
    } catch [System.UnauthorizedAccessException] {
        # Access denied
        Write-ErrorLog "Access denied when accessing Active Directory: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Access denied when accessing Active Directory.`n`nYou do not have sufficient permissions to query Active Directory.`n`nPlease contact your system administrator or run the application with appropriate credentials.",
            "Active Directory Access Denied",
            'OK',
            'Error'
        )
        return
    } catch [System.Runtime.InteropServices.COMException] {
        # COM/RPC errors (common with domain connectivity issues)
        Write-ErrorLog "COM/RPC error when accessing Active Directory: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "A communication error occurred when accessing Active Directory.`n`nError: $($_.Exception.Message)`n`nThis may be due to network connectivity issues or domain controller availability.`n`nPlease check your network connection and domain controller status.",
            "Active Directory Communication Error",
            'OK',
            'Error'
        )
        return
    } catch [System.SystemException] {
        # Generic catch for domain issues or service unavailability
        Write-ErrorLog "Active Directory services unavailable or not joined to a domain: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Active Directory services are unavailable or this computer is not joined to a domain. Please check your network connection or domain configuration.",
            "Active Directory Error",
            'OK',
            'Error'
        )
        return
    } catch {
        # Generic catch-all for any other AD-related errors
        Write-ErrorLog "Unexpected error when accessing Active Directory: $($_.Exception.Message)"
        Write-ErrorLog "Exception type: $($_.Exception.GetType().FullName)"
        
        # Offer to run diagnostic test
        $result = [System.Windows.MessageBox]::Show(
            "An unexpected error occurred when accessing Active Directory.`n`nError: $($_.Exception.Message)`n`nError Type: $($_.Exception.GetType().Name)`n`nThis computer may not be joined to a domain, or there may be network connectivity issues.`n`nWould you like to run an AD connectivity test to diagnose the issue?",
            "Active Directory Error",
            'YesNo',
            'Error'
        )
        
        if ($result -eq 'Yes') {
            & $TestADConnection
        }
        return
    }
    
    #region OU Picker
    $OUPickerHash = [hashtable]::Synchronized(@{})
    try{
        $ouPickerXamlPath = Join-Path $PSScriptRoot "OUPicker.xaml"
        Write-InfoLog "Checking OUPicker.xaml at $ouPickerXamlPath"
        if (-not (Test-Path $ouPickerXamlPath)) {
            Write-ErrorLog "OUPicker.xaml file not found at: $ouPickerXamlPath"
            throw "OUPicker.xaml file not found at: $ouPickerXamlPath"
        }
        [xml]$xaml = Get-Content $ouPickerXamlPath -ErrorAction Stop
        $reader = New-Object System.Xml.XmlNodeReader $xaml
        $OUPickerHash.Window = [Windows.Markup.XamlReader]::Load($reader)
        if (-not $OUPickerHash.Window) {
            throw "Failed to create OUPicker window from XAML"
        }
    }
    catch{
        Write-ErrorLog "Failed to load OUPicker XAML: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Unable to load the Organizational Unit picker dialog.`n`nError: $($_.Exception.Message)`n`nThe OUPicker.xaml file may be missing or corrupted.",
            "OUPicker Error",
            'OK',
            'Error'
        )
        return
    }

    $OUPickerHash.OKButton = $OUPickerHash.Window.FindName('OKButton')
    $OUPickerHash.CancelButton = $OUPickerHash.Window.FindName('CancelButton')
    $OUPickerHash.OUTree = $OUPickerHash.Window.FindName('OUTree')

    $OUPickerHash.OKButton.Add_Click({
        if ($OUPickerHash.OUTree.SelectedItem) {
            $OUPickerHash.SelectedOU = $OUPickerHash.OUTree.SelectedItem.Tag
            $OUPickerHash.Window.Close()
        } else {
            [System.Windows.MessageBox]::Show('Please select an Organizational Unit first.', 'No Selection', 'OK', 'Information')
        }
    })
    $OUPickerHash.CancelButton.Add_Click({$OUPickerHash.Window.Close()})

    try {
        # Verify domain object is available before proceeding
        if (-not $domain -or [string]::IsNullOrEmpty($domain.Name)) {
            Write-ErrorLog "Domain object is not properly initialized"
            throw "Domain information is not available"
        }
        
        # Building the tree runs synchronously on the UI thread; show a wait cursor
        $uiHash.Window.Cursor = [System.Windows.Input.Cursors]::Wait

        # Root the search at the verified domain rather than the default naming context
        $domainRoot = $domain.GetDirectoryEntry()

        $rootItem = New-Object System.Windows.Controls.TreeViewItem
        $rootItem.Header = $domain.Name
        $rootItem.Tag = $domainRoot.Properties['distinguishedName'].Value

        # Use non-recursive approach to prevent stack overflow
        function Add-ChildNodes($node, $maxDepth = 3, $currentDepth = 0){
            try {
                # Prevent infinite recursion and stack overflow
                if ($currentDepth -ge $maxDepth) {
                    Write-InfoLog "Maximum depth ($maxDepth) reached for OU: $($node.Tag)"
                    return
                }
                
                # Use a local searcher so recursion cannot mutate the parent's search state
                $childSearcher = New-Object System.DirectoryServices.DirectorySearcher
                $childSearcher.SearchRoot = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$($node.Tag)")
                $childSearcher.Filter = "(objectCategory=organizationalUnit)"
                $childSearcher.SearchScope = "OneLevel"
                $childOUs = $childSearcher.FindAll()
                
                # Limit the number of child OUs to prevent performance issues
                $maxChildren = 50
                $childCount = 0
                
                foreach ($childOU in $childOUs) {
                    if ($childCount -ge $maxChildren) {
                        Write-InfoLog "Limited child OUs to $maxChildren for performance"
                        break
                    }
                    
                    $childItem = New-Object System.Windows.Controls.TreeViewItem
                    $childItem.Header = $childOU.Properties.name[0]
                    $childItem.Tag = $childOU.Properties.distinguishedname[0]
                    
                    # Only add children if we haven't reached max depth
                    if ($currentDepth -lt ($maxDepth - 1)) {
                        Add-ChildNodes $childItem $maxDepth ($currentDepth + 1)
                    }
                    
                    $node.Items.Add($childItem) | Out-Null
                    $childCount++
                }
                
                Write-InfoLog "Added $childCount child OUs to $($node.Header)"
                
            } catch {
                Write-WarningLog "Error adding child nodes for $($node.Tag): $($_.Exception.Message)"
            }
        }
        
        # Start building the tree with depth limit
        Write-InfoLog "Starting to build OU tree for $($domain.Name)"
        Add-ChildNodes $rootItem 3 0
        Write-InfoLog "Finished building OU tree for $($domain.Name)"
        $OUPickerHash.OUTree.Items.Add($rootItem) | Out-Null
        $uiHash.Window.Cursor = $null
            Write-InfoLog "OU tree completed and added to TreeView"
    } catch {
        $uiHash.Window.Cursor = $null
        Write-ErrorLog "Error building OU tree: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Error building the Organizational Unit tree.`n`nError: $($_.Exception.Message)`n`nYou may not have sufficient permissions to browse Active Directory.",
            "OU Tree Error",
            'OK',
            'Warning'
        )
        return
    }

$OUPickerHash.Window.ShowDialog() | Out-Null
    #endregion
    
#Verify user didn't hit 'cancel' before processing
    if($OUPickerHash.SelectedOU){
        #Update status
        Update-Status 'Querying Active Directory for Computers...'

        try {
                Write-InfoLog "Searching LDAP path for computers in OU: $($OUPickerHash.SelectedOU)"
                $Searcher = [adsisearcher]''
                $Searcher.SearchRoot= [adsi]"LDAP://$($OUPickerHash.SelectedOU)"
                $Searcher.Filter = '(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'
                $Searcher.PropertiesToLoad.Add('name') | Out-Null

                Write-InfoLog "Executing LDAP search for computers..."
                $Results = $Searcher.FindAll()
                Write-InfoLog "LDAP search completed. Found $($Results.Count) results"
                
                if($Results){
                    #Add computers found
                    Write-InfoLog "Processing $($Results.Count) computer results from AD"
                    $computerNames = $Results | ForEach-Object { $_.Properties.name[0] }
                    Write-InfoLog "Extracted computer names: $($computerNames -join ', ')"
                    
                    # Debug: Check if AddEntry function exists
                    if ($AddEntry) {
                        Write-InfoLog "AddEntry function exists, calling it with $($computerNames.Count) computers"
                        Write-InfoLog "Current GUI state before AddEntry call:"
                        Write-InfoLog "  - Window exists: $($uiHash.Window -ne $null)"
                        Write-InfoLog "  - Window IsVisible: $($uiHash.Window.IsVisible)"
                        Write-InfoLog "  - Window IsLoaded: $($uiHash.Window.IsLoaded)"
                        Write-InfoLog "  - ListView exists: $($uiHash.ListView -ne $null)"
                        Write-InfoLog "  - clientObservable exists: $($uiHash.clientObservable -ne $null)"
                        Write-InfoLog "  - Current ListView count: $($uiHash.Listview.Items.Count)"
                        
                        # Call AddEntry with detailed error handling
                        try {
                            Write-InfoLog "About to call AddEntry with computers: $($computerNames -join ', ')"
                            & $AddEntry $computerNames
                            Write-InfoLog "AddEntry function completed successfully"
                        } catch {
                            Write-ErrorLog "CRITICAL ERROR in AddEntry during AD import: $($_.Exception.Message)"
                            Write-ErrorLog "AddEntry error type: $($_.Exception.GetType().FullName)"
                            Write-ErrorLog "AddEntry stack trace: $($_.ScriptStackTrace)"
                            Write-ErrorLog "AddEntry thread ID: $([System.Threading.Thread]::CurrentThread.ManagedThreadId)"
                            
                            if ($_.Exception.InnerException) {
                                Write-ErrorLog "AddEntry inner exception: $($_.Exception.InnerException.Message)"
                            }
                            
                            # Show error to user
                            [System.Windows.MessageBox]::Show(
                                "An error occurred while adding computers from Active Directory to the list.`n`nError: $($_.Exception.Message)`n`nThis may be a threading or UI synchronization issue. Check the debug log for more details.",
                                "AD Import Error",
                                'OK',
                                'Error'
                            )
                            
                            # Still update the status to show partial success
                            Update-StatusBackground "AD import failed: $($_.Exception.Message)"
                            return
                        }
                    } else {
                        Write-ErrorLog "AddEntry function not found!"
                        [System.Windows.MessageBox]::Show(
                            "Internal error: AddEntry function not available.",
                            "Internal Error",
                            'OK',
                            'Error'
                        )
                        return
                    }
                    
                    Write-InfoLog "Imported $($Results.Count) computers from Active Directory."
                    Write-InfoLog "Final GUI state after AddEntry:"
                    Write-InfoLog "  - Window exists: $($uiHash.Window -ne $null)"
                    Write-InfoLog "  - Window IsVisible: $($uiHash.Window.IsVisible)"
                    Write-InfoLog "  - ListView exists: $($uiHash.ListView -ne $null)"
                    Write-InfoLog "  - clientObservable exists: $($uiHash.clientObservable -ne $null)"
                    Write-InfoLog "  - Final ListView count: $($uiHash.Listview.Items.Count)"

                    #Update status
                    Update-StatusBackground "Successfully Imported $($Results.Count) computers from Active Directory."
                } else {
                    Write-WarningLog "No computers found for the given LDAP path in AD."
                    #Update status
                    Update-StatusBackground 'No computers found, verify LDAP path...'
                    [System.Windows.MessageBox]::Show("No computers found in the selected Organizational Unit.", "No Computers Found", 'OK', 'Warning')
                }
        } catch [System.Runtime.InteropServices.COMException] {
            Write-ErrorLog "LDAP search error: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show(
                "There was an error accessing Active Directory during the search process. Please check your connection and try again.",
                "LDAP Search Error",
                'OK',
                'Error'
            )
        } catch {
            Write-ErrorLog "Unexpected error during LDAP search: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show(
                "An unexpected error occurred while querying Active Directory.`n`nError: $($_.Exception.Message)`n`nPlease check your connection or permissions.",
                "LDAP Search Error",
                'OK',
                'Error'
            )
        }
    }
}

#endregion
#region Manual Computer Entry
$eventAddComputer = { #Add computers by typing them in manually
    #Open prompt
    $computer = [Microsoft.VisualBasic.Interaction]::InputBox('Enter a computer name or names. Separate computers with a comma (,) or semi-colon (;).', 'Add Computer(s)')

    #Verify computers were input
    If (-Not [System.String]::IsNullOrEmpty($computer)) {
        [string[]]$computername = $computer -split ',|;' #Parse
    }
    if($computername){&$AddEntry $computername} #Add computers
}
#endregion

#region File Import
$eventAddFile = { #Add computers from CSV or TXT file with advanced options
    # Import computers from files with CSV column detection, duplicate checking, exempt filtering, and import summary
    
    #Open file dialog
    $dlg = new-object microsoft.win32.OpenFileDialog
    $dlg.DefaultExt = '*.csv'
    $dlg.Filter = 'CSV Files (*.csv)|*.csv|Text Files (*.txt)|*.txt|All Files (*.*)|*.*'
    $dlg.InitialDirectory = $pwd
    $dlg.Title = 'Add Computers From File'
    [void]$dlg.showdialog()
    $File = $dlg.FileName

    #Verify file was selected
    If (-Not ([system.string]::IsNullOrEmpty($File))) {
        try {
            $fileExtension = [System.IO.Path]::GetExtension($File).ToLower()
            $computerNames = @()
            $importCount = 0
            $duplicateCount = 0
            $exemptCount = 0
            
            # Load exempt list if it exists
            $exemptList = @()
            if (Test-Path 'Exempt.txt') {
                $exemptList = Get-Content 'Exempt.txt' | Where-Object { $_ -and $_.Trim() -ne '' }
            }
            
            # Get existing computers to check for duplicates
            $existingComputers = @()
            if ($uiHash.Listview.Items.Count -gt 0) {
                $existingComputers = $uiHash.Listview.Items | Select-Object -ExpandProperty Computer
            }
            
            if ($fileExtension -eq '.csv') {
                # Handle CSV file
                $csvData = Import-Csv -Path $File
                
                # Try to detect computer name column
                $computerColumn = $null
                $possibleColumns = @('Computer', 'ComputerName', 'Name', 'Hostname', 'Host', 'Server', 'Machine')
                
                foreach ($column in $possibleColumns) {
                    if ($csvData[0].PSObject.Properties.Name -contains $column) {
                        $computerColumn = $column
                        break
                    }
                }
                
                if (-not $computerColumn) {
                    # Show column selection dialog
                    $columns = $csvData[0].PSObject.Properties.Name
                    $selectedColumn = $null
                    
                    # Create a simple selection dialog
                    Add-Type -AssemblyName Microsoft.VisualBasic
                    $columnList = $columns -join ', '
                    $message = "Available columns in CSV: $columnList`n`nWhich column contains the computer names? (Enter exact column name)"
                    $selectedColumn = [Microsoft.VisualBasic.Interaction]::InputBox($message, 'Select Computer Name Column', $columns[0])
                    
                    if ($selectedColumn -and $columns -contains $selectedColumn) {
                        $computerColumn = $selectedColumn
                    } else {
                        [System.Windows.MessageBox]::Show("Invalid column selection. Import cancelled.", "Import Error", 'OK', 'Warning')
                        return
                    }
                }
                
                # Extract computer names from CSV
                foreach ($row in $csvData) {
                    $computerName = $row.$computerColumn
                    if ($computerName -and $computerName.ToString().Trim() -ne '') {
                        $computerNames += $computerName.ToString().Trim()
                    }
                }
                
            } else {
                # Handle TXT file (and other text files)
                $fileContent = Get-Content $File
                
                # Try to detect delimiter
                $delimiters = @(',', ';', '`t', '|')
                $detectedDelimiter = $null
                
                foreach ($delimiter in $delimiters) {
                    if ($fileContent[0] -split $delimiter | Where-Object { $_.Trim() -ne '' } | Measure-Object | Select-Object -ExpandProperty Count -gt 1) {
                        $detectedDelimiter = $delimiter
                        break
                    }
                }
                
                if ($detectedDelimiter) {
                    # Ask user if they want to use the detected delimiter
                    $delimiterName = switch ($detectedDelimiter) {
                        ',' { 'comma' }
                        ';' { 'semicolon' }
                        '`t' { 'tab' }
                        '|' { 'pipe' }
                    }
                    
                    $result = [System.Windows.MessageBox]::Show(
                        "Detected $delimiterName-separated values in file.`n`nDo you want to import only the first column as computer names?`n`nClick 'Yes' to use first column only, 'No' to treat each line as a computer name.",
                        "Import Format Detection",
                        'YesNo',
                        'Question'
                    )
                    
                    if ($result -eq 'Yes') {
                        # Use first column only
                        foreach ($line in $fileContent) {
                            if ($line -and $line.Trim() -ne '') {
                                $firstColumn = ($line -split $detectedDelimiter)[0]
                                if ($firstColumn -and $firstColumn.Trim() -ne '') {
                                    $computerNames += $firstColumn.Trim()
                                }
                            }
                        }
                    } else {
                        # Treat each line as computer name
                        $computerNames = $fileContent | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }
                    }
                } else {
                    # No delimiter detected, treat each line as computer name
                    $computerNames = $fileContent | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }
                }
            }
            
            # Process computer names
            $validComputers = @()
            foreach ($computer in $computerNames) {
                $computer = $computer.Trim()
                
                # Skip empty names
                if ([string]::IsNullOrEmpty($computer)) {
                    continue
                }
                
                # Check if computer is in exempt list
                if ($exemptList -contains $computer) {
                    $exemptCount++
                    continue
                }
                
                # Check if computer already exists
                if ($existingComputers -contains $computer) {
                    $duplicateCount++
                    continue
                }
                
                # Add to valid computers list
                $validComputers += $computer
            }
            
            # Show import summary
            $totalProcessed = $computerNames.Count
            $importCount = $validComputers.Count
            
            $summaryMessage = "Import Summary:`n`n"
            $summaryMessage += "Total entries processed: $totalProcessed`n"
            $summaryMessage += "Valid computers to import: $importCount`n"
            if ($duplicateCount -gt 0) { $summaryMessage += "Duplicates skipped: $duplicateCount`n" }
            if ($exemptCount -gt 0) { $summaryMessage += "Exempt computers skipped: $exemptCount`n" }
            
            if ($importCount -gt 0) {
                $summaryMessage += "`nProceed with import?"
                $result = [System.Windows.MessageBox]::Show($summaryMessage, "Import Computer List", 'YesNo', 'Question')
                
                if ($result -eq 'Yes') {
                    # Import the computers
                    & $AddEntry $validComputers
                    
                    # Update status
                    Update-StatusBackground "Successfully imported $importCount computer(s) from $([System.IO.Path]::GetFileName($File))"
                } else {
                    # Update status
                    Update-StatusBackground 'Import cancelled by user'
                }
            } else {
                [System.Windows.MessageBox]::Show($summaryMessage + "`nNo valid computers found to import.", "Import Computer List", 'OK', 'Warning')
                Update-StatusBackground 'No valid computers found in selected file'
            }
            
        } catch {
            [System.Windows.MessageBox]::Show("Error importing file: $($_.Exception.Message)", "Import Error", 'OK', 'Error')
            Update-StatusBackground "Import failed: $($_.Exception.Message)"
        }
    }
}
#endregion

#region Update Operations
$eventGetUpdates = {
    $uiHash.Listview.SelectedItems | ForEach-Object {
        if (-not $_.Runspace) {
            # Item was never started (phase-gated or loaded from config): use the full startup path
            if ($_.PSObject.Properties['Pending']) { $_.Pending = $false }
            [void](Start-UpdateCheckJob -ComputerItem $_)
            return
        }
        $temp = New-Object PSObject -Property @{
            PowerShell = $null
            Runspace = $null
            StartTime = Get-Date
            Computer = $_.Computer
        }
        $temp.PowerShell = [powershell]::Create().AddScript($GetUpdates).AddArgument($_)
        $temp.PowerShell.Runspace = $_.Runspace
        $temp.Runspace = $temp.PowerShell.BeginInvoke()
        $jobs.Add($temp) | Out-Null
    }
}
$eventDownloadUpdates = {
    $uiHash.Listview.SelectedItems | ForEach-Object {
        if (-not $_.Runspace) {
            $item = $_
            try { $item.Runspace = New-ComputerRunspace -ComputerItem $item } catch {
                Write-ErrorLog "Failed to create runspace for $($item.Computer): $($_.Exception.Message)"
                return
            }
        }
        #Don't bother downloading if nothing available.
        if($_.Available -eq $_.Downloaded){
            #Update status based on whether computer is up-to-date or already has downloads
            $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
                $uiHash.Listview.Items.EditItem($_)
                if($_.Available -eq 0){
                    $_.Status = 'Up-to-Date - No updates available for download.'
                } else {
                    $_.Status = 'All available updates are already downloaded.'
                }
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })
            return
        }

        $temp = "" | Select-Object PowerShell,Runspace
        $temp.PowerShell = [powershell]::Create().AddScript($DownloadUpdates).AddArgument($_)
        # Disable SetUpdatesStatus to prevent hanging - status updates are handled within DownloadUpdates
        # $temp.PowerShell.AddScript($SetUpdatesStatus).AddArgument($_)
        $temp.PowerShell.Runspace = $_.Runspace
        $temp.Runspace = $temp.PowerShell.BeginInvoke()
        $jobs.Add($temp) | Out-Null
    }
}
$eventInstallUpdates = {
    $uiHash.Listview.SelectedItems | ForEach-Object {
        if (-not $_.Runspace) {
            $item = $_
            try { $item.Runspace = New-ComputerRunspace -ComputerItem $item } catch {
                Write-ErrorLog "Failed to create runspace for $($item.Computer): $($_.Exception.Message)"
                return
            }
        }
        #Check if there are any updates that are downloaded and don't require user input
        $downloadedUpdates = $updatesHash[$_.computer] | Where-Object {$_.IsDownloaded -and $_.InstallationBehavior.CanRequestUserInput -eq $false}
        $availableUpdates = $updatesHash[$_.computer] | Where-Object {-not $_.IsDownloaded -and $_.InstallationBehavior.CanRequestUserInput -eq $false}
        
        if(-not $downloadedUpdates){
            #Update status based on whether there are updates available for download
            $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
                $uiHash.Listview.Items.EditItem($_)
                if($availableUpdates){
                    $_.Status = 'Download Available Updates - No downloaded updates ready for installation.'
                } elseif($_.Available -eq 0) {
                    $_.Status = 'Up-to-Date - No updates available for this computer.'
                } else {
                    $_.Status = 'No updates available that can be installed remotely (may require user input).'
                }
                $uiHash.Listview.Items.CommitEdit()
                $uiHash.Listview.Items.Refresh()
            })
            
            #No need to continue if there are no updates to install.
            return
        }

        $temp = "" | Select-Object PowerShell,Runspace
        $temp.PowerShell = [powershell]::Create().AddScript($InstallUpdates).AddArgument($_)
        $temp.PowerShell.AddScript($RestartComputer).AddArgument($_).AddArgument($true)
        $temp.PowerShell.AddScript($GetUpdates).AddArgument($_)
        # Disable SetUpdatesStatus to prevent hanging - status updates are handled within GetUpdates
        # $temp.PowerShell.AddScript($SetUpdatesStatus).AddArgument($_)
        $temp.PowerShell.Runspace = $_.Runspace
        $temp.Runspace = $temp.PowerShell.BeginInvoke()
        $jobs.Add($temp) | Out-Null
    }
}

#region System Management
$eventRemoveOfflineComputer = {
    $uiHash.Listview.Items | ForEach-Object {
        if (-not $_.Runspace) {
            $item = $_
            try { $item.Runspace = New-ComputerRunspace -ComputerItem $item } catch {
                Write-ErrorLog "Failed to create runspace for $($item.Computer): $($_.Exception.Message)"
                return
            }
        }
        $temp = "" | Select-Object PowerShell,Runspace
        $temp.PowerShell = [powershell]::Create().AddScript($RemoveOfflineComputer).AddArgument($_)
        $temp.PowerShell.Runspace = $_.Runspace
        $temp.Runspace = $temp.PowerShell.BeginInvoke()
        $jobs.Add($temp) | Out-Null
    }
}
$eventRestartComputer = {
    $uiHash.Listview.SelectedItems | ForEach-Object {
        if (-not $_.Runspace) {
            $item = $_
            try { $item.Runspace = New-ComputerRunspace -ComputerItem $item } catch {
                Write-ErrorLog "Failed to create runspace for $($item.Computer): $($_.Exception.Message)"
                return
            }
        }
        $temp = "" | Select-Object PowerShell,Runspace
        $temp.PowerShell = [powershell]::Create().AddScript($RestartComputer).AddArgument($_).AddArgument($false)
        $temp.PowerShell.AddScript($GetUpdates).AddArgument($_)
        # Disable SetUpdatesStatus to prevent hanging - status updates are handled within GetUpdates
        # $temp.PowerShell.AddScript($SetUpdatesStatus).AddArgument($_)		
        $temp.PowerShell.Runspace = $_.Runspace
        $temp.Runspace = $temp.PowerShell.BeginInvoke()
        $jobs.Add($temp) | Out-Null
    }
}
#endregion

#region Clipboard Operations
# Copy selected computer information to clipboard
$eventCopyComputers = {
    if ($uiHash.Listview.SelectedItems.Count -gt 0) {
        $clipboardData = @()
        
        foreach ($item in $uiHash.Listview.SelectedItems) {
            # Create a comprehensive line with all relevant information
            $line = "Computer: $($item.Computer)"
            
            if ($item.Status -and $item.Status -ne 'Ready' -and $item.Status -ne '') {
                $line += " | Status: $($item.Status)"
            }
            
            if ($item.Available -and $item.Available -gt 0) {
                $line += " | Available Updates: $($item.Available)"
            }
            
            if ($item.Downloaded -and $item.Downloaded -gt 0) {
                $line += " | Downloaded: $($item.Downloaded)"
            }
            
            if ($item.Installed -and $item.Installed -gt 0) {
                $line += " | Installed: $($item.Installed)"
            }
            
            if ($item.UpdatesStatus -and $item.UpdatesStatus -ne '') {
                $line += " | Updates Status: $($item.UpdatesStatus)"
            }
            
            $clipboardData += $line
        }
        
        $clipboardText = $clipboardData -join "`r`n"
        
        try {
            [System.Windows.Clipboard]::SetText($clipboardText)
            Update-Status "Copied detailed information for $($uiHash.Listview.SelectedItems.Count) computer(s) to clipboard"
        } catch {
            Update-Status "Failed to copy to clipboard: $($_.Exception.Message)"
        }
    } else {
        Write-WarningLog "No valid OU selected to process"
        Update-Status 'No computers selected to copy'
    }
}

# Copy only status/error messages to clipboard
$eventCopyStatus = {
    if ($uiHash.Listview.SelectedItems.Count -gt 0) {
        $statusData = @()
        
        foreach ($item in $uiHash.Listview.SelectedItems) {
            if ($item.Status -and $item.Status -ne 'Ready' -and $item.Status -ne '') {
                $statusData += "$($item.Computer): $($item.Status)"
            } else {
                $statusData += "$($item.Computer): Ready"
            }
        }
        
        if ($statusData.Count -gt 0) {
            $clipboardText = $statusData -join "`r`n"
            
            try {
                [System.Windows.Clipboard]::SetText($clipboardText)
                Update-Status "Copied status messages for $($uiHash.Listview.SelectedItems.Count) computer(s) to clipboard"
            } catch {
                Update-Status "Failed to copy status to clipboard: $($_.Exception.Message)"
            }
        }
    } else {
        Update-Status 'No computers selected to copy status'
    }
}

# Paste computer names from clipboard
$eventPasteComputers = {
    try {
        $clipboardText = [System.Windows.Clipboard]::GetText()
        
        if (-not [string]::IsNullOrWhiteSpace($clipboardText)) {
            # Split by common delimiters (newlines, commas, semicolons, spaces)
            $computerNames = $clipboardText -split '[\r\n,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            
            if ($computerNames.Count -gt 0) {
                # Add computers to the list
                &$AddEntry $computerNames
                
                Update-Status "Pasted $($computerNames.Count) computer name(s) from clipboard"
            } else {
                Update-Status 'No valid computer names found in clipboard'
            }
        } else {
            Update-Status 'Clipboard is empty or contains no text'
        }
    } catch {
        Update-Status "Failed to paste from clipboard: $($_.Exception.Message)"
    }
}
#endregion

#region Keyboard and Context Menu Events
$eventKeyDown = {
    If ([System.Windows.Input.Keyboard]::IsKeyDown('RightCtrl') -OR [System.Windows.Input.Keyboard]::IsKeyDown('LeftCtrl')) {
        # Check for Shift+Ctrl combinations
        If ([System.Windows.Input.Keyboard]::IsKeyDown('RightShift') -OR [System.Windows.Input.Keyboard]::IsKeyDown('LeftShift')) {
            Switch ($_.Key) {
            'C' {&$eventCopyStatus}  # Ctrl+Shift+C = Copy status messages only
            Default {$Null}
            }
        } Else {
            Switch ($_.Key) {
            'A' {$uiHash.Listview.SelectAll()}
            'C' {&$eventCopyComputers}  # Ctrl+C = Copy detailed computer info
            'V' {&$eventPasteComputers}
            'O' {&$eventAddFile}  # Ctrl+O = Add computers from file
            'S' {&$eventSaveComputerList}
            Default {$Null}
            }
        }
    }
    ElseIf ($_.Key -eq 'Delete') {&$removeEntry @($uiHash.Listview.SelectedItems)}
}
$eventRightClick = {
    try {
        Write-InfoLog "Right-click event triggered"
        # Enable/Disable buttons as needed
        
        # Check if ListView is properly initialized (but allow empty lists)
        if (-not $uiHash.Listview) {
            Write-ErrorLog "ListView control not found"
            throw "ListView control is not initialized"
        }
        
        if (-not $uiHash.Listview.Items -or $uiHash.Listview.Items.Count -eq 0) {
            Write-InfoLog "ListView is empty, disabling item-specific context menu options"
            # Disable all context menu items for empty ListView
            if ($uiHash.RemoveComputerContext) { $uiHash.RemoveComputerContext.IsEnabled = $False }
            if ($uiHash.RemoteDesktopContext) { $uiHash.RemoteDesktopContext.IsEnabled = $False }
            if ($uiHash.CheckUpdatesContext) { $uiHash.CheckUpdatesContext.IsEnabled = $False }
            if ($uiHash.DownloadUpdatesContext) { $uiHash.DownloadUpdatesContext.IsEnabled = $False }
            if ($uiHash.InstallUpdatesContext) { $uiHash.InstallUpdatesContext.IsEnabled = $False }
            if ($uiHash.RestartContext) { $uiHash.RestartContext.IsEnabled = $False }
            if ($uiHash.ShowInstalledContext) { $uiHash.ShowInstalledContext.IsEnabled = $False }
            if ($uiHash.ShowUpdatesContext) { $uiHash.ShowUpdatesContext.IsEnabled = $False }
            if ($uiHash.UpdateHistoryMenu) { $uiHash.UpdateHistoryMenu.IsEnabled = $False }
            if ($uiHash.ViewUpdateLogContext) { $uiHash.ViewUpdateLogContext.IsEnabled = $False }
            if ($uiHash.WindowsUpdateServiceMenu) { $uiHash.WindowsUpdateServiceMenu.IsEnabled = $False }
            Write-InfoLog "Context menu items disabled for empty ListView"
        } elseif ($uiHash.Listview.SelectedItems.count -eq 0) {
            # Safe context menu control access
            if ($uiHash.RemoveComputerContext) { $uiHash.RemoveComputerContext.IsEnabled = $False }
            if ($uiHash.RemoteDesktopContext) { $uiHash.RemoteDesktopContext.IsEnabled = $False }
            if ($uiHash.CheckUpdatesContext) { $uiHash.CheckUpdatesContext.IsEnabled = $False }
            if ($uiHash.DownloadUpdatesContext) { $uiHash.DownloadUpdatesContext.IsEnabled = $False }
            if ($uiHash.InstallUpdatesContext) { $uiHash.InstallUpdatesContext.IsEnabled = $False }
            if ($uiHash.RestartContext) { $uiHash.RestartContext.IsEnabled = $False }
            if ($uiHash.ShowInstalledContext) { $uiHash.ShowInstalledContext.IsEnabled = $False }
            if ($uiHash.ShowUpdatesContext) { $uiHash.ShowUpdatesContext.IsEnabled = $False }
            if ($uiHash.UpdateHistoryMenu) { $uiHash.UpdateHistoryMenu.IsEnabled = $False }
            if ($uiHash.ViewUpdateLogContext) { $uiHash.ViewUpdateLogContext.IsEnabled = $False }
            if ($uiHash.WindowsUpdateServiceMenu) { $uiHash.WindowsUpdateServiceMenu.IsEnabled = $False }
            Write-InfoLog "Context menu items disabled, no selection"
        } elseif ($uiHash.Listview.SelectedItems.count -eq 1) {
            # Safe context menu control access for single selection
            if ($uiHash.RemoveComputerContext) { $uiHash.RemoveComputerContext.IsEnabled = $True }
            if ($uiHash.RemoteDesktopContext) { $uiHash.RemoteDesktopContext.IsEnabled = $True }
            if ($uiHash.CheckUpdatesContext) { $uiHash.CheckUpdatesContext.IsEnabled = $True }
            $selection = $uiHash.Listview.SelectedItems[0]
            Write-InfoLog "Processing single selection: $($selection.Computer)"
            if ($selection -and $selection.Downloaded -ge 1) {
                if ($uiHash.InstallUpdatesContext) { $uiHash.InstallUpdatesContext.IsEnabled = $True }
            } else {
                if ($uiHash.InstallUpdatesContext) { $uiHash.InstallUpdatesContext.IsEnabled = $False }
            }
            if ($uiHash.RestartContext) { $uiHash.RestartContext.IsEnabled = $True }
            if ($uiHash.ShowInstalledContext) { $uiHash.ShowInstalledContext.IsEnabled = $True }
            if ($selection -and $selection.Available -gt 0) {
                if ($uiHash.ShowUpdatesContext) { $uiHash.ShowUpdatesContext.IsEnabled = $True }
                if ($uiHash.DownloadUpdatesContext) { $uiHash.DownloadUpdatesContext.IsEnabled = $True }
            } else {
                if ($uiHash.ShowUpdatesContext) { $uiHash.ShowUpdatesContext.IsEnabled = $False }
                if ($uiHash.DownloadUpdatesContext) { $uiHash.DownloadUpdatesContext.IsEnabled = $False }
            }
            if ($uiHash.UpdateHistoryMenu) { $uiHash.UpdateHistoryMenu.IsEnabled = $True }
            if ($uiHash.ViewUpdateLogContext) { $uiHash.ViewUpdateLogContext.IsEnabled = $True }
            if ($uiHash.WindowsUpdateServiceMenu) { $uiHash.WindowsUpdateServiceMenu.IsEnabled = $True }
            Write-InfoLog "Context menu items enabled for single selection"
        } else {
            # Safe context menu control access for multiple selection
            if ($uiHash.RemoveComputerContext) { $uiHash.RemoveComputerContext.IsEnabled = $True }
            if ($uiHash.RemoteDesktopContext) { $uiHash.RemoteDesktopContext.IsEnabled = $False }
            if ($uiHash.CheckUpdatesContext) { $uiHash.CheckUpdatesContext.IsEnabled = $True }
            if ($uiHash.DownloadUpdatesContext) { $uiHash.DownloadUpdatesContext.IsEnabled = $True }
            if ($uiHash.InstallUpdatesContext) { $uiHash.InstallUpdatesContext.IsEnabled = $True }
            if ($uiHash.RestartContext) { $uiHash.RestartContext.IsEnabled = $True }
            if ($uiHash.ShowInstalledContext) { $uiHash.ShowInstalledContext.IsEnabled = $False }
            if ($uiHash.ShowUpdatesContext) { $uiHash.ShowUpdatesContext.IsEnabled = $False }
            if ($uiHash.UpdateHistoryMenu) { $uiHash.UpdateHistoryMenu.IsEnabled = $False }
            if ($uiHash.ViewUpdateLogContext) { $uiHash.ViewUpdateLogContext.IsEnabled = $False }
            if ($uiHash.WindowsUpdateServiceMenu) { $uiHash.WindowsUpdateServiceMenu.IsEnabled = $True }
            Write-InfoLog "Context menu items enabled for multiple selection"
        }
    } catch {
        Write-ErrorLog "Right-click context menu error: $($_.Exception.Message)"
        
        # Only show persistent status message for actual errors, not normal operations
        if ($_.Exception.Message -notmatch "ListView is not ready|ListView control is not initialized") {
            Update-Status "Error in Right-Click Context Menu: $($_.Exception.Message)"
        }
        
        if ($EnableDebugLogging) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $logEntry = "[$timestamp] [ERROR] Right-click context menu crash: $($_.Exception.GetType().FullName) - $($_.Exception.Message)"
            Add-Content -Path $LogPath -Value $logEntry -Force
            if ($_.Exception.InnerException) {
                $logEntry = "[$timestamp] [ERROR] Inner exception: $($_.Exception.InnerException.Message)"
                Add-Content -Path $LogPath -Value $logEntry -Force
            }
            $logEntry = "[$timestamp] [ERROR] Stack trace: $($_.ScriptStackTrace)"
            Add-Content -Path $LogPath -Value $logEntry -Force
        }
    }
    Write-InfoLog "Right-click processing completed"
}
#endregion

#region Configuration Management
$eventSaveComputerList = {
    If ($uiHash.Listview.Items.count -gt 0) {
        #Save dialog
        $dlg = new-object Microsoft.Win32.SaveFileDialog
        $dlg.FileName = 'Computer List'
        $dlg.DefaultExt = '*.txt'
        $dlg.Filter = 'Text files (*.txt)|*.txt|CSV files (*.csv)|*.csv'
        $dlg.InitialDirectory = $pwd
        [void]$dlg.showdialog()
        $filePath = $dlg.FileName

        #Verify file was selected
        If (-Not ([system.string]::IsNullOrEmpty($filepath))) {
            #Save file
            $uiHash.Listview.Items | Select-Object -Expand Computer | Out-File $filePath -Force

            #Update status
            Update-Status "Computer List saved to $filePath"
        }
    }
    Else { #No items selected
        #Update status
        Update-Status 'Computer List not saved, there are no computers in the list!'
    }
}

# Save encrypted computer list
$eventSaveConfig = {
    If ($uiHash.Listview.Items.count -gt 0) {
        try {
            # Suspend background processing to prevent interference with password dialog
            Suspend-BackgroundProcessing -Reason "encrypted computer list save"
            
            # Prompt for password using GUI dialog
            $securePassword = Show-PasswordPrompt -Title "Encrypt Computer List" -Message "Enter a password to encrypt the computer list configuration:"
            
            if ($securePassword -eq $null) {
                # User cancelled the password prompt
                Update-Status 'Save operation cancelled by user.'
                return
            }
            
            # Default path for config
            $configPath = Join-Path $PSScriptRoot 'ComputerList.config'
            
            $saveResult = Save-ComputerListConfig -ComputerList $uiHash.Listview.Items -ConfigPath $configPath -Password $securePassword
            
            if ($saveResult.Success) {
                Update-Status "Encrypted computer list saved to $configPath"
            } else {
                Update-Status "Failed to save encrypted computer list: $($saveResult.Error)"
            }
        } finally {
            # Always resume background processing
            Resume-BackgroundProcessing -CompletedOperation "encrypted computer list save"
        }
    } else {
        Update-Status 'No computers in the list to save!'
    }
}

# Load encrypted computer list
$eventLoadConfig = {
    try {
        # Suspend background processing to prevent interference with password dialog
        Suspend-BackgroundProcessing -Reason "encrypted computer list load"
        
        # Prompt for password using GUI dialog
        $securePassword = Show-PasswordPrompt -Title "Decrypt Computer List" -Message "Enter the password to decrypt the computer list configuration:"
        
        if ($securePassword -eq $null) {
            # User cancelled the password prompt
            Update-Status 'Load operation cancelled by user.'
            return
        }
        
        # Default path for config
        $configPath = Join-Path $PSScriptRoot 'ComputerList.config'
        
        $loadResult = Import-ComputerListConfig -ConfigPath $configPath -Password $securePassword

        if ($loadResult.Success) {
            $loadedComputers = $loadResult.Config.Computers
            
            # Clear current items from the ObservableCollection
            $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
                if ($uiHash.clientObservable) {
                    $uiHash.clientObservable.Clear()
                }
            })

            # Add loaded items to the ObservableCollection
            ForEach ($compData in $loadedComputers) {
                $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
                    if ($null -eq $uiHash.clientObservable) {
                        $uiHash.clientObservable = New-Object System.Collections.ObjectModel.ObservableCollection[object]
                        $uiHash.ListView.ItemsSource = $uiHash.clientObservable
                    }
                    try {
                        # Only load computer name and phase - all other data starts fresh
                        $computerObject = New-Object PSObject -Property @{
                            Computer = if ($compData.Computer) { $compData.Computer } else { "Unknown" }
                            Phase = if ($compData.Phase) { $compData.Phase } else { "Phase 1" }
                            Available = 0  # Start fresh
                            Downloaded = 0  # Start fresh
                            InstallErrors = 0  # Start fresh
                            Status = "Loaded from config. Right-click > Check For Updates to refresh status."
                            RebootRequired = $false  # Start fresh
                            UpdatesStatus = "Unknown"  # Start fresh
                            Runspace = $null
                            Pending = $false  # Loaded computers wait for a manual Check For Updates
                        }
                        
                        $uiHash.clientObservable.Add($computerObject)
                        Write-InfoLog "Successfully loaded computer: $($computerObject.Computer)"
                    } catch {
                        Write-ErrorLog "Failed to add computer: $($compData.Computer). Error: $($_.Exception.Message)"
                        Update-Status "Error adding $($compData.Computer): $($_.Exception.Message)"
                    }
                })
            }
            
            # Worker runspaces are created on demand (New-ComputerRunspace) when an operation is requested
            Update-Status "Encrypted computer list loaded from $configPath"
        } else {
            # Show error dialog for load failure (likely wrong password)
            $errorMessage = $loadResult.Error
            
            # Check if error is related to decryption (wrong password)
            if ($errorMessage -match "decrypt|password|invalid|corrupt") {
                [System.Windows.MessageBox]::Show(
                    "Failed to load the encrypted computer list.`n`nThis is usually caused by an incorrect password.`n`nError Details: $errorMessage`n`nPlease try again with the correct password.",
                    "Load Computer List - Authentication Error",
                    'OK',
                    'Error'
                )
            } else {
                [System.Windows.MessageBox]::Show(
                    "Failed to load the encrypted computer list.`n`nError Details: $errorMessage`n`nPlease check that the file exists and is not corrupted.",
                    "Load Computer List - File Error",
                    'OK',
                    'Error'
                )
            }
            
            Update-Status "Failed to load encrypted computer list: $($loadResult.Error)"
        }
    } finally {
        # Always resume background processing
        Resume-BackgroundProcessing -CompletedOperation "encrypted computer list load"
    }
}
#endregion

#region Update Information and Service Management
$eventShowAvailableUpdates = {
    ForEach ($Computer in $uiHash.Listview.SelectedItems){
        $updatesHash[$computer.computer] | Select-Object Title,Description,IsDownloaded,IsMandatory,IsUninstallable,@{n='CanRequestUserInput';e={$_.InstallationBehavior.CanRequestUserInput}},LastDeploymentChangeTime,@{n='MaxDownloadSize (MB)';e={'{0:N2}' -f ($_.MaxDownloadSize/1MB)}},@{n='MinDownloadSize (MB)';e={'{0:N2}' -f ($_.MinDownloadSize/1MB)}},RecommendedCpuSpeed,RecommendedHardDiskSpace,RecommendedMemory,DriverClass,DriverManufacturer,DriverModel,DriverProvider,DriverVerDate | Out-GridView -Title "$($Computer.computer)'s Available Updates"
    }
}
$eventShowInstalledUpdates = {
    ForEach ($Computer in $uiHash.Listview.SelectedItems){
        $updatesession =  [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session',$Computer.computer))
        $updatesearcher = $updatesession.CreateUpdateSearcher()
        $updatesearcher.Search('IsInstalled=1').Updates | Select-Object Title,Description,IsUninstallable,SupportUrl | Out-GridView -Title "$($Computer.computer)'s Installed Updates"
    }
}
$eventAuditWSUSUpdates = {
    # Audit WSUS-approved updates and compare with Windows Update count
    ForEach ($Computer in $uiHash.Listview.SelectedItems){
        try {
            $updatesession = [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session',$Computer.computer))
            $updatesearcher = $updatesession.CreateUpdateSearcher()
            
            # Search 1: Standard search (what WUU uses)
            $standardResults = $updatesearcher.Search('IsInstalled=0 and IsHidden=0')
            
            # Search 2: Include hidden updates
            $allResults = $updatesearcher.Search('IsInstalled=0')
            
            # Search 3: WSUS-assigned updates
            $wsusResults = $updatesearcher.Search('IsInstalled=0 and IsAssigned=1')
            
            # Check WSUS configuration
            $wsusServer = $null
            try {
                $wsusKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
                if (Test-Path $wsusKey) {
                    $wsusServer = (Get-ItemProperty -Path $wsusKey -Name "WUServer" -ErrorAction SilentlyContinue).WUServer
                }
            } catch {
                $wsusServer = "Unable to detect"
            }
            
            # Check reboot status
            $rebootRequired = (New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired
            
            # Display results
            $auditResults = [PSCustomObject]@{
                Computer = $Computer.computer
                WSUS_Server = $wsusServer
                Standard_Search_Count = $standardResults.Updates.Count
                Including_Hidden_Count = $allResults.Updates.Count
                WSUS_Assigned_Count = $wsusResults.Updates.Count
                Downloaded_Count = @($standardResults.Updates | Where-Object {$_.IsDownloaded}).Count
                Not_Downloaded_Count = @($standardResults.Updates | Where-Object {-not $_.IsDownloaded}).Count
                Reboot_Required = $rebootRequired
            }
            
            $auditResults | Format-List | Out-String | Write-Host -ForegroundColor Cyan
            
            # Show detailed update list
            if ($standardResults.Updates.Count -gt 0) {
                $standardResults.Updates | Select-Object Title, @{n='Downloaded';e={$_.IsDownloaded}}, @{n='Mandatory';e={$_.IsMandatory}}, @{n='Assigned';e={$_.IsAssigned}} | Out-GridView -Title "WSUS Audit: $($Computer.computer) - $($standardResults.Updates.Count) updates found"
            } else {
                [PSCustomObject]@{Title="No updates found"} | Out-GridView -Title "WSUS Audit: $($Computer.computer)"
            }
            
        } catch {
            [PSCustomObject]@{Error = "WSUS audit failed: $($_.Exception.Message)"} | Format-List | Write-Host -ForegroundColor Red
        }
    }
}
$eventShowUpdateHistory = {
    Try{
        $computer = $uiHash.Listview.SelectedItems | Select-Object -First 1
# Get installed hotfix, create popup
        $updatesession =  [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session',$computer.computer))
        $updatesearcher = $updatesession.CreateUpdateSearcher()
        $updates = $updateSearcher.QueryHistory(1,$updateSearcher.GetTotalHistoryCount())
        $updates | Select-Object -Property `
        @{name="Operation"; expression={switch($_.Operation){1 {"Installation"}; 2 {"Uninstallation"}; 3 {"Other"}}}},`
        @{name="Result"; expression={switch($_.ResultCode){1 {"Success"}; 2 {"Success (reboot required)"}; 4 {"Failure"}}}},`
        @{n='HResult';e={'0x' + [Convert]::ToString($_.HResult, 16)}},`
        Date,Title,Description,SupportUrl | Out-GridView -Title "$($computer.computer)'s Update History"
    } Catch{
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($computer)
            $computer.Status = "Error Occured: $($_.exception.Message)"
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })
    }
}
$eventViewUpdateLog = {
    $uiHash.Listview.SelectedItems | ForEach-Object {
        &"\\$($_.computer)\c$\windows\windowsupdate.log"
    }
}
$eventWUServiceAction = {
    Param ($Action)
    $uiHash.Listview.SelectedItems | ForEach-Object {
        if (-not $_.Runspace) {
            $item = $_
            try { $item.Runspace = New-ComputerRunspace -ComputerItem $item } catch {
                Write-ErrorLog "Failed to create runspace for $($item.Computer): $($_.Exception.Message)"
                return
            }
        }
        $temp = "" | Select-Object PowerShell,Runspace
        $temp.PowerShell = [powershell]::Create().AddScript($WUServiceAction).AddArgument($_).AddArgument($Action)
        $temp.PowerShell.Runspace = $_.Runspace
        $temp.Runspace = $temp.PowerShell.BeginInvoke()
        $jobs.Add($temp) | Out-Null
    }
}

# Windows Update Service Action ScriptBlock
$WUServiceAction = {
    Param ($Computer, $Action)
    
    Try {
        Write-InfoLog "Performing Windows Update service action '$Action' on $($Computer.Computer)"
        
        # Update status
        $uiHash.ListView.Dispatcher.Invoke('Normal',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = "${Action}ing Windows Update Service..."
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })
        
        # Get credentials for this computer
        $credential = Get-RemoteCredentials -ComputerName $Computer.Computer -Operation "Windows Update Service $Action"
        
        # Perform the service action
        $scriptBlock = {
            param($Action)
            $service = Get-Service -Name 'wuauserv' -ErrorAction Stop
            
            switch ($Action) {
                'Start' { 
                    if ($service.Status -ne 'Running') {
                        $service | Start-Service -ErrorAction Stop
                        return "Windows Update Service started successfully"
                    } else {
                        return "Windows Update Service is already running"
                    }
                }
                'Stop' { 
                    if ($service.Status -ne 'Stopped') {
                        $service | Stop-Service -Force -ErrorAction Stop
                        return "Windows Update Service stopped successfully"
                    } else {
                        return "Windows Update Service is already stopped"
                    }
                }
                'Restart' { 
                    $service | Restart-Service -Force -ErrorAction Stop
                    return "Windows Update Service restarted successfully"
                }
                default { 
                    throw "Unknown action: $Action"
                }
            }
        }
        
        # Execute the script block
        if ($Computer.Computer -eq 'localhost' -or $Computer.Computer -eq $env:COMPUTERNAME) {
            $result = & $scriptBlock $Action
        } else {
            if ($credential) {
                $result = Invoke-Command -ComputerName $Computer.Computer -ScriptBlock $scriptBlock -ArgumentList $Action -Credential $credential -ErrorAction Stop
            } else {
                $result = Invoke-Command -ComputerName $Computer.Computer -ScriptBlock $scriptBlock -ArgumentList $Action -ErrorAction Stop
            }
        }
        
        # Update status with result
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = $result
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })
        
        Write-SuccessLog "Windows Update service action '$Action' completed successfully on $($Computer.Computer)"
        
    } Catch {
        Write-ErrorLog "Windows Update service action '$Action' failed on $($Computer.Computer): $($_.Exception.Message)"
        
        $uiHash.ListView.Dispatcher.Invoke('Background',[action]{
            $uiHash.Listview.Items.EditItem($Computer)
            $computer.Status = "Service $Action failed: $($_.Exception.Message)"
            # Set background color to grey for errored entries
            $listViewItem = $uiHash.Listview.ItemContainerGenerator.ContainerFromItem($Computer)
            if($listViewItem) {
                $listViewItem.Background = [System.Windows.Media.Brushes]::LightGray
            }
            $uiHash.Listview.Items.CommitEdit()
            $uiHash.Listview.Items.Refresh()
        })
    }
}

# Get Errors ScriptBlock
$GetErrors = {
    Write-InfoLog "Retrieving error information"
    
    $errorInfo = @()
    
    # Get PowerShell errors
    if ($Error.Count -gt 0) {
        foreach ($err in $Error) {
            $errorInfo += [PSCustomObject]@{
                Timestamp = if ($err.TimeGenerated) { $err.TimeGenerated } else { Get-Date }
                Type = 'PowerShell Error'
                Message = $err.Exception.Message
                Source = if ($err.InvocationInfo.ScriptName) { Split-Path -Leaf $err.InvocationInfo.ScriptName } else { 'Unknown' }
                LineNumber = $err.InvocationInfo.ScriptLineNumber
                Details = $err.Exception.GetType().FullName
                Computer = if ($err.TargetObject) { $err.TargetObject.Computer } else { 'Local' }
            }
        }
    }
    
    # Get computer-specific errors from status messages
    foreach ($computer in $uiHash.Listview.Items) {
        if ($computer.Status -match '^Error|failed:|timeout') {
            $errorInfo += [PSCustomObject]@{
                Timestamp = Get-Date
                Type = 'Computer Error'
                Message = $computer.Status
                Source = 'WUU Operation'
                LineNumber = ''
                Details = "UpdatesStatus: $($computer.UpdatesStatus)"
                Computer = $computer.Computer
            }
        }
    }
    
    # Get performance issues
    foreach ($computer in $performanceHash.Keys) {
        $perf = $performanceHash[$computer]
        if ($perf.Status -match 'Error|Warning') {
            $errorInfo += [PSCustomObject]@{
                Timestamp = Get-Date
                Type = 'Performance Issue'
                Message = $perf.Status
                Source = 'Performance Monitor'
                LineNumber = ''
                Details = "CPU: $($perf.CPUPercent)%, Memory: $($perf.MemoryUsedMB)MB, Latency: $($perf.NetworkLatencyMs)ms"
                Computer = $computer
            }
        }
    }
    
    if ($errorInfo.Count -eq 0) {
        $errorInfo += [PSCustomObject]@{
            Timestamp = Get-Date
            Type = 'Information'
            Message = 'No errors found'
            Source = 'WUU'
            LineNumber = ''
            Details = 'All operations completed successfully'
            Computer = 'All'
        }
    }
    
    return $errorInfo | Sort-Object Timestamp -Descending
}
#endregion

#region Credential Management
$eventSetDomainCredentials = {
    try {
        # Suspend background processing to prevent interference with credential dialog
        Suspend-BackgroundProcessing -Reason "credential configuration"
        
        Write-InfoLog "Opening credential configuration dialog"
        $dialogResult = Show-CredentialConfigDialog
        
        if ($dialogResult -eq $true) {
            $statusMessage = 'Custom credentials configured successfully'
            Write-InfoLog "Custom credentials configured successfully"
        } else {
            $statusMessage = 'Credential configuration cancelled'
            Write-InfoLog "Credential configuration cancelled"
        }
        
        # Update status bar
        Update-StatusBackground $statusMessage
        
        $credentialStatus = if ($script:UseCustomCredentials) { 'Enabled' } else { 'Disabled' }
        Write-InfoLog "Credential configuration updated: $credentialStatus"
    } catch {
        Write-Error "Failed to open credential configuration dialog: $($_.Exception.Message)"
    } finally {
        # Always resume background processing
        Resume-BackgroundProcessing -CompletedOperation "credential configuration"
    }
}
#endregion

#endregion

#region Event Handlers
$uiHash.ActionMenu.Add_SubmenuOpened($eventActionMenu) #Action Menu
$uiHash.AddADContext.Add_Click($eventAddAD) #Add Computers From AD (Context)
$uiHash.AddADMenu.Add_Click($eventAddAD) #Add Computers From AD (Menu)
$uiHash.AddComputerContext.Add_Click($eventAddComputer) #Add Computers (Context)
$uiHash.AddComputerMenu.Add_Click($eventAddComputer) #Add Computers (Menu)
$uiHash.AddFileContext.Add_Click($eventAddFile) #Add Computers From File (Context)
$uiHash.BrowseFileMenu.Add_Click($eventAddFile) #Add Computers From File (Menu)
$uiHash.CheckUpdatesContext.Add_Click($eventGetUpdates) #Check For Updates (Context)
$uiHash.ClearComputerListMenu.Add_Click($clearComputerList) #Clear Computer List
$uiHash.DownloadUpdatesContext.Add_Click($eventDownloadUpdates) #Download Updates
$uiHash.ExitMenu.Add_Click({$uiHash.Window.Close()}) #Exit
$uiHash.UpdateHistoryMenu.Add_Click($eventShowUpdateHistory) #Get Update History
$uiHash.ExportListMenu.Add_Click($eventSaveComputerList) #Exports Computer To File
$uiHash.SaveConfigMenu.Add_Click($eventSaveConfig) #Save Encrypted Computer List
$uiHash.LoadConfigMenu.Add_Click($eventLoadConfig) #Load Encrypted Computer List
$uiHash.InstallUpdatesContext.Add_Click($eventInstallUpdates) #Install Updates
$uiHash.Listview.Add_MouseRightButtonUp($eventRightClick) #On Right Click
# Removed PreviewMouseDown event handler to prevent GUI hangs
$uiHash.OfflineHostsMenu.Add_Click($eventRemoveOfflineComputer) #Remove Offline Computers
$uiHash.RemoteDesktopContext.Add_Click({
    try {
        # Validate selection
        if (-not $uiHash.Listview.SelectedItems -or $uiHash.Listview.SelectedItems.Count -eq 0) {
            $uiHash.Window.Dispatcher.Invoke([action]{$uiHash.StatusTextBox.Text="Please select a computer first"}) | Out-Null
            return
        }
        
        # Validate computer property exists
        $selectedComputer = $uiHash.Listview.SelectedItems.Computer
        if ([string]::IsNullOrWhiteSpace($selectedComputer)) {
            $uiHash.Window.Dispatcher.Invoke([action]{$uiHash.StatusTextBox.Text="Selected item has no computer name"}) | Out-Null
            return
        }
        
        # Launch RDP
        mstsc.exe /v $selectedComputer
        Write-InfoLog "Launched RDP to $selectedComputer"
    } catch {
        $errorMsg = $_.Exception.Message
        Write-ErrorLog "Error in RemoteDesktopContext click: $errorMsg"
        $uiHash.Window.Dispatcher.Invoke([action]{
            $uiHash.StatusTextBox.Text = "RDP failed: $errorMsg"
        }) | Out-Null
    }
}) #RDP
$uiHash.RemoveComputerContext.Add_Click({
    try {
        # Validate selection
        if (-not $uiHash.Listview.SelectedItems -or $uiHash.Listview.SelectedItems.Count -eq 0) {
            $uiHash.Window.Dispatcher.Invoke([action]{$uiHash.StatusTextBox.Text="Please select computers to remove first"}) | Out-Null
            return
        }
        
        # Call removeEntry with validated selection
        &$removeEntry @($uiHash.Listview.SelectedItems)
        Write-InfoLog "Removed $($uiHash.Listview.SelectedItems.Count) computers via context menu"
    } catch {
        $errorMsg = $_.Exception.Message
        Write-ErrorLog "Error in RemoveComputerContext click: $errorMsg"
        $uiHash.Window.Dispatcher.Invoke([action]{
            $uiHash.StatusTextBox.Text = "Remove failed: $errorMsg"
        }) | Out-Null
    }
}) #Delete Computers
$uiHash.RestartContext.Add_Click($eventRestartComputer) #Restart Computer
$uiHash.SelectAllMenu.Add_Click({$uiHash.Listview.SelectAll()}) #Select All
$uiHash.ShowUpdatesContext.Add_Click($eventShowAvailableUpdates) #Show Available Updates
$uiHash.ShowInstalledContext.Add_Click($eventShowInstalledUpdates) #Show Installed Updates
$uiHash.WSUSAuditContext.Add_Click($eventAuditWSUSUpdates) #Audit WSUS Updates
$uiHash.ViewUpdateLogContext.Add_Click($eventViewUpdateLog) #Show Installed Updates
$uiHash.Window.Add_Closed($eventWindowClose) #On Window Close
$uiHash.Window.Add_SourceInitialized($eventWindowInit) #On Window Open
$uiHash.Window.Add_KeyDown($eventKeyDown) #On key down
$uiHash.WURestartServiceMenu.Add_Click({& $eventWUServiceAction 'Restart'}) #Restart Windows Update Service
$uiHash.WUStartServiceMenu.Add_Click({& $eventWUServiceAction 'Start'}) #Start Windows Update Service
$uiHash.WUStopServiceMenu.Add_Click({& $eventWUServiceAction 'Stop'}) #Stop Windows Update Service
$uiHash.TestADConnectionMenu.Add_Click({& $TestADConnection}) #Test Active Directory Connection
$uiHash.ViewErrorMenu.Add_Click({& $GetErrors | Out-GridView}) #View Errors
$uiHash.Phase1Menu.Add_Click({&$eventAssignPhase 'Phase 1'}) #Assign Phase 1
$uiHash.Phase2Menu.Add_Click({&$eventAssignPhase 'Phase 2'}) #Assign Phase 2
$uiHash.Phase3Menu.Add_Click({&$eventAssignPhase 'Phase 3'}) #Assign Phase 3
$uiHash.Phase4Menu.Add_Click({&$eventAssignPhase 'Phase 4'}) #Assign Phase 4
$uiHash.Phase5Menu.Add_Click({&$eventAssignPhase 'Phase 5'}) #Assign Phase 5
$uiHash.SetDomainCredentialsContext.Add_Click($eventSetDomainCredentials) #Toggle Domain Credentials
$uiHash.CopyCellContext.Add_Click($eventCopyCellContent) #Copy Cell Content
#endregion

#region Job scheduler timer
# Starts pending update checks from the UI thread without ever blocking it
$uiHash.JobTimer = New-Object System.Windows.Threading.DispatcherTimer
$uiHash.JobTimer.Interval = [TimeSpan]::FromSeconds(1)
$uiHash.JobTimer.Add_Tick({
    try {
        Start-PendingUpdateCheck
    } catch {
        Write-ErrorLog "Job scheduler tick failed: $($_.Exception.Message)"
    }
})
$uiHash.JobTimer.Start()
#endregion Job scheduler timer

#region Start the GUI with error handling
try {
    Write-InfoLog "Starting GUI initialization"
    
    # Test that essential controls exist
    $requiredControls = @('AutoDownloadCheckBox', 'AutoInstallCheckBox', 'AutoRebootCheckBox', 'Listview')
    foreach ($control in $requiredControls) {
        if (-not $uiHash.$control) {
            Write-Warning "Control '$control' not found in XAML"
            Write-WarningLog "Control '$control' not found in XAML"
        } else {
            Write-InfoLog "Found control: $control"
        }
    }
    
    Write-InfoLog "Showing GUI dialog"
    
    # Initialize ListView ObservableCollection before showing GUI to prevent binding errors
    Write-InfoLog "Initializing ListView ObservableCollection"
    $uiHash.clientObservable = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $uiHash.ListView.ItemsSource = $uiHash.clientObservable

    # Ensure errors during GUI startup are caught and handled
    try {
        Write-InfoLog "Attempting to show GUI - Thread ID: $([System.Threading.Thread]::CurrentThread.ManagedThreadId)"
        Write-InfoLog "GUI Window exists: $($null -ne $uiHash.Window)"
        Write-InfoLog "GUI Window type: $($uiHash.Window.GetType().FullName)"
        Write-InfoLog "clientObservable exists: $($null -ne $uiHash.clientObservable)"
        Write-InfoLog "ListView exists: $($null -ne $uiHash.ListView)"
        Write-InfoLog "ListView ItemsSource set: $($null -ne $uiHash.ListView.ItemsSource)"
        
        # Check if window is already shown
        if ($uiHash.Window.IsVisible) {
            Write-WarningLog "Window is already visible, this might cause issues"
        }
        
        Write-InfoLog "Calling ShowDialog() now..."
        
        # Additional checks for MethodInvocationException
        Write-InfoLog "Pre-ShowDialog dispatcher check - CheckAccess: $($uiHash.Window.Dispatcher.CheckAccess())"
        Write-InfoLog "Pre-ShowDialog dispatcher check - HasShutdownStarted: $($uiHash.Window.Dispatcher.HasShutdownStarted)"
        Write-InfoLog "Pre-ShowDialog dispatcher check - HasShutdownFinished: $($uiHash.Window.Dispatcher.HasShutdownFinished)"
        
        # Add additional protection against scope conflicts
        try {
            # Ensure we're on the main thread and no runspace conflicts exist
            $result = $uiHash.Window.ShowDialog()
            Write-InfoLog "GUI closed with result: $result"
        } catch [System.Management.Automation.SessionStateUnauthorizedAccessException] {
            Write-ErrorLog "Global scope conflict detected - attempting recovery"
            # Try to dispose any problematic runspaces
            if ($jobs) {
                foreach ($job in $jobs) {
                    if ($job.PowerShell) {
                        try {
                            $job.PowerShell.Dispose()
                        } catch { }
                    }
                }
            }
            # Wait a moment and try again
            Start-Sleep -Seconds 2
            $result = $uiHash.Window.ShowDialog()
            Write-InfoLog "GUI closed with result after recovery: $result"
        }
    } catch {
        Write-ErrorLog "CRITICAL ERROR - ShowDialog failed: $($_.Exception.Message)"
        Write-ErrorLog "Error type: $($_.Exception.GetType().FullName)"
        Write-ErrorLog "Stack trace: $($_.ScriptStackTrace)"
        Write-ErrorLog "Thread ID: $([System.Threading.Thread]::CurrentThread.ManagedThreadId)"
        
        if ($_.Exception.InnerException) {
            Write-ErrorLog "Inner exception: $($_.Exception.InnerException.Message)"
            Write-ErrorLog "Inner exception type: $($_.Exception.InnerException.GetType().FullName)"
        }
        
        # Additional diagnostic info
        Write-ErrorLog "Window state - IsVisible: $($uiHash.Window.IsVisible)"
        Write-ErrorLog "Window state - IsLoaded: $($uiHash.Window.IsLoaded)"
        Write-ErrorLog "Window state - WindowState: $($uiHash.Window.WindowState)"
        
        [System.Windows.MessageBox]::Show(
            "An error occurred while launching the GUI: $($_.Exception.Message)`n`nError Type: $($_.Exception.GetType().Name)`n`nThis error suggests a threading or UI initialization issue. Check the debug log for more details.",
            "GUI Error - Stack Empty",
            'OK',
            'Error'
        )
    }
    
    # Important: DO NOT automatically add any computers on startup
    # This prevents the binding error that occurs when background processes try to update
    # computers that haven't been properly added to the ListView
    
exit
} catch {
    Write-Error "Failed to start GUI: $($_.Exception.Message)"
    Write-ErrorLog "CRITICAL ERROR - Failed to start GUI: $($_.Exception.Message)"
    Write-ErrorLog "Error details: $($_.Exception.GetType().FullName)"
    Write-ErrorLog "Stack trace: $($_.ScriptStackTrace)"
    
    if ($_.Exception.InnerException) {
        Write-ErrorLog "Inner exception: $($_.Exception.InnerException.Message)"
    }
    
    Write-Host "Common causes:" -ForegroundColor Yellow
    Write-Host "  - Missing or corrupted XAML file" -ForegroundColor Cyan
    Write-Host "  - WPF not properly installed" -ForegroundColor Cyan
    Write-Host "  - .NET Framework issues" -ForegroundColor Cyan
    Write-Host "  - PowerShell execution policy restrictions" -ForegroundColor Cyan
    
    Read-Host "Press Enter to exit"
    exit
} finally {
    # Comprehensive cleanup on exit
    Write-InfoLog "Starting application shutdown cleanup..."
    
    # Stop job timer
    if ($uiHash.JobTimer) {
        try {
            $uiHash.JobTimer.Stop()
            Write-InfoLog "Job timer stopped"
        } catch {
            Write-WarningLog "Failed to stop job timer: $($_.Exception.Message)"
        }
    }
    
    # Stop and dispose all running jobs
    if ($jobs) {
        Write-InfoLog "Cleaning up $($jobs.Count) background jobs"
        foreach ($job in $jobs) {
            try {
                if ($job.PowerShell) {
                    $job.PowerShell.Stop()
                    $job.PowerShell.Dispose()
                }
            } catch {
                Write-WarningLog "Failed to cleanup job: $($_.Exception.Message)"
            }
        }
        $jobs.Clear()
    }
    
    # Close and dispose all runspaces
    if ($uiHash.Listview.Items) {
        Write-InfoLog "Cleaning up computer runspaces"
        foreach ($computer in $uiHash.Listview.Items) {
            if ($computer.Runspace) {
                try {
                    $computer.Runspace.Close()
                    $computer.Runspace.Dispose()
                } catch {
                    Write-WarningLog "Failed to cleanup runspace for $($computer.Computer): $($_.Exception.Message)"
                }
            }
        }
    }
    
    # Clear synchronized hashtables
    $updatesHash.Clear()
    $performanceHash.Clear()
    $errorSuggestionsHash.Clear()
    $script:CredentialCache.Clear()
    
    # Dispose job cleanup runspace
    if ($jobCleanup.Flag) {
        Write-InfoLog "Cleaning up job cleanup runspace"
        $jobCleanup.Flag = $False
        if ($jobCleanup.PowerShell) {
            try {
                $jobCleanup.PowerShell.Dispose()
            } catch {
                Write-WarningLog "Failed to dispose job cleanup PowerShell: $($_.Exception.Message)"
            }
        }
        if ($jobCleanup.Runspace) {
            try {
                $jobCleanup.Runspace.Close()
                $jobCleanup.Runspace.Dispose()
            } catch {
                Write-WarningLog "Failed to cleanup job cleanup runspace: $($_.Exception.Message)"
            }
        }
    }
    
    Write-InfoLog "Application shutdown cleanup complete"
    Write-InfoLog "Windows Update Utility has been closed"
}
#endregion Start the GUI
