param(
    # Nested Join-Path keeps Windows PowerShell 5.1 compatibility (3-arg Join-Path is PS7+)
    [string]$OutputDirectory = (Join-Path (Join-Path $PSScriptRoot "..") "dist"),
    [string]$ZipName = ("WUU2_{0}.zip" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
)

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$OutputDirectory = (Resolve-Path (New-Item -ItemType Directory -Path $OutputDirectory -Force)).Path

$staging = Join-Path $OutputDirectory "staging"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

# Core runnable files + docs
$include = @(
    "WUU.ps1",
    "WUU.xaml",
    "OUPicker.xaml",
    "ComputerList.config",
    "Exempt.txt",
    "README.md",
    "LICENSE",
    "Kill-WUU-Processes.ps1"
)

foreach ($rel in $include) {
    $src = Join-Path $repoRoot $rel
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $staging $rel) -Force
    }
}

# Include helper scripts folder
$scriptsSrc = Join-Path $repoRoot "Scripts"
$scriptsDst = Join-Path $staging "Scripts"
if (Test-Path $scriptsSrc) {
    Copy-Item -Path $scriptsSrc -Destination $scriptsDst -Recurse -Force

    # Don’t include the packager itself inside the zip (optional, avoids nesting tooling)
    $selfInZip = Join-Path $scriptsDst "Package-WUU2.ps1"
    if (Test-Path $selfInZip) { Remove-Item $selfInZip -Force }
}

# Include markdown docs (optional but useful)
Get-ChildItem -Path $repoRoot -Filter "*.md" -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $staging $_.Name) -Force
}

$zipPath = Join-Path $OutputDirectory $ZipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zipPath -Force

Write-Host "Created package: $zipPath" -ForegroundColor Green
Write-Host "Staging folder: $staging" -ForegroundColor DarkGray
