# WSUS Update Audit Tool
# Compares WSUS-approved updates vs what Windows Update COM API reports
# Run on the target machine or remotely

param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [switch]$IncludeHidden,
    [switch]$Verbose
)

Write-Host "=== WSUS Update Audit Tool ===" -ForegroundColor Cyan
Write-Host "Target: $ComputerName" -ForegroundColor Cyan
Write-Host "Date: $(Get-Date)" -ForegroundColor Cyan
Write-Host ""

# Check WSUS configuration
Write-Host "1. WSUS Configuration Check:" -ForegroundColor Yellow
try {
    $wuClient = New-Object -ComObject 'Microsoft.Update.AutoUpdate'
    $wuSettings = $wuClient.Settings
    
    Write-Host "   WSUS Server: $($wuSettings.NotificationLevel)"
    Write-Host "   Update Source: $($wuSettings.ServiceID)"
    
    # Check registry for WSUS settings
    $wsusKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    if (Test-Path $wsusKey) {
        $wsusUrl = Get-ItemProperty -Path $wsusKey -Name "WUServer" -ErrorAction SilentlyContinue
        $wsusStatus = Get-ItemProperty -Path $wsusKey -Name "WUStatusServer" -ErrorAction SilentlyContinue
        Write-Host "   WSUS URL: $($wsusUrl.WUServer)" -ForegroundColor Green
        Write-Host "   WSUS Status: $($wsusStatus.WUStatusServer)" -ForegroundColor Green
    } else {
        Write-Host "   WSUS: Not configured (using Microsoft Update)" -ForegroundColor Gray
    }
} catch {
    Write-Host "   Error checking WSUS config: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Search 1: Standard search (WSUS-approved updates)
Write-Host "2. WSUS-Approved Updates (IsInstalled=0):" -ForegroundColor Yellow
try {
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()
    
    # Search for all uninstalled updates (includes WSUS-approved)
    $searchQuery = 'IsInstalled=0'
    if (-not $IncludeHidden) {
        $searchQuery += ' and IsHidden=0'
    }
    
    Write-Host "   Search Query: $searchQuery" -ForegroundColor Gray
    $results = $searcher.Search($searchQuery)
    
    Write-Host "   Total Found: $($results.Updates.Count)" -ForegroundColor Cyan
    
    if ($results.Updates.Count -gt 0) {
        Write-Host "   Updates:" -ForegroundColor Cyan
        $results.Updates | ForEach-Object {
            $downloaded = if ($_.IsDownloaded) { "[DOWNLOADED]" } else { "[NOT DOWNLOADED]" }
            Write-Host "     - $($_.Title) $downloaded" -ForegroundColor White
        }
    } else {
        Write-Host "   No updates found." -ForegroundColor Gray
    }
} catch {
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Search 2: Check for WSUS-specific updates
Write-Host "3. WSUS-Specific Search (IsApproved=1):" -ForegroundColor Yellow
try {
    $searcher2 = $session.CreateUpdateSearcher()
    # Try WSUS-specific search query
    $wsusResults = $searcher2.Search('IsInstalled=0 and IsAssigned=1')
    Write-Host "   Assigned Updates Found: $($wsusResults.Updates.Count)" -ForegroundColor Cyan
    
    if ($wsusResults.Updates.Count -gt 0 -and $Verbose) {
        $wsusResults.Updates | ForEach-Object {
            Write-Host "     - $($_.Title)" -ForegroundColor White
        }
    }
} catch {
    Write-Host "   WSUS search not supported or error: $($_.Exception.Message)" -ForegroundColor Gray
}
Write-Host ""

# Search 3: Check update history for WSUS-related failures
Write-Host "4. Windows Update History (Last 20 entries):" -ForegroundColor Yellow
try {
    $history = $searcher.GetHistory(0, 20)
    Write-Host "   Recent Update Activity:" -ForegroundColor Cyan
    
    $history | ForEach-Object {
        $result = $_.ResultCode
        $resultCodeStr = switch ($result) {
            0 { "Not Started" }
            1 { "In Progress" }
            2 { "Success" }
            3 { "Success with Errors" }
            4 { "Failed" }
            5 { "Aborted" }
            default { "Unknown ($result)" }
        }
        
        $fgColor = switch ($result) {
            2 { "Green" }
            3 { "Yellow" }
            4 { "Red" }
            5 { "Red" }
            default { "White" }
        }
        
        Write-Host "     [$($_.Date)] $($_.Title) - $resultCodeStr" -ForegroundColor $fgColor
    }
} catch {
    Write-Host "   Error reading history: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Search 4: Check for pending reboot state
Write-Host "5. Reboot Status:" -ForegroundColor Yellow
try {
    $systemInfo = New-Object -ComObject 'Microsoft.Update.SystemInfo'
    $rebootRequired = $systemInfo.RebootRequired
    Write-Host "   Reboot Required: $rebootRequired" -ForegroundColor $(if($rebootRequired){"Red"}else{"Green"})
} catch {
    Write-Host "   Error checking reboot: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Search 5: Check Windows Update service status
Write-Host "6. Windows Update Service Status:" -ForegroundColor Yellow
try {
    $wuService = Get-Service -Name wuauserv -ErrorAction Stop
    Write-Host "   Service: $($wuService.Status)" -ForegroundColor $(if($wuService.Status -eq 'Running'){"Green"}else{"Yellow"})
    Write-Host "   Startup: $($wuService.StartType)" -ForegroundColor Gray
} catch {
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Search 6: Check for WSUS client logging
Write-Host "7. WSUS Client Log Files:" -ForegroundColor Yellow
$logPath = "$env:WINDIR\WindowsUpdate.log"
$etlPath = "$env:WINDIR\Logs\WindowsUpdate"

if (Test-Path $etlPath) {
    $latestEtl = Get-ChildItem -Path $etlPath -Filter "*.etl" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestEtl) {
        Write-Host "   Latest ETL: $($latestEtl.Name) ($($latestEtl.LastWriteTime))" -ForegroundColor Green
        Write-Host "   Location: $etlPath" -ForegroundColor Gray
    }
} elseif (Test-Path $logPath) {
    Write-Host "   Legacy Log: $logPath" -ForegroundColor Yellow
} else {
    Write-Host "   No update logs found" -ForegroundColor Gray
}
Write-Host ""

# Summary
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "This tool shows WSUS-approved updates visible to the Windows Update Agent." -ForegroundColor White
Write-Host ""
Write-Host "If WSUS-approved updates are missing:" -ForegroundColor Yellow
Write-Host "  1. Check WSUS server approval status" -ForegroundColor White
Write-Host "  2. Verify client is pointing to correct WSUS server" -ForegroundColor White
Write-Host "  3. Run 'wuauclt /detectnow' or 'usoclient StartScan'" -ForegroundColor White
Write-Host "  4. Check Windows Update event logs for errors" -ForegroundColor White
Write-Host "  5. Clear Windows Update cache (net stop wuauserv, del %windir%\SoftwareDistribution, net start wuauserv)" -ForegroundColor White
Write-Host ""
