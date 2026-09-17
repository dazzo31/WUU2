# WUU Diagnostic - Find Missing Updates
# Run this on the machine with the discrepancy

Write-Host "=== WUU Update Diagnostic ===" -ForegroundColor Cyan
Write-Host "Checking all possible update states..." -ForegroundColor Cyan
Write-Host ""

# Search 1: Standard WUU search (IsInstalled=0 and IsHidden=0)
Write-Host "1. Standard WUU Search (IsInstalled=0 and IsHidden=0):" -ForegroundColor Yellow
$session = New-Object -ComObject 'Microsoft.Update.Session'
$searcher = $session.CreateUpdateSearcher()
$standard = $searcher.Search('IsInstalled=0 and IsHidden=0')
Write-Host "   Found: $($standard.Updates.Count) updates"
$standard.Updates | ForEach-Object { Write-Host "   - $($_.Title)" }
Write-Host ""

# Search 2: Include hidden updates
Write-Host "2. Include Hidden Updates (IsInstalled=0):" -ForegroundColor Yellow
$includeHidden = $searcher.Search('IsInstalled=0')
Write-Host "   Found: $($includeHidden.Updates.Count) updates"
$includeHidden.Updates | ForEach-Object { Write-Host "   - $($_.Title) [Hidden=$($_.IsHidden)]" }
Write-Host ""

# Search 3: Check installed updates that might need reboot
Write-Host "3. Installed Updates (IsInstalled=1):" -ForegroundColor Yellow
$installed = $searcher.Search('IsInstalled=1')
Write-Host "   Found: $($installed.Updates.Count) updates"
Write-Host "   (Showing last 10 installed)"
$installed.Updates | Select-Object -Last 10 | ForEach-Object { Write-Host "   - $($_.Title)" }
Write-Host ""

# Check Reboot Required
Write-Host "4. Reboot Required Check:" -ForegroundColor Yellow
$rebootRequired = (New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired
Write-Host "   Reboot Required: $rebootRequired"
Write-Host ""

# Search 5: Check for updates in specific states
Write-Host "5. Update State Breakdown:" -ForegroundColor Yellow
$allUpdates = $includeHidden.Updates
$downloaded = @($allUpdates | Where-Object {$_.IsDownloaded -eq $true})
$notDownloaded = @($allUpdates | Where-Object {$_.IsDownloaded -eq $false})
Write-Host "   Total (including hidden): $($allUpdates.Count)"
Write-Host "   Downloaded: $($downloaded.Count)"
Write-Host "   Not Downloaded: $($notDownloaded.Count)"
Write-Host ""

# Show all update details
Write-Host "6. Detailed Update Information:" -ForegroundColor Yellow
$allUpdates | ForEach-Object {
    Write-Host "   Title: $($_.Title)"
    Write-Host "   IsInstalled: $($_.IsInstalled)"
    Write-Host "   IsDownloaded: $($_.IsDownloaded)"
    Write-Host "   IsHidden: $($_.IsHidden)"
    Write-Host "   InstallationBehavior: $($_.InstallationBehavior.InstallBehavior)"
    Write-Host "   RebootBehavior: $($_.InstallationBehavior.RebootBehavior)"
    Write-Host "   ---"
}

Write-Host ""
Write-Host "=== Diagnostic Complete ===" -ForegroundColor Cyan
