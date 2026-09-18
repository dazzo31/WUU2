# Release validation: XAML load + control resolution + event handler wiring check
Add-Type -AssemblyName PresentationFramework
$failed = $false

# 1. XAML loads
try {
    $xaml = [xml](Get-Content (Join-Path $PSScriptRoot '..\ui\MainWindow.xaml') -Raw)
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)
    Write-Host 'PASS: ui\MainWindow.xaml loads' -ForegroundColor Green
} catch {
    Write-Host "FAIL: ui\MainWindow.xaml load: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 2. Every control the app wires an event handler to must resolve via FindName.
# Wiring lives in src\Wuu.Core.psm1 since the split (WUU.ps1 is a thin entry point).
$wuu = Get-Content (Join-Path $PSScriptRoot '..\src\Wuu.Core.psm1') -Raw
$controlNames = [regex]::Matches($wuu, '\$uiHash\.(\w+)\.Add_(Click|Closed|SourceInitialized|KeyDown)') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

foreach ($name in $controlNames) {
    if ($name -in @('Window','Listview','ListView')) { continue }
    $c = $win.FindName($name)
    if ($null -eq $c) {
        Write-Host "FAIL: control '$name' has Add_ handler in Wuu.Core.psm1 but not found in XAML" -ForegroundColor Red
        $failed = $true
    } else {
        Write-Host "PASS: $name" -ForegroundColor Green
    }
}

# 3. ui\OUSelector.xaml loads too
try {
    $xaml2 = [xml](Get-Content (Join-Path $PSScriptRoot '..\ui\OUSelector.xaml') -Raw)
    $reader2 = New-Object System.Xml.XmlNodeReader $xaml2
    [void][Windows.Markup.XamlReader]::Load($reader2)
    Write-Host 'PASS: ui\OUSelector.xaml loads' -ForegroundColor Green
} catch {
    Write-Host "FAIL: ui\OUSelector.xaml load: $($_.Exception.Message)" -ForegroundColor Red
    $failed = $true
}

# 3b. ui\CredentialDialog.xaml exists and parses as XML (template placeholders intact)
try {
    $credXamlText = Get-Content (Join-Path $PSScriptRoot '..\ui\CredentialDialog.xaml') -Raw
    $credXamlText -replace '\$Title\b', 'Cred' -replace '\$Message\b', 'Msg' | Out-Null
    [xml]($credXamlText -replace '\$Title\b', 'Credentials' -replace '\$Message\b', 'Enter credentials') | Out-Null
    Write-Host 'PASS: ui\CredentialDialog.xaml template loads' -ForegroundColor Green
} catch {
    Write-Host "FAIL: ui\CredentialDialog.xaml template load: $($_.Exception.Message)" -ForegroundColor Red
    $failed = $true
}

if ($failed) { exit 1 } else { Write-Host "`nAll validation checks passed" -ForegroundColor Cyan }
