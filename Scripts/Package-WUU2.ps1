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

# Core runnable files + docs.
#
# 'ComputerList.config' IS DELIBERATELY ABSENT (defect D4 / T027). It is the operator's real
# saved fleet - hostnames, phases and credential mode/username metadata - and it was previously
# listed here, so every release zip disclosed it. Do not re-add it. The staging guard below
# re-checks the built tree so that re-adding it fails the package instead of leaking silently.
#
# 'Exempt.txt' IS DELIBERATELY ABSENT (retired). Legacy PoshPAIG exemption list is no longer shipped.
$include = @(
    "WUU.ps1",
    "README.md",
    "LICENSE",
    "NOTICE",
    "Kill-WUU-Processes.ps1"
)

foreach ($rel in $include) {
    $src = Join-Path $repoRoot $rel
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $staging $rel) -Force
    }
}

# UI layouts (MainWindow.xaml, CredentialDialog.xaml, OUSelector.xaml)
$uiSrc = Join-Path $repoRoot "ui"
if (Test-Path $uiSrc) {
    Copy-Item -Path $uiSrc -Destination (Join-Path $staging "ui") -Recurse -Force
}

# src/ modules (WUU.ps1 imports them at startup)
$srcSrc = Join-Path $repoRoot "src"
if (Test-Path $srcSrc) {
    Copy-Item -Path $srcSrc -Destination (Join-Path $staging "src") -Recurse -Force
}

# Include helper scripts folder
$scriptsSrc = Join-Path $repoRoot "Scripts"
$scriptsDst = Join-Path $staging "Scripts"
if (Test-Path $scriptsSrc) {
    Copy-Item -Path $scriptsSrc -Destination $scriptsDst -Recurse -Force

    # Don't include the packager itself inside the zip (optional, avoids nesting tooling)
    $selfInZip = Join-Path $scriptsDst "Package-WUU2.ps1"
    if (Test-Path $selfInZip) { Remove-Item $selfInZip -Force }

    # Exclude dev-only scratch/tooling (_*.ps1, e.g. _syntax-check, _pack-*). Nothing the
    # app runs at runtime references them - ConfigPaths only uses Download-Patches.ps1 and
    # Install-Patches.ps1 - so they must not ship in a release zip.
    Get-ChildItem -Path $scriptsDst -Filter "_*.ps1" -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force }
}

# Include markdown docs (optional but useful)
Get-ChildItem -Path $repoRoot -Filter "*.md" -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $staging $_.Name) -Force
}

$zipPath = Join-Path $OutputDirectory $ZipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# -------------------------------------------------------------------------------------------------
# OPERATOR-DATA GUARD (D4 / T027). FAIL CLOSED, NOT WARN.
#
# The staged tree is the exact input to the zip, so refusing here is the last point at which a
# leak can be stopped. A warning would have let the previous leak ship for months, because the
# packaging output is success-looking either way; only a hard failure is noticed.
#
# The patterns cover operator data (saved lists), credentials, debug/history logs and the
# dated snapshot scripts that accumulate in the repo root. A release zip has no legitimate
# reason to contain any of them.
# -------------------------------------------------------------------------------------------------
$forbiddenNames = @('ComputerList.config', 'Exempt.txt')
$forbiddenPatterns = @(
    'WUU_backup*', 'WUU_updated_backup*', 'WUU_v1.1*',
    'WUU_debug*', 'WUU_git_version*', 'WUU_perplexity*',
    '*.log'
)
$stagedFiles = @(Get-ChildItem -Path $staging -Recurse -File -ErrorAction SilentlyContinue)
$leaks = @()
foreach ($f in $stagedFiles) {
    if ($forbiddenNames -contains $f.Name) { $leaks += $f.FullName; continue }
    foreach ($pat in $forbiddenPatterns) {
        if ($f.Name -like $pat) { $leaks += $f.FullName; break }
    }
}
if ($leaks.Count -gt 0) {
    $leaks | ForEach-Object { Write-Host "  OPERATOR DATA: $_" -ForegroundColor Red }
    throw "Packaging refused: $($leaks.Count) operator-data/history file(s) would ship in the zip. Remove them from the include list or the repo before packaging."
}

# Compress-Archive's constructor intermittently throws (ConstructorInvokedThrowException)
# when the destination is in the OneDrive-synced dist/ and leaves NO zip behind while
# still reaching the success message below. Use the ZipFile API instead.
#
# BUT NOT `CreateFromDirectory`: on Windows it writes PLATFORM separators, so every nested entry
# becomes `docs\ARCHITECTURE.md`. The ZIP spec REQUIRES `/`, and a non-Windows extractor takes the name
# literally - it creates a FILE called `docs\ARCHITECTURE.md` in the extraction root instead of a folder.
# Measured 2026-10-10: 22 of 27 entries carried a backslash. Entries are therefore created one at a
# time from the relative path with `/`, and the built archive is re-read to THROW if any backslash
# survives (a silent regression here ships a subtly broken package that still "succeeds").
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$stagingFull = (Resolve-Path $staging).Path.TrimEnd('\', '/')
$archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    $stagingFiles = @(Get-ChildItem -Path $stagingFull -Recurse -File)
    foreach ($file in $stagingFiles) {
        $relative = $file.FullName.Substring($stagingFull.Length).TrimStart('\', '/')
        $entryName = $relative -replace '\\', '/'
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $archive.Dispose()
}

if (-not (Test-Path $zipPath)) {
    throw "Packaging failed: zip was not created at $zipPath"
}
$verify = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entryCount = $verify.Entries.Count
    $backslashes = @($verify.Entries | Where-Object { $_.FullName -like '*\*' })
    if ($backslashes.Count -gt 0) {
        throw "Packaging refused: $($backslashes.Count) archive entry(ies) use '\' separators. The ZIP spec requires '/' or non-Windows extractors create flat files named 'dir\file'."
    }
} finally {
    $verify.Dispose()
}
if ($entryCount -lt 1) { throw "Packaging failed: zip at $zipPath has 0 entries" }

Write-Host "Created package: $zipPath ($entryCount entries)" -ForegroundColor Green
Write-Host "Staging folder: $staging" -ForegroundColor DarkGray
