# Runs on the target as SYSTEM via a WUU2 scheduled task; $RunId is prepended by Invoke-WuuRemoteTask.
if (-not $RunId) { $RunId = 'manual' }
$regPath = "HKLM:\SOFTWARE\WUU2\Jobs\$RunId"
function Write-WuuProgress([hashtable]$Data) {
    try {
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name 'State' -Value ($Data | ConvertTo-Json -Compress)
    } catch { }
}

try {
    Write-WuuProgress @{ Phase = 'Searching' }
    $updateSession = New-Object -ComObject 'Microsoft.Update.Session'
    $searchResult = $updateSession.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")
    $pending = @(foreach ($update in $searchResult.Updates) { if (-not $update.IsDownloaded) { $update } })

    # One update per Download() call so progress can be reported between updates
    $numDownloaded = 0
    $i = 0
    foreach ($update in $pending) {
        $i++
        Write-WuuProgress @{ Phase = 'Downloading'; Current = $i; Total = $pending.Count; Title = $update.Title }
        $coll = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        [void]$coll.Add($update)
        $downloader = $updateSession.CreateUpdateDownloader()
        $downloader.Updates = $coll
        $resultCode = $downloader.Download().GetUpdateResult(0).ResultCode
        if ($resultCode -eq 2 -or $resultCode -eq 3) { $numDownloaded++ }
    }

    Write-WuuProgress @{ Phase = 'Done'; Result = 'Success'; Count = $numDownloaded; Total = $pending.Count }
    exit $numDownloaded
} catch {
    Write-WuuProgress @{ Phase = 'Done'; Result = 'Error'; ErrorMessage = $_.Exception.Message }
    exit 9999
}