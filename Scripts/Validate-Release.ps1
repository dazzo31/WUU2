# Release validation: XAML load + control resolution + event handler wiring check
Add-Type -AssemblyName PresentationFramework
$failed = $false

# 1. XAML loads
try {
    $xaml = [xml](Get-Content (Join-Path $PSScriptRoot '..\WUU.xaml') -Raw)
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)
    Write-Host 'PASS: WUU.xaml loads' -ForegroundColor Green
} catch {
    Write-Host "FAIL: WUU.xaml load: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 2. Every control WUU.ps1 wires an event handler to must resolve via FindName
$wuu = Get-Content (Join-Path $PSScriptRoot '..\WUU.ps1') -Raw
$controlNames = [regex]::Matches($wuu, '\$uiHash\.(\w+)\.Add_(Click|Closed|SourceInitialized|KeyDown)') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

foreach ($name in $controlNames) {
    if ($name -in @('Window','Listview','ListView')) { continue }
    $c = $win.FindName($name)
    if ($null -eq $c) {
        Write-Host "FAIL: control '$name' has Add_ handler in WUU.ps1 but not found in XAML" -ForegroundColor Red
        $failed = $true
    } else {
        Write-Host "PASS: $name" -ForegroundColor Green
    }
}

# 3. OUPicker.xaml loads too
try {
    $xaml2 = [xml](Get-Content (Join-Path $PSScriptRoot '..\OUPicker.xaml') -Raw)
    $reader2 = New-Object System.Xml.XmlNodeReader $xaml2
    [void][Windows.Markup.XamlReader]::Load($reader2)
    Write-Host 'PASS: OUPicker.xaml loads' -ForegroundColor Green
} catch {
    Write-Host "FAIL: OUPicker.xaml load: $($_.Exception.Message)" -ForegroundColor Red
    $failed = $true
}

if ($failed) { exit 1 } else { Write-Host "`nAll validation checks passed" -ForegroundColor Cyan }
