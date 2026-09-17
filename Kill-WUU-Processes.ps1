# Kill hung WUU processes
# Run this on the remote system if WUU.ps1 crashes and locks up

Write-Host "Killing hung WUU processes..." -ForegroundColor Yellow

# Kill PowerShell processes that might be running WUU
Get-Process -Name "powershell*","pwsh*" | Where-Object { 
    $_.MainWindowTitle -like "*WUU*" -or 
    $_.MainWindowTitle -like "*Windows Update*" -or
    $_.Path -like "*WUU*"
} | ForEach-Object {
    Write-Host "Killing process: $($_.ProcessName) (ID: $($_.Id))" -ForegroundColor Red
    Stop-Process -Id $_.Id -Force
}

# Release any locked debug log files
Write-Host "Attempting to release locked log files..." -ForegroundColor Yellow
Get-ChildItem -Path "." -Filter "WUU_Debug_*.log" | ForEach-Object {
    try {
        # Try to release the file lock by opening and closing it
        $fileStream = [System.IO.File]::Open($_.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
        $fileStream.Close()
        Write-Host "Released lock on: $($_.Name)" -ForegroundColor Green
    } catch {
        Write-Host "Could not release lock on: $($_.Name)" -ForegroundColor Red
    }
}

Write-Host "Done. You should now be able to run WUU.ps1 again." -ForegroundColor Green
