# Test: T006 — the WPF projection adapter (src\Wuu.Gui.psm1).
#
# WHY THIS SUITE EXISTS
# ---------------------
# Before T006 the ListView WAS the application's state: rows were created as ListView items, handed to
# worker runspaces by reference, and mutated in place under a dispatcher Invoke. Two consequences that
# this suite pins down:
#
#   * There was no engine state to test headlessly, so the projection rules were untestable.
#   * Selection was an object reference into the view, so any refresh/sort/filter invalidated it.
#
# The assertions below are the properties that make the split real rather than nominal:
#   1. the module imports with NO WPF loaded (if it drags WPF in, the split has not happened)
#   2. the row -> view mapping is PURE and correct
#   3. an unknown status is never rendered as OK
#   4. reconcile is by KEY, preserves object identity, and does not rebuild
#   5. selection survives a refresh because it is expressed as keys
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-GuiProjection.ps1

$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$ErrorActionPreference = 'Continue'

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

# ---------------------------------------------------------------------------------------------
# 1. HEADLESS. The adapter must not load WPF merely by being imported. If it does, every consumer
#    (including the engine tests) inherits a WPF dependency it does not want.
# ---------------------------------------------------------------------------------------------
'=== 1. the adapter imports without loading WPF ==='

$wpfBefore = @(Get-Module -Name PresentationFramework, PresentationCore, WindowsBase -ErrorAction SilentlyContinue).Count
Import-Module (Join-Path $repo 'src\Wuu.Gui.psm1') -Force -ErrorAction Stop
$wpfAfter = @(Get-Module -Name PresentationFramework, PresentationCore, WindowsBase -ErrorAction SilentlyContinue).Count

Assert-True ($null -ne (Get-Module Wuu.Gui)) 'Wuu.Gui imports'
Assert-Equal $wpfAfter $wpfBefore 'importing Wuu.Gui loads no WPF assembly (the mapping is headless)'

# And the exported surface is the projection contract, nothing more.
$exported = @((Get-Module Wuu.Gui).ExportedFunctions.Keys | Sort-Object)
Assert-True ($exported -contains 'ConvertTo-WuuViewRow') 'exports ConvertTo-WuuViewRow'
Assert-True ($exported -contains 'Sync-WuuViewCollection') 'exports Sync-WuuViewCollection'
Assert-True ($exported -contains 'Get-WuuSelectedKeys') 'exports Get-WuuSelectedKeys'
Assert-True ($exported -contains 'Select-WuuRowKeys') 'exports Select-WuuRowKeys'
Assert-True ($exported -contains 'Get-WuuStatusToken') 'exports Get-WuuStatusToken'
Assert-True ($exported -contains 'Get-WuuColorBrush') 'exports Get-WuuColorBrush'

# ---------------------------------------------------------------------------------------------
# 2. THE MAPPING. Built from a REAL engine row (Wuu.State's contract), not a hand-made hashtable -
#    otherwise the test would prove the mapping matches the test, not the engine.
# ---------------------------------------------------------------------------------------------
''
'=== 2. engine row -> view row, using a real Wuu.State row ==='

Import-Module (Join-Path $repo 'src\Wuu.State.psm1') -Force -ErrorAction Stop
$row = New-WuuComputerRow -Computer 'HOST-A' -Phase 'Phase 2'
$row.State = 'Checking'
$row.Available = 7
$row.Downloaded = 3
$row.InstallErrors = 1
$row.RebootRequired = $true
$row.Status = 'Checking for updates...'
$row.UpdatesStatus = 'Searching'
Set-WuuComputerRowColor -Row $row -Color 'Error'

$view = ConvertTo-WuuViewRow -Row $row

Assert-Equal $view.Computer 'HOST-A' 'the key is carried through'
Assert-Equal $view.Phase 'Phase 2' 'phase is carried through'
Assert-Equal $view.State 'Checking' 'state is carried through'
Assert-Equal $view.Available 7 'available count is carried through'
Assert-Equal $view.Downloaded 3 'downloaded count is carried through'
Assert-Equal $view.InstallErrors 1 'install errors are carried through (the failure signal)'
Assert-Equal $view.RebootRequired $true 'reboot required is carried through'
Assert-Equal $view.Color 'Error' 'the colour NAME is carried through (no WPF brush in the mapping)'

# The mapping must be pure: no brush may be created, or a headless test could not call it.
Assert-True ($null -eq $view.ColorBrush) 'the mapping leaves ColorBrush for the WPF layer'

# Engine mechanics must NOT leak onto the bound object - a handler reading them off the view instead
# of the engine is how the two states drift apart again.
Assert-True (-not $view.PSObject.Properties['Runspace']) 'Runspace is not projected onto the view row'
Assert-True (-not $view.PSObject.Properties['PendingOp']) 'PendingOp is not projected onto the view row'
Assert-True (-not $view.PSObject.Properties['OperationId']) 'operation identity is not projected onto the view row'

# ---------------------------------------------------------------------------------------------
# 3. UNKNOWN IS NOT OK. The old Get-WuuStatusToken defaulted to [OK], which is the one answer that
#    hides a state nobody recognised.
# ---------------------------------------------------------------------------------------------
''
'=== 3. an unrecognised status is never reported as OK ==='

$unknownRow = New-WuuComputerRow -Computer 'HOST-B'
$unknownRow.State = 'SomeStateNobodyListed'
Assert-Equal (Get-WuuStatusToken -Row $unknownRow) '[?]' 'an unknown state renders [?], not [OK]'

# A row with NO state information at all. Note both fields must be blanked: New-WuuComputerRow seeds
# State='Queued', so blanking only UpdatesStatus leaves a legitimately-known Queued row (which is
# [WAIT], and was the test's bug when it asserted [?] for that case).
$blankRow = New-WuuComputerRow -Computer 'HOST-C'
$blankRow.State = ''
$blankRow.UpdatesStatus = ''
Assert-Equal (Get-WuuStatusToken -Row $blankRow) '[?]' 'a row with no state at all renders [?], not [OK]'

$errRow = New-WuuComputerRow -Computer 'HOST-D'; $errRow.State = 'Error'
Assert-Equal (Get-WuuStatusToken -Row $errRow) '[ERR]' 'Error renders its own token'
$tmoRow = New-WuuComputerRow -Computer 'HOST-E'; $tmoRow.State = 'Timeout'
Assert-Equal (Get-WuuStatusToken -Row $tmoRow) '[TMO]' 'Timeout renders its own token'
$doneRow = New-WuuComputerRow -Computer 'HOST-F'; $doneRow.State = 'Complete'
Assert-Equal (Get-WuuStatusToken -Row $doneRow) '[DONE]' 'Complete renders its own token'

# Colour must never be the only signal: every token is non-empty text.
foreach ($r in @($unknownRow, $errRow, $tmoRow, $doneRow)) {
    Assert-True ([bool](Get-WuuStatusToken -Row $r)) "row $($r.Computer) carries a text token (colour is supplementary)"
}

# ---------------------------------------------------------------------------------------------
# 4. RECONCILE. Key-based add/update/remove, preserving object identity so selection survives.
# ---------------------------------------------------------------------------------------------
''
'=== 4. reconcile by key: add, update in place, remove ==='

$collection = New-Object System.Collections.ObjectModel.ObservableCollection[object]

$r1 = New-WuuComputerRow -Computer 'N1'; $r1.Status = 'first'
$r2 = New-WuuComputerRow -Computer 'N2'; $r2.Status = 'second'

$added = Sync-WuuViewCollection -Collection $collection -EngineRows @($r1, $r2)
Assert-Equal $collection.Count 2 'both rows are added'
Assert-Equal @($added).Count 2 'the added keys are reported'

$viewN1 = $collection | Where-Object { $_.Computer -eq 'N1' }
Assert-Equal $viewN1.Status 'first' 'a new row is projected with its data'

# UPDATE: change the ENGINE row and reconcile again. The view object must be the SAME instance.
$r1.Status = 'updated'
$added2 = Sync-WuuViewCollection -Collection $collection -EngineRows @($r1, $r2)
$viewN1After = $collection | Where-Object { $_.Computer -eq 'N1' }
Assert-Equal $viewN1After.Status 'updated' 'the change reaches the view'
Assert-True ([object]::ReferenceEquals($viewN1, $viewN1After)) 'the view object is UPDATED IN PLACE, not rebuilt (selection identity would otherwise be lost)'
Assert-Equal @($added2).Count 0 'an update reports no additions'

# REMOVE: drop N2 from the engine set.
$null = Sync-WuuViewCollection -Collection $collection -EngineRows @($r1)
Assert-Equal $collection.Count 1 'a row gone from the engine is removed from the view'
Assert-Equal $collection[0].Computer 'N1' 'the surviving row is the right one'

# ADD-BACK keeps order stable and appends the missing key.
$r3 = New-WuuComputerRow -Computer 'N0'
$null = Sync-WuuViewCollection -Collection $collection -EngineRows @($r1, $r3)
Assert-Equal $collection.Count 2 're-adding brings the count back'
Assert-True (($collection | ForEach-Object { $_.Computer }) -contains 'N0') 'the new key is present'

# ---------------------------------------------------------------------------------------------
# 5. SELECTION SURVIVES REFRESH. This is the property the whole key-based design exists for.
# ---------------------------------------------------------------------------------------------
''
'=== 5. selection is expressed as keys, so it survives a refresh ==='

# A minimal stand-in for the parts of a ListView the helpers use. The helpers deliberately depend on
# only SelectedItems/Items, so no live WPF control is needed to prove the semantics.
$items = New-Object System.Collections.ArrayList
foreach ($v in $collection) { [void]$items.Add($v) }
$fakeList = [pscustomobject]@{ Items = $items; SelectedItems = (New-Object System.Collections.ArrayList) }

[void]$fakeList.SelectedItems.Add(($items | Where-Object { $_.Computer -eq 'N0' })[0])
$keys = Get-WuuSelectedKeys -ListView $fakeList
Assert-Equal @($keys).Count 1 'the selection reads back as one key'
Assert-Equal @($keys)[0] 'N0' 'the key is the Computer value'

# Now simulate a refresh that replaces every view object (the worst case for a reference selection).
$refreshed = New-Object System.Collections.ObjectModel.ObservableCollection[object]
Sync-WuuViewCollection -Collection $refreshed -EngineRows @($r1, $r3) | Out-Null

$refreshedList = [pscustomobject]@{
    Items         = (New-Object System.Collections.ArrayList)
    SelectedItems = (New-Object System.Collections.ArrayList)
}
foreach ($v in $refreshed) { [void]$refreshedList.Items.Add($v) }

$restored = Select-WuuRowKeys -ListView $refreshedList -Keys $keys
Assert-Equal $restored 1 'the key selection is restored onto the refreshed (all-new-object) list'
Assert-Equal @(Get-WuuSelectedKeys -ListView $refreshedList)[0] 'N0' 'and it is the same row by key, though the object is new'

# An empty/absent selection must be handled without throwing.
Assert-Equal @(Get-WuuSelectedKeys -ListView $null).Count 0 'a null ListView yields no keys rather than throwing'
Assert-Equal (Select-WuuRowKeys -ListView $null -Keys @('X')) 0 'selecting on a null ListView returns 0 rather than throwing'

# ---------------------------------------------------------------------------------------------
# 6. SELECTION RESOLVES TO ENGINE ROWS, BY KEY (T006.1). Handlers must act on the STORE's row for the
#    selected key, not on the view object - the two are the same object today, but a decoupled
#    projection (T008.1) will make them different, and a handler acting on a view snapshot would then
#    act on stale data. Resolve-WuuSelectedRows is a closure inside Start-WuuApplication, so it is
#    extracted by AST exactly as the app's other internal helpers are tested.
# ---------------------------------------------------------------------------------------------
''
'=== 6. selection resolves to authoritative engine rows by key ==='

Import-Module (Join-Path $repo 'src\Wuu.Core.psm1') -Force -ErrorAction Stop
Import-WuuModules -WuuRoot $repo | Out-Null

$coreAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'src\Wuu.Core.psm1'), [ref]$null, [ref]$null)
$resolveFn = $coreAst.FindAll({ param($a)
    $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Resolve-WuuSelectedRows'
}, $true) | Select-Object -First 1
Assert-True ($null -ne $resolveFn) 'Resolve-WuuSelectedRows exists in Wuu.Core'
. ([scriptblock]::Create($resolveFn.Extent.Text))

$store = New-WuuStateStore
$engineRow = New-WuuComputerRow -Computer 'SEL-1'
Add-WuuComputerRow -Store $store -Row $engineRow | Out-Null

# A VIEW object with the same key but DIFFERENT field values (i.e. a stale snapshot).
$staleViewRow = [pscustomobject]@{ Computer = 'SEL-1'; State = 'STALE-VIEW'; OperationId = 'view-only' }
$selList = [pscustomobject]@{
    SelectedItems = @($staleViewRow)
}

$resolved = @(Resolve-WuuSelectedRows -ListView $selList -Store $store)
Assert-Equal $resolved.Count 1 'the selection resolves to one row'
Assert-True ([object]::ReferenceEquals($resolved[0], $engineRow)) 'resolution returns the STORE row, not the stale view object'
Assert-Equal $resolved[0].State 'Queued' 'and it carries the ENGINE state, not the view snapshot'

# A key with no engine row (a phantom) yields nothing rather than a stale object.
$phantomList = [pscustomobject]@{ SelectedItems = @([pscustomobject]@{ Computer = 'NO-SUCH-ROW' }) }
Assert-Equal @(Resolve-WuuSelectedRows -ListView $phantomList -Store $store).Count 0 'an unknown key resolves to nothing'

# With no store (a rig that has only a ListView), the view object is used as a last resort.
$noStore = @(Resolve-WuuSelectedRows -ListView $selList -Store $null)
Assert-Equal $noStore.Count 1 'without a store the view object is used (fallback preserves behaviour)'

Assert-Equal @(Resolve-WuuSelectedRows -ListView $null -Store $store).Count 0 'a null ListView resolves to no rows'

# The handlers must CALL it, not read SelectedItems directly, or the migration is nominal.
$coreText = [System.IO.File]::ReadAllText((Join-Path $repo 'src\Wuu.Core.psm1'))
$resolvedCalls = ([regex]::Matches($coreText, 'Resolve-WuuSelectedRows -ListView')).Count
Assert-True ($resolvedCalls -ge 6) "the action handlers resolve selection through the store (found $resolvedCalls call sites)"

# ---------------------------------------------------------------------------------------------
# 7. REVISION-GATED PROJECTION (T008.1). A tick queued before a change must not be applied after a
#    newer tick has rendered, or it resurrects a removed row / a pre-reset display. The engine provides
#    a coherent snapshot (rows + revision); the adapter refuses a superseded snapshot.
# ---------------------------------------------------------------------------------------------
''
'=== 7. a superseded snapshot cannot be applied over a newer one ==='

Import-Module (Join-Path $repo 'src\Wuu.State.psm1') -Force -ErrorAction Stop
$store7 = New-WuuStateStore
$global:stateStore = $store7
$r7 = New-WuuComputerRow -Computer 'REV-1'
Add-WuuComputerRow -Store $store7 -Row $r7 | Out-Null

$snap = Get-WuuViewSnapshot -Store $store7
Assert-True ($snap.Schema -eq 'wuu.view.snapshot.v1') 'the snapshot carries a schema'
Assert-True ($snap.Coherent) 'the snapshot is taken coherently under the gate'
Assert-Equal @($snap.Rows).Count 1 'the snapshot carries the fleet'
$revA = [int]$snap.Revision
Assert-True ($revA -gt 0) 'the snapshot carries a revision'

# A change advances the revision, so the OLD snapshot is now superseded.
Add-WuuComputerRow -Store $store7 -Row (New-WuuComputerRow -Computer 'REV-2') | Out-Null
$snapB = Get-WuuViewSnapshot -Store $store7
Assert-True ([int]$snapB.Revision -gt $revA) 'a change advances the revision'

$coll = New-Object System.Collections.ObjectModel.ObservableCollection[object]
# Apply the OLD snapshot first (as a stale queued tick would): accepted, since nothing newer is rendered.
$applied = Sync-WuuViewCollection -Collection $coll -EngineRows @($snap.Rows) -Revision $revA -AppliedRevision 0
Assert-True ($null -ne $applied) 'a NEWER-than-rendered snapshot is applied'
$renderedRevision = $revA

# Now a stale tick arrives (its revision is older than what was rendered) -> refused, collection untouched.
$before = $coll.Count
$refusedSync = Sync-WuuViewCollection -Collection $coll -EngineRows @($snap.Rows) -Revision $revA -AppliedRevision $revA
Assert-True ($null -eq $refusedSync) 'a SUPERSEDED snapshot is refused'
Assert-Equal $coll.Count $before 'and the view collection is left untouched by the refused tick'

# The current snapshot is still applied normally.
$appliedNow = Sync-WuuViewCollection -Collection $coll -EngineRows @($snapB.Rows) -Revision $snapB.Revision -AppliedRevision $renderedRevision
Assert-True ($null -ne $appliedNow) 'the CURRENT snapshot is applied'
Assert-Equal $coll.Count 2 'and the new row appears'

# A caller with no revision (a manual refresh) is applied unconditionally - the gate is opt-in. Proving
# this needs a CHANGE to reconcile: PowerShell unwraps an empty array return to $null, so "nothing to
# add" would look identical to a refusal if we only checked the return value.
Add-WuuComputerRow -Store $store7 -Row (New-WuuComputerRow -Computer 'REV-3') | Out-Null
$snapC = Get-WuuViewSnapshot -Store $store7
$noRev = Sync-WuuViewCollection -Collection $coll -EngineRows @($snapC.Rows)
Assert-Equal $coll.Count 3 'a revision-less call is applied unconditionally (manual refresh path reconciles)'

$global:stateStore = $null

# ---------------------------------------------------------------------------------------------
# 8. ENGINE -> VIEW DECOUPLING (T006.1). The whole point of the projection is that the engine rows and
#    the visible rows are DIFFERENT objects, so an engine write reaches the grid only when the
#    projection copies it. This is asserted headlessly: two INDEPENDENT objects (not the same reference),
#    and a direct mutation of the engine row does NOT change the view until a reconcile runs.
# ---------------------------------------------------------------------------------------------
'=== 8. the view is decoupled from the engine rows ==='

Import-Module (Join-Path $repo 'src\Wuu.State.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $repo 'src\Wuu.Gui.psm1') -Force -ErrorAction Stop
$decStore = New-WuuStateStore
$decRow = New-WuuComputerRow -Computer 'DEC-1'; $decRow.Status = 'engine-v1'
Add-WuuComputerRow -Store $decStore -Row $decRow | Out-Null

$decColl = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$decRev = [int]$decStore.Revision
Sync-WuuViewCollection -Collection $decColl -EngineRows @($decStore.Rows) -Revision $decRev -AppliedRevision 0 | Out-Null
Assert-Equal $decColl.Count 1 'the engine row is projected into the view'
Assert-True (-not [object]::ReferenceEquals($decColl[0], $decRow)) 'the view row is a DISTINCT object from the engine row (decoupled)'

# A direct engine write must NOT leak into the view (proves there is no aliasing left).
$decRow.Status = 'engine-v2'
Assert-Equal $decColl[0].Status 'engine-v1' 'a direct engine write does NOT reach the view until the projection runs'
Assert-True (-not $decColl[0].PSObject.Properties['OperationId']) 'the view row carries no engine identity'

# The reconcile (the projection) is what carries it across.
$decRev2 = [int]$decStore.Revision
$null = Sync-WuuViewCollection -Collection $decColl -EngineRows @($decStore.Rows) -Revision $decRev2 -AppliedRevision $decRev
Assert-Equal $decColl[0].Status 'engine-v2' 'the projection carries the engine value into the view'

# A view-only field must not be writable back onto the engine: mutate the VIEW and confirm the ENGINE
# is unchanged (a one-way projection).
$decColl[0].Status = 'view-only'
Assert-Equal $decRow.Status 'engine-v2' 'a write to the view row does NOT reach the engine (one-way projection)'

# ---------------------------------------------------------------------------------------------
# 9. DESKTOP WPF FIXTURE (T006.2). Everything above is headless. This drives a REAL WPF ListView with
#    the REAL projection helpers, because a headless ObservableCollection cannot show whether the grid
#    actually repaints, keeps selection through a sort, or survives a burst of updates. WPF is loaded
#    lazily here so a headless process without a desktop still runs sections 1-8 (this one SKIPs).
# ---------------------------------------------------------------------------------------------
''
'=== 9. desktop WPF ListView fixture (sorting, selection, repaint) ==='

$desktopOk = $false
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    $desktopOk = $true
} catch { $desktopOk = $false }

if (-not $desktopOk) {
    Write-Host 'SKIP: WPF assemblies unavailable in this host' -ForegroundColor Yellow
} else {
    # SELF-CONTAINED: sections 4-7 reuse `$coll`, so build a fresh store + collection here rather than
    # depending on whatever state they left behind (that coupling broke the first version of this test).
    $deskStore = New-WuuStateStore
    $deskRows = @(
        (New-WuuComputerRow -Computer 'D-0'),
        (New-WuuComputerRow -Computer 'D-1'),
        (New-WuuComputerRow -Computer 'D-2')
    )
    $deskRows[0].State = 'Complete'; $deskRows[1].State = 'Searching'; $deskRows[2].State = 'Queued'
    foreach ($dr in $deskRows) { Add-WuuComputerRow -Store $deskStore -Row $dr | Out-Null }
    $deskColl = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $deskSnap = Get-WuuViewSnapshot -Store $deskStore
    $null = Sync-WuuViewCollection -Collection $deskColl -EngineRows @($deskSnap.Rows)

    $grid = New-Object System.Windows.Controls.ListView
    # Columns live on the GridView VIEW, not on the ListView (a bare ListView has a null Columns
    # collection, so adding to $grid.Columns throws InvokeMethodOnNull and the bindings never apply).
    $gridView = New-Object System.Windows.Controls.GridView
    $gridView.Columns.Add((New-Object System.Windows.Controls.GridViewColumn -Property @{ Header = 'Computer'; DisplayMemberBinding = (New-Object System.Windows.Data.Binding 'Computer'); Width = 120 }))
    $gridView.Columns.Add((New-Object System.Windows.Controls.GridViewColumn -Property @{ Header = 'State';    DisplayMemberBinding = (New-Object System.Windows.Data.Binding 'State');    Width = 120 }))
    $grid.View = $gridView
    $grid.ItemsSource = $deskColl
    $window = New-Object System.Windows.Window
    $window.Content = $grid
    $window.WindowStartupLocation = 'Manual'; $window.Left = -32000; $window.Top = 0
    $window.Show(); $window.UpdateLayout()

    function Invoke-Pump { param($w)
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $null = $w.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ $frame.Continue = $false })
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }

    Assert-Equal @($grid.Items).Count $deskColl.Count 'the real ListView renders the projected rows'

    # SELECTION BY KEY through a SORT: select a row, sort by State so the order changes, then restore.
    $grid.SelectedItems.Clear()
    $grid.SelectedItems.Add((@($grid.Items) | Where-Object { $_.Computer -eq 'D-0' })[0]) | Out-Null
    $selKeys = @(Get-WuuSelectedKeys -ListView $grid)
    Assert-Equal $selKeys[0] 'D-0' 'the selected key is read from the real ListView'

    $grid.Items.SortDescriptions.Clear()
    $grid.Items.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription 'State', 'Ascending'))
    Invoke-Pump -w $window
    # MEASURED: WPF KEEPS the selection across a pure reorder (the same item objects, new order), so
    # selection by key matters when the objects are REPLACED - which the reconcile does not do (it
    # updates in place) but a rebuild would. Assert the preservation, then prove the key path restores
    # after an explicit object replacement.
    Assert-Equal @(Get-WuuSelectedKeys -ListView $grid).Count 1 'selection survives a reorder (WPF keeps the item objects)'

    # Replace every view object (the worst case: a full rebuild) and confirm the KEY restores selection.
    $rebuilt = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $null = Sync-WuuViewCollection -Collection $rebuilt -EngineRows @($deskSnap.Rows)
    $grid.ItemsSource = $rebuilt
    Invoke-Pump -w $window
    Assert-Equal @(Get-WuuSelectedKeys -ListView $grid).Count 0 'a rebuilt collection drops the selection (why keys exist)'
    $restoredSel = Select-WuuRowKeys -ListView $grid -Keys $selKeys
    Assert-Equal $restoredSel 1 'the key selection is RESTORED after a rebuild'
    Assert-Equal @(Get-WuuSelectedKeys -ListView $grid)[0] 'D-0' 'and it re-selects the same computer by key'

    # REPAINT: an accepted projection of a CHANGED row updates the rendered text without a rebuild.
    $before = @($grid.Items).Count
    $deskRows[0].Status = 'desktop-repaint-check'
    $deskSnap2 = Get-WuuViewSnapshot -Store $deskStore
    $null = Sync-WuuViewCollection -Collection $rebuilt -EngineRows @($deskSnap2.Rows) -Revision $deskSnap2.Revision -AppliedRevision 0
    Invoke-Pump -w $window
    $d0 = @(@($grid.Items) | Where-Object { $_.Computer -eq 'D-0' })
    Assert-Equal @($grid.Items).Count $before 'the reconcile did not rebuild the collection (count stable)'
    Assert-Equal $d0.Count 1 'the row is still present after repaint'
    Assert-Equal $d0[0].Status 'desktop-repaint-check' 'the rendered row carries the new value'

    # BURST: many updates in one tick must not throw (the CollectionView is mid-edit if CommitEdit is
    # skipped, which is exactly the failure the CommitEdit-always rule guards).
    try {
        for ($i = 0; $i -lt 25; $i++) {
            $deskRows[0].Status = "burst-$i"
            $null = Sync-WuuViewCollection -Collection $rebuilt -EngineRows @($deskSnap2.Rows) -Revision $deskSnap2.Revision -AppliedRevision 0
            $grid.Items.Refresh()
        }
        $burstOk = $true
    } catch { $burstOk = $false; Write-Host ("  burst error: " + $_.Exception.Message) -ForegroundColor Red }
    Assert-True $burstOk 'a 25-update burst reconciles without a CollectionView error'

    $grid.SelectedItems.Clear()
    $window.Close()

    # REVISION-GATED REPROJECT. A Touch-only write - one that bumps the revision but performs NO
    # dispatcher envelope (the timeout twins, the cleanup loop, the funnel) - must still reach the grid.
    # Now that the grid holds DETACHED view rows, Update-WuuProjection is what carries the change across;
    # nothing consumes Revision by merely refreshing engine objects any more.

    # A Touch-only write: mutate the ENGINE row and bump the revision with NO dispatcher envelope, exactly
    # as SetComputerTimeoutScript / SetCleanupTimeoutScript do. The grid holds DETACHED view rows, so only
    # the projection can carry the change across.
    $storeForTick = New-WuuStateStore
    $tickRow = New-WuuComputerRow -Computer 'SAME-1'
    $tickRow.Status = 'before-touch'
    Add-WuuComputerRow -Store $storeForTick -Row $tickRow | Out-Null

    $tickColl = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $null = Sync-WuuViewCollection -Collection $tickColl -EngineRows @($storeForTick.Rows) -Revision 0 -AppliedRevision 0
    $tickGrid = New-Object System.Windows.Controls.ListView
    $tickView = New-Object System.Windows.Controls.GridView
    $tickView.Columns.Add((New-Object System.Windows.Controls.GridViewColumn -Property @{ Header = 'Status'; DisplayMemberBinding = (New-Object System.Windows.Data.Binding 'Status'); Width = 200 }))
    $tickGrid.View = $tickView
    $tickGrid.ItemsSource = $tickColl
    $tickWin = New-Object System.Windows.Window
    $tickWin.Content = $tickGrid; $tickWin.WindowStartupLocation = 'Manual'; $tickWin.Left = -32000; $tickWin.Top = 0
    $tickWin.Show(); $tickWin.UpdateLayout()

    # The detached view must NOT see the engine write until the projection runs.
    $tickRow.Status = 'after-touch'
    Assert-Equal (@($tickGrid.Items)[0]).Status 'before-touch' 'the detached view does NOT see a Touch-only engine write directly'

    # The tick's job: consume the revision by re-projecting through the same helper the app's tick uses.
    # Update-WuuProjection is a function nested inside Start-WuuApplication (not a module export), so it is
    # extracted from Core's AST exactly as section 6 does for Resolve-WuuSelectedRows.
    $coreTree = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'src\Wuu.Core.psm1'), [ref]$null, [ref]$null)
    $projFn = $coreTree.FindAll({ param($a)
        $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Update-WuuProjection'
    }, $true) | Select-Object -First 1
    Assert-True ($null -ne $projFn) 'Update-WuuProjection exists in Wuu.Core (the tick bridge)'
    . ([scriptblock]::Create($projFn.Extent.Text))

    $uiHash = @{ Listview = $tickGrid; clientObservable = $tickColl }
    $script:lastRenderedRevision = 0
    $global:stateStore = $storeForTick
    Update-WuuProjection
    Invoke-Pump -w $tickWin
    Assert-Equal (@($tickGrid.Items)[0]).Status 'after-touch' 'Update-WuuProjection carries a Touch-only write to the detached view (T008.2 + T006.1)'
    $global:stateStore = $null
    $tickWin.Close()
}

''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
