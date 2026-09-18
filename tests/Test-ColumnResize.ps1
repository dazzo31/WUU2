# Smoke test: load the REAL WUU.xaml, wire the REAL Set-ColumnProportionalWidths from WUU.ps1,
# resize the window programmatically, and verify columns span the width. Closes itself.
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Scripts\Test-ColumnResize.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# --- extract Set-ColumnProportionalWidths from the real WUU.ps1 (AST) ---
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'WUU.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "WUU.ps1 parse errors: $($parseErrors.Count)" }
$fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Set-ColumnProportionalWidths' }, $true) | Select-Object -First 1
if (-not $fn) { throw 'Set-ColumnProportionalWidths not found in WUU.ps1' }

# --- environment like the app: uiHash + window from real XAML ---
$uiHash = [hashtable]::Synchronized(@{})
$xamlFile = Join-Path $repo 'WUU.xaml'
[xml]$xaml = Get-Content $xamlFile -Raw
$reader = New-Object System.Xml.XmlNodeReader($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$uiHash.Window = $window
$uiHash.ListView = $window.FindName('Listview')
$uiHash.GridView = $window.FindName('GridView')
if (-not $uiHash.ListView -or -not $uiHash.GridView) { throw 'Listview/GridView not found in XAML' }

# --- load the real function into this session (dot-source a new scriptblock) ---
. ([scriptblock]::Create($fn.Extent.Text))

# --- also extract the real $eventWindowInit wiring and invoke it (SourceInitialized equivalent) ---
$initAssign = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$eventWindowInit' }, $true) | Select-Object -First 1
if (-not $initAssign) { throw '$eventWindowInit not found in WUU.ps1' }

# --- simulate the app's init: window shown, layout done ---
function Pump-Dispatcher {
    # Process all queued dispatcher ops up to Background priority (includes Render).
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $null = $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

$window.WindowStartupLocation = 'Manual'
$window.Left = -32000; $window.Top = 0   # offscreen
$window.Show()
$window.UpdateLayout()

$cols = $uiHash.GridView.Columns
$names = foreach ($c in $cols) { "$($c.Header)=$([math]::Round($c.ActualWidth,0))" }
Write-Host ("Initial widths: " + ($names -join ', '))
$initialTotal = ($cols | Measure-Object -Property ActualWidth -Sum).Sum

# --- TEST 1: proportional call at default size ---
Set-ColumnProportionalWidths
$window.UpdateLayout()
$total1 = ($cols | Measure-Object -Property ActualWidth -Sum).Sum
$vw = $uiHash.ListView.ActualWidth
Write-Host ("After proportional fit: total={0:N0} viewport={1:N0} match={2}" -f $total1, $vw, ($total1 -le $vw -and ($vw - $total1) -lt 2))

# --- TEST 2: shrink window below column total (the 'window too small' case) ---
# First invoke the REAL eventWindowInit wiring so SizeChanged handler is live
$initText = $initAssign.Right.Extent.Text.Trim()
if ($initText.StartsWith('{')) { $initText = $initText.Substring(1) }
if ($initText.EndsWith('}')) { $initText = $initText.Substring(0, $initText.Length - 1) }
# Sort-handler wiring needs SortHash; provide script-scope state like the app does
. ([scriptblock]::Create($initText))
Write-Host 'REAL $eventWindowInit wiring invoked.'
# Pump the dispatcher so the BeginInvoke(Render) callback runs (grips + first fit)
Pump-Dispatcher
Start-Sleep -Milliseconds 100
Pump-Dispatcher
$window.UpdateLayout()
$totalAfterInit = ($cols | Measure-Object -Property ActualWidth -Sum).Sum
Write-Host ("After init auto-fit: total={0:N0} viewport={1:N0}" -f $totalAfterInit, $uiHash.ListView.ActualWidth)

$window.Width = 400
$window.UpdateLayout()
Pump-Dispatcher   # SizeChanged defers the fit to Render priority - must pump
Start-Sleep -Milliseconds 100
Pump-Dispatcher
$vw2 = $uiHash.ListView.ActualWidth
$total2 = ($cols | Measure-Object -Property ActualWidth -Sum).Sum
Write-Host ("At width 400 (auto): viewport={0:N0} total={1:N0} fits={2}" -f $vw2, $total2, ($total2 -le $vw2))
if ($total2 -le $vw2) { Write-Host '  PASS: columns fit small window (auto via SizeChanged)' } else { Write-Host '  FAIL: columns overflow small window' }

# --- TEST 3: widen window again (auto via SizeChanged) ---
$window.Width = 1200
$window.UpdateLayout()
Pump-Dispatcher
Start-Sleep -Milliseconds 100
Pump-Dispatcher
$total3 = ($cols | Measure-Object -Property ActualWidth -Sum).Sum
$vw3 = $uiHash.ListView.ActualWidth
Write-Host ("At width 1200 (auto): viewport={0:N0} total={1:N0} fits={2}" -f $vw3, $total3, ($total3 -le $vw3))
if ($total3 -le $vw3 -and $vw3 - $total3 -lt 3) { Write-Host '  PASS: columns expand with window (auto)' } else { Write-Host '  FAIL: columns do not expand' }

# --- TEST 4: check grips exist in header template (resizability) ---
$window.UpdateLayout()
$found = 0
$stack = New-Object System.Collections.Generic.Stack[System.Windows.DependencyObject]
$stack.Push($uiHash.ListView)
while ($stack.Count -gt 0) {
    $el = $stack.Pop()
    if ($el -is [System.Windows.Controls.GridViewColumnHeader]) {
        $grip = $el.Template.FindName('PART_HeaderGripper', $el)
        if ($grip) { $found++ }
    }
    $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el)
    for ($i = 0; $i -lt $n; $i++) { $stack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($el, $i)) }
}
Write-Host ("Resize grips found in visual tree: $found / $($cols.Count) (>= needed; extra is the padding header)")
if ($found -ge $cols.Count) { Write-Host '  PASS: all column headers have drag grips' } else { Write-Host '  FAIL: some headers lack grips' }

# --- TEST 5: simulated user drag - a user-resized column keeps its width, others fill ---
$script:userResizedColumns = @{}   # mimic $eventWindowInit's script-scope state
$computerColumn = $cols | Where-Object { $_.Header -eq 'Computer' }
$computerColumn.Width = 60
$script:userResizedColumns['Computer'] = $true
Set-ColumnProportionalWidths
$window.UpdateLayout()
$total5 = ($cols | Measure-Object -Property ActualWidth -Sum).Sum
$vw5 = $uiHash.ListView.ActualWidth
$computerKept = [math]::Round($computerColumn.ActualWidth, 0) -eq 60
Write-Host ("User-resized case: Computer kept 60={0} total={1:N0} viewport={2:N0} fits={3}" -f $computerKept, $total5, $vw5, ($total5 -le $vw5 -and ($vw5 - $total5) -lt 3))
if ($computerKept -and $total5 -le $vw5 -and ($vw5 - $total5) -lt 3) { Write-Host '  PASS: user drag honored, remaining columns fill' } else { Write-Host '  FAIL: user-resize case broken' }

# --- TEST 6: tiny window with pinned minimums - must not exceed minimum sum, no crash ---
$window.Width = 260
$window.UpdateLayout()
Pump-Dispatcher
Start-Sleep -Milliseconds 100
Pump-Dispatcher
$total6 = ($cols | Measure-Object -Property ActualWidth -Sum).Sum
Write-Host ("Tiny window: viewport={0:N0} total={1:N0} (horizontal scroll expected) sum>min*8={2}" -f $uiHash.ListView.ActualWidth, $total6, ($total6 -ge 8*40))
if ($total6 -ge 8*40) { Write-Host '  PASS: minimums respected, no crash' } else { Write-Host '  FAIL: minimums violated' }

$window.Close()
Write-Host 'Smoke test done.'