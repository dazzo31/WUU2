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

# 4. Version constant check (D7)
$configModule = Join-Path $PSScriptRoot '..\src\Wuu.Configuration.psm1'
if (Test-Path $configModule) {
    $configText = Get-Content $configModule -Raw
    if ($configText -match '\$global:WuuVersion\s*=\s*[''"]([^''"]+)[''"]') {
        $ver = $matches[1]
        if ($ver -like '*-cli*') {
            Write-Host "FAIL: WuuVersion '$ver' carries CLI edition suffix" -ForegroundColor Red
            $failed = $true
        } else {
            Write-Host "PASS: version constant defined: $ver (D7)" -ForegroundColor Green
        }
    } else {
        Write-Host "FAIL: no `$global:WuuVersion constant in Wuu.Configuration.psm1 (D7)" -ForegroundColor Red
        $failed = $true
    }
} else {
    Write-Host "FAIL: Wuu.Configuration.psm1 not found" -ForegroundColor Red
    $failed = $true
}

# 5. Root repository hygiene (Exempt.txt retired)
if (Test-Path (Join-Path $PSScriptRoot '..\Exempt.txt')) {
    Write-Host "FAIL: Exempt.txt still present in repo root" -ForegroundColor Red
    $failed = $true
} else {
    Write-Host "PASS: Exempt.txt not in repo root" -ForegroundColor Green
}

# 6. Packaging script does not include operator data or retired files
$pkgScript = Join-Path $PSScriptRoot 'Package-WUU2.ps1'
if (Test-Path $pkgScript) {
    $pkgText = Get-Content $pkgScript -Raw
    if ($pkgText -match '(?m)^\s*["'']Exempt\.txt["'']') {
        Write-Host "FAIL: Package-WUU2.ps1 still includes Exempt.txt in packaging list" -ForegroundColor Red
        $failed = $true
    } else {
        Write-Host "PASS: Package-WUU2.ps1 excludes Exempt.txt" -ForegroundColor Green
    }
    if ($pkgText -match '(?m)^\s*["'']ComputerList\.config["'']') {
        Write-Host "FAIL: Package-WUU2.ps1 includes ComputerList.config in packaging list" -ForegroundColor Red
        $failed = $true
    } else {
        Write-Host "PASS: Package-WUU2.ps1 excludes ComputerList.config (D4)" -ForegroundColor Green
    }
}

if ($failed) { exit 1 } else { Write-Host "`nAll validation checks passed" -ForegroundColor Cyan }
