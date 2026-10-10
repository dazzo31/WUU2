# Test: simulate a real column-drag (raises Thumb drag events on the actual header grip
# from the real ui\MainWindow.xaml + real src\Wuu.Core.psm1 wiring) and check whether the
# column resizes.
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Test-DragResize.ps1
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Assertion harness. This suite previously only PRINTED its findings and therefore always exited 0
# - it could not fail. A test that cannot fail is not coverage, so the observations below are now
# assertions with the same thresholds the narrative used.
$script:pass = 0
$script:fail = 0
function Assert-True($Condition, $Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "FAIL: $Name" -ForegroundColor Red; $script:fail++ }
}
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -eq "$Expected") { Write-Host "PASS: $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host ("FAIL: {0} - expected '{1}', got '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red; $script:fail++ }
}

# Extract REAL code from src\Wuu.Core.psm1 (moved out of the root WUU.ps1 during the module split).
$corePath = Join-Path $repo 'src\Wuu.Core.psm1'
$tokens = $null; $perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($corePath, [ref]$tokens, [ref]$perr)
$fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Set-ColumnProportionalWidths' }, $true) | Select-Object -First 1
if (-not $fn) { throw 'Set-ColumnProportionalWidths not found in src\Wuu.Core.psm1' }
. ([scriptblock]::Create($fn.Extent.Text))   # dot-source the FUNCTION definition
$initAssign = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$eventWindowInit' }, $true) | Select-Object -First 1
$initText = $initAssign.Right.Extent.Text.Trim()
if ($initText.StartsWith('{')) { $initText = $initText.Substring(1) }
if ($initText.EndsWith('}')) { $initText = $initText.Substring(0, $initText.Length - 1) }
# Trace handler entry (test-only instrumentation)
$initText = $initText.Replace(
    '$script:isDraggingColumn = $false
                            $header = $thumb.TemplatedParent',
    'Add-Content -Path "$env:TEMP\wuu-drag-trace.log" -Value ("DragCompleted fired, tp-null={0}" -f ($null -eq $thumb.TemplatedParent))
                            $script:isDraggingColumn = $false
                            $header = $thumb.TemplatedParent')
Remove-Item "$env:TEMP\wuu-drag-trace.log" -ErrorAction SilentlyContinue

# Real XAML (the current layout; the root WUU.xaml no longer exists).
# NOTE: this suite needs an interactive desktop session (it shows a real window offscreen and pumps
# the dispatcher). It runs in a normal interactive PowerShell session; in a headless/service context
# Show() would not produce a layout and the drag assertions below would fail rather than skip - so do
# not wire it into a non-interactive agent.
$uiHash = [hashtable]::Synchronized(@{})
[xml]$xaml = Get-Content (Join-Path $repo 'ui\MainWindow.xaml') -Raw
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader($xaml)))
$uiHash.Window = $window
$uiHash.ListView = $window.FindName('Listview')
$uiHash.GridView = $window.FindName('GridView')
if (-not $uiHash.ListView -or -not $uiHash.GridView) { throw 'Listview/GridView not found in ui\MainWindow.xaml' }

function Invoke-DispatcherPump {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $null = $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

# Invoke the REAL wiring (function must be dot-sourced BEFORE it so handlers resolve it)
. ([scriptblock]::Create($initText))
$window.Left = -32000; $window.Top = 0
$window.Show(); $window.UpdateLayout()
Invoke-DispatcherPump; Start-Sleep -Milliseconds 100; Invoke-DispatcherPump
$window.UpdateLayout()

$cols = $uiHash.GridView.Columns
Write-Host ("Column widths after init: " + (($cols | ForEach-Object { "$($_.Header)=$([math]::Round($_.Width))" }) -join ', '))

# Find the FIRST real column's header + grip via visual tree
$firstCol = $cols[0]
$targetGrip = $null
$stack = New-Object System.Collections.Generic.Stack[System.Windows.DependencyObject]
$stack.Push($uiHash.ListView)
while ($stack.Count -gt 0) {
    $el = $stack.Pop()
    if ($el -is [System.Windows.Controls.GridViewColumnHeader] -and $el.Column -eq $firstCol) {
        $targetGrip = $el.Template.FindName('PART_HeaderGripper', $el)
        break
    }
    $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el)
    for ($i = 0; $i -lt $n; $i++) { $stack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($el, $i)) }
}
if (-not $targetGrip) { throw 'grip not found for first column' }
Write-Host ("Target: column '$($firstCol.Header)' width=$($firstCol.Width), grip found: $($null -ne $targetGrip)")

# === TEST 1: does a simulated drag change the column width (native PART_HeaderGripper wiring)? ===
$completedArgs = New-Object System.Windows.Controls.Primitives.DragCompletedEventArgs 0, 0, $false
$widthBefore = $firstCol.Width
$targetGrip.RaiseEvent((New-Object System.Windows.Controls.Primitives.DragStartedEventArgs 0, 0))
$targetGrip.RaiseEvent((New-Object System.Windows.Controls.Primitives.DragDeltaEventArgs 40, 0))
$targetGrip.RaiseEvent($completedArgs)
Invoke-DispatcherPump; $window.UpdateLayout()
$widthAfter = $firstCol.Width
$delta = [math]::Round($widthAfter - $widthBefore)
Write-Host ("After simulated drag +40: width {0} -> {1} (delta {2})" -f $widthBefore, $widthAfter, $delta)
Assert-True ($delta -ge 39) "native PART_HeaderGripper resize works (drag +40 grew the column by $delta)"
Assert-True ($delta -lt 45) "no double-adjustment (delta $delta is close to the requested 40)"

# === TEST 2: after drag completes, does the refit keep the dragged width? ===
Assert-True ([bool]$script:userResizedColumns.ContainsKey($firstCol.Header)) 'a completed user drag is recorded in userResizedColumns (so a refit will not undo it)'
Assert-True ([math]::Round($firstCol.Width) -ge 210) "the refit kept the user's dragged width ($([math]::Round($firstCol.Width))) instead of re-proportioning it"

# === TEST 3: drag LEFT (shrink) must not go below column MinWidth ===
$widthBefore2 = $firstCol.Width
$completedArgs2 = New-Object System.Windows.Controls.Primitives.DragCompletedEventArgs 0, 0, $false
$targetGrip.RaiseEvent((New-Object System.Windows.Controls.Primitives.DragStartedEventArgs 0, 0))
$targetGrip.RaiseEvent((New-Object System.Windows.Controls.Primitives.DragDeltaEventArgs -500, 0))
$targetGrip.RaiseEvent($completedArgs2)
Invoke-DispatcherPump; $window.UpdateLayout()
Write-Host ("After drag -500 (native clamps to 0, our handler re-floors to 40): width {0} -> {1}" -f $widthBefore2, $firstCol.Width)
Assert-True ([math]::Round($firstCol.Width) -ge 40) "an over-shrink is floored to the minimum width ($([math]::Round($firstCol.Width))) rather than collapsing the column"

$window.Close()
Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0