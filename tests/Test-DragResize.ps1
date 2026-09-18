# Test: simulate a real column-drag (raises Thumb drag events on the actual header grip
# from the real WUU.xaml + real WUU.ps1 wiring) and check whether the column resizes.
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Scripts\Test-DragResize.ps1
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Extract REAL code from WUU.ps1
$tokens = $null; $perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'WUU.ps1'), [ref]$tokens, [ref]$perr)
$fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Set-ColumnProportionalWidths' }, $true) | Select-Object -First 1
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

# Real XAML
$uiHash = [hashtable]::Synchronized(@{})
[xml]$xaml = Get-Content (Join-Path $repo 'WUU.xaml') -Raw
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader($xaml)))
$uiHash.Window = $window
$uiHash.ListView = $window.FindName('Listview')
$uiHash.GridView = $window.FindName('GridView')

function Pump-Dispatcher {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $null = $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

# Invoke the REAL wiring (function must be dot-sourced BEFORE it so handlers resolve it)
. ([scriptblock]::Create($initText))
$window.Left = -32000; $window.Top = 0
$window.Show(); $window.UpdateLayout()
Pump-Dispatcher; Start-Sleep -Milliseconds 100; Pump-Dispatcher
$window.UpdateLayout()

$cols = $uiHash.GridView.Columns
Write-Host ("Column widths after init: " + (($cols | ForEach-Object { "$($_.Header)=$([math]::Round($_.Width))" }) -join ', '))

# Find the FIRST real column's header + grip via visual tree
$firstCol = $cols[0]
$targetGrip = $null; $targetHeader = $null
$stack = New-Object System.Collections.Generic.Stack[System.Windows.DependencyObject]
$stack.Push($uiHash.ListView)
while ($stack.Count -gt 0) {
    $el = $stack.Pop()
    if ($el -is [System.Windows.Controls.GridViewColumnHeader] -and $el.Column -eq $firstCol) {
        $targetHeader = $el
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
Pump-Dispatcher; $window.UpdateLayout()
$widthAfter = $firstCol.Width
$delta = [math]::Round($widthAfter - $widthBefore)
Write-Host ("After simulated drag +40: width {0} -> {1} (delta {2})" -f $widthBefore, $widthAfter, $delta)
if ($delta -ge 39) { Write-Host '  NATIVE RESIZE WORKS: PART_HeaderGripper auto-wiring is functional' }
elseif ($delta -eq 0) { Write-Host '  NATIVE RESIZE DEAD: raising DragDelta changed nothing - no native wiring on this thumb' -ForegroundColor Red }
else { Write-Host ("  UNEXPECTED delta {0} (check for double-adjustment)" -f $delta) -ForegroundColor Yellow }

# === TEST 2: after drag completes, does the refit keep the dragged width? ===
Write-Host ("userResizedColumns marked: $($script:userResizedColumns.ContainsKey($firstCol.Header))")
$total = ($cols | Measure-Object -Property ActualWidth -Sum).Sum
Write-Host ("Post-drag totals: dragged col width={0}, header total={1:N0}, viewport={2:N0}" -f $firstCol.Width, $total, $uiHash.ListView.ActualWidth)

# === TEST 3: drag LEFT (shrink) must not go below column MinWidth ===
$widthBefore2 = $firstCol.Width
$completedArgs2 = New-Object System.Windows.Controls.Primitives.DragCompletedEventArgs 0, 0, $false
$targetGrip.RaiseEvent((New-Object System.Windows.Controls.Primitives.DragStartedEventArgs 0, 0))
$targetGrip.RaiseEvent((New-Object System.Windows.Controls.Primitives.DragDeltaEventArgs -500, 0))
$targetGrip.RaiseEvent($completedArgs2)
Pump-Dispatcher; $window.UpdateLayout()
Write-Host ("After drag -500 (native clamps to 0, our handler re-floors to 40): width {0} -> {1}" -f $widthBefore2, $firstCol.Width)

$window.Close()
Write-Host 'Drag simulation done.'
if ($Error.Count -gt 0) { Write-Host '--- $Error contents ---'; $Error | ForEach-Object { "  $($_.ToString())" } }