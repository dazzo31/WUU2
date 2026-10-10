# Test: T006/T007 step A — the engine store is created and MIRRORS the fleet.
#
# WHY THIS SUITE EXISTS
# ---------------------
# The engine (Wuu.State) was complete and tested, but UNUSED: measured, nothing in src/ called
# New-WuuStateStore, Add-WuuComputerRow or Update-WuuOperationState, and no runspace received a store.
# Production keeps its state in ListView.Items. Step A makes the store exist and be TRUTHFUL by
# mirroring row add/remove, WITHOUT moving any read or write off the ListView - so this suite asserts
# both halves of that contract:
#
#   (a) the mirroring is real (rows land in the store, and removal propagates)
#   (b) it is additive only (the row object is shared by REFERENCE, so no second copy can drift)
#
# Property (b) is the important one: if the store held a COPY, the store and the UI would disagree the
# moment anything wrote to a row, and the future worker fence would compare against stale data. Proving
# reference identity is what makes this step safe to build on.
#
# Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-StateStoreMirror.ps1

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

Import-Module (Join-Path $repo 'src\Wuu.Core.psm1') -ErrorAction Stop
Import-WuuModules -WuuRoot $repo | Out-Null

# ---------------------------------------------------------------------------------------------
# 1. THE STORE. Created through the same function the app calls at startup.
# ---------------------------------------------------------------------------------------------
'=== 1. the store contract ==='

$store = New-WuuStateStore
Assert-True ($null -ne $store) 'New-WuuStateStore returns a store'
Assert-True ($store -is [hashtable]) 'the store is a hashtable'
Assert-True ($null -ne $store.Rows) 'the store exposes Rows'
Assert-True ($null -ne $store.ByName) 'the store exposes ByName (the O(1) lookup the worker twin needs)'
Assert-True ($null -ne $store.Settings) 'the store exposes Settings'
Assert-Equal $store.Rows.Count 0 'a fresh store has no rows'
Assert-True ($store.PSObject.Methods['Touch']) 'the store exposes Touch() so a worker can signal a redraw without a module function'

# ---------------------------------------------------------------------------------------------
# 2. MIRRORING ADD. Built from the same row shape production creates.
# ---------------------------------------------------------------------------------------------
''
'=== 2. rows are mirrored into the store on add ==='

# Same property set the Add-Computer sites build, so this test cannot drift from production shape.
function New-TestUiRow([string]$Computer) {
    [pscustomobject]@{
        State          = 'Queued'
        StateTimestamp = Get-Date
        StateSource    = 'Add-Computer-Direct'
        Computer       = $Computer
        Phase          = 'Phase 1'
        Available      = 0
        Downloaded     = 0
        InstallErrors  = 0
        Status         = 'Initializing...'
        RebootRequired = $false
        UpdatesStatus  = 'Initializing'
        Runspace       = $null
        Pending        = $true
        TimeoutExpiresAt = $null
        TimeoutSource  = ''
        RetryCount     = 0
        RetryAt        = $null
    }
}

$uiA = New-TestUiRow 'MIRROR-A'
$uiB = New-TestUiRow 'MIRROR-B'

# THE FINDING THIS SUITE RECORDED. A production row is a literal property bag that predates the
# engine, and a [pscustomobject] THROWS when you assign a property it was not created with. Assert the
# throw first, then that the backfill repairs it - otherwise the reason Set-WuuRowEngineDefaults exists
# would only be in a comment.
$identityThrew = $false
try { $uiA.OperationId = 'too-early' } catch { $identityThrew = $true }
Assert-True $identityThrew 'an un-backfilled production row CANNOT take an OperationId (property absent)'

$addedProps = Set-WuuRowEngineDefaults -Row $uiA
Assert-True (@($addedProps) -contains 'OperationId') 'the backfill adds OperationId'
Assert-True (@($addedProps) -contains 'LastResetOperationId') 'the backfill adds LastResetOperationId (the reset fence needs it)'
Assert-True (@($addedProps) -contains 'Color') 'the backfill adds Color (the colour helper writes it)'
Set-WuuRowEngineDefaults -Row $uiB | Out-Null

Add-WuuComputerRow -Store $store -Row $uiA | Out-Null
Add-WuuComputerRow -Store $store -Row $uiB | Out-Null

Assert-Equal $store.Rows.Count 2 'both added rows are in the store'
Assert-True ($null -ne $store.ByName['mirror-a']) 'lookup is by lower-cased key (workers resolve this way)'
Assert-Equal $store.ByName['mirror-a'].Computer 'MIRROR-A' 'the key resolves to the right row'

# ---------------------------------------------------------------------------------------------
# 3. SHARED BY REFERENCE - the property that makes this step additive-only.
# ---------------------------------------------------------------------------------------------
''
'=== 3. the store holds the SAME object, not a copy ==='

Assert-True ([object]::ReferenceEquals($store.ByName['mirror-a'], $uiA)) 'the store row IS the UI row object (by reference)'

# Because it is the same object, a write through the UI row is visible through the store. If the store
# held a copy this would fail - and the future worker fence would compare against stale data.
$uiA.State = 'Searching'
Assert-Equal $store.ByName['mirror-a'].State 'Searching' 'a UI-side write is visible through the store (no second copy to drift)'

$uiA.OperationId = 'op-12345'
Assert-Equal $store.ByName['mirror-a'].OperationId 'op-12345' 'an operation id written on the UI row is readable from the store (the fence will need this)'

# ---------------------------------------------------------------------------------------------
# 4. REPLACE SEMANTICS. Adding the same Computer twice must not duplicate it.
# ---------------------------------------------------------------------------------------------
''
'=== 4. re-adding the same computer replaces rather than duplicates ==='

$uiA2 = New-TestUiRow 'MIRROR-A'
$uiA2.State = 'Complete'
Set-WuuRowEngineDefaults -Row $uiA2 | Out-Null
Add-WuuComputerRow -Store $store -Row $uiA2 | Out-Null

Assert-Equal $store.Rows.Count 2 're-adding the same Computer does not grow the row list'
Assert-Equal $store.ByName['mirror-a'].State 'Complete' 'the newly added row replaces the old one'
Assert-True ([object]::ReferenceEquals($store.ByName['mirror-a'], $uiA2)) 'and the replacement is the new object'

# ---------------------------------------------------------------------------------------------
# 5. MIRRORING REMOVE.
# ---------------------------------------------------------------------------------------------
''
'=== 5. removal propagates to the store ==='

$removed = Remove-WuuComputerRow -Store $store -Computer 'MIRROR-B'
Assert-True $removed 'removing an existing computer reports success'
Assert-Equal $store.Rows.Count 1 'the row list shrinks'
Assert-True (-not $store.ByName.ContainsKey('mirror-b')) 'the lookup entry is gone'

$removedAgain = Remove-WuuComputerRow -Store $store -Computer 'MIRROR-B'
Assert-True (-not $removedAgain) 'removing an absent computer reports failure rather than throwing'

# Removal must be CASE-INSENSITIVE, because workers resolve by a lower-cased key and operators type
# hostnames in whatever case they like.
$uiC = New-TestUiRow 'MiXeD-Case-Host'
Set-WuuRowEngineDefaults -Row $uiC | Out-Null
Add-WuuComputerRow -Store $store -Row $uiC | Out-Null
Assert-True (Remove-WuuComputerRow -Store $store -Computer 'mixed-case-host') 'removal matches case-insensitively'

# ---------------------------------------------------------------------------------------------
# 6. REVISION. The redraw signal the projection layer polls.
# ---------------------------------------------------------------------------------------------
''
'=== 6. the revision counter moves on change ==='

$before = [int]$store.Revision
$uiD = New-TestUiRow 'REV-HOST'
Set-WuuRowEngineDefaults -Row $uiD | Out-Null
Add-WuuComputerRow -Store $store -Row $uiD | Out-Null
$afterAdd = [int]$store.Revision
Assert-True ($afterAdd -gt $before) 'adding a row advances the revision'

Remove-WuuComputerRow -Store $store -Computer 'REV-HOST' | Out-Null
$afterRemove = [int]$store.Revision
Assert-True ($afterRemove -gt $afterAdd) 'removing a row advances the revision'

# ---------------------------------------------------------------------------------------------
# 7. THE WIRING ITSELF. The store must be wired into startup and into every runspace, or the mirror
#    would exist while the worker twin still could not see it.
# ---------------------------------------------------------------------------------------------
''
'=== 7. the store is wired into startup and runspace creation ==='

$coreSrc = [System.IO.File]::ReadAllText((Join-Path $repo 'src\Wuu.Core.psm1'))
Assert-True ($coreSrc -match '\$global:stateStore\s*=\s*New-WuuStateStore') 'startup creates the global store'
Assert-True ($coreSrc -match 'StateStore\s*=\s*\$global:stateStore') 'the store is handed to the job layer via the context'

# The BULK LOAD path is a WHOLE-INVENTORY REPLACE, so it commits through Set-WuuComputerRows (one
# atomic step) rather than per-row Add-WuuComputerRow. The per-row ADD sites are the direct and
# dispatched single-computer adds.
$addSites = ([regex]::Matches($coreSrc, 'Add-WuuComputerRow\s+-Store\s+\$global:stateStore')).Count
Assert-True ($addSites -ge 2) "every single-computer ListView add site mirrors into the store (found $addSites of 2: direct, dispatched)"
Assert-True ($coreSrc -match 'Set-WuuComputerRows\s+-Store\s+\$global:stateStore') 'the bulk config load commits the store atomically via Set-WuuComputerRows'

# The ROW-REMOVAL paths. `$removeEntry` (the main-session removal) calls the module remover directly.
# The RemoveOffline PAYLOAD cannot - a module function is not resolvable in a worker runspace - so it
# uses the INJECTED `RemoveComputerRowScript` twin, which itself removes from the same store. Exactly
# one direct module call therefore remains; the worker path is the twin.
$removeSites = ([regex]::Matches($coreSrc, 'Remove-WuuComputerRow\s+-Store\s+\$global:stateStore')).Count
Assert-True ($removeSites -ge 1) "the main-session removal mirrors into the store (found $removeSites of 1)"
Assert-True ($coreSrc -match '\$RemoveComputerRowScript') 'the worker removal path uses the injected store-removal twin (the module remover cannot resolve in a worker runspace)'

$updateSrc = [System.IO.File]::ReadAllText((Join-Path $repo 'src\Wuu.WindowsUpdate.psm1'))
Assert-True ($updateSrc -match "SetVariable\(""stateStore"",\`$ctx\.StateStore\)") 'New-ComputerRunspace injects the store into every per-computer runspace'
# Every mirror site must backfill FIRST. A mirror without the backfill would register a row the
# engine cannot write to, which is the defect this suite found.
$backfillSites = ([regex]::Matches($coreSrc, 'Set-WuuRowEngineDefaults\s+-Row')).Count
Assert-True ($backfillSites -ge 3) "every mirror site backfills the engine contract first (found $backfillSites of 3)"

# =============================================================================================
# 9. ATOMIC WHOLE-INVENTORY REPLACEMENT (G3 / T007.7). A config load is a WHOLE replace, and it must
#    be ONE step: a reader must see either the old fleet or the new one, never a half-rebuilt one, and
#    a failed load must leave the existing fleet untouched.
# =============================================================================================
''
'=== 9. atomic whole-inventory replacement ==='

$swapStore = New-WuuStateStore
foreach ($name in @('OLD-A', 'OLD-B', 'OLD-C')) {
    $r = New-WuuComputerRow -Computer $name
    Add-WuuComputerRow -Store $swapStore -Row $r | Out-Null
}
$revisionBeforeSwap = [int]$swapStore.Revision

$newRows = @((New-WuuComputerRow -Computer 'NEW-1'), (New-WuuComputerRow -Computer 'NEW-2'))
Set-WuuComputerRows -Store $swapStore -Rows $newRows | Out-Null

Assert-Equal $swapStore.Rows.Count 2 'the whole inventory is replaced in one step'
Assert-Equal $swapStore.ByName.Count 2 'the name lookup is replaced with it'
Assert-True ($null -eq $swapStore.ByName['old-a']) 'no old row survives the replacement'
Assert-True ($null -ne $swapStore.ByName['new-1']) 'the new rows are registered'
Assert-True ([object]::ReferenceEquals($swapStore.ByName['new-2'], $newRows[1])) 'the store holds the SAME new row objects (by reference)'
Assert-Equal ([int]$swapStore.Revision - $revisionBeforeSwap) 1 'the whole replacement bumps the revision exactly ONCE (not once per row)'

# A row removed from the fleet is a real orphan afterwards - the funnel refuses writes to it.
$orphaned = $newRows[0]
$staleName = [string]$orphaned.Computer
Set-WuuComputerRows -Store $swapStore -Rows @($newRows[1]) | Out-Null
Assert-True ($null -eq $swapStore.ByName[$staleName.ToLowerInvariant()]) 'the dropped row is gone from the lookup'
Assert-Equal $swapStore.Rows.Count 1 'and gone from the ordered list'

# An EMPTY replacement is the clear-list path: the store empties in one step too.
Set-WuuComputerRows -Store $swapStore -Rows @() | Out-Null
Assert-Equal $swapStore.Rows.Count 0 'an empty replacement clears the whole inventory atomically'
Assert-Equal $swapStore.ByName.Count 0 'and clears the lookup with it'

# A config file is trusted verbatim and can name the same computer twice; the replacement must collapse
# it, or Rows and ByName would disagree (a duplicate the lookup could never resolve).
$dupOne = New-WuuComputerRow -Computer 'DUPE-1'
$dupTwo = New-WuuComputerRow -Computer 'DUPe-1'
Set-WuuComputerRows -Store $swapStore -Rows @($dupOne, $dupTwo) | Out-Null
Assert-Equal $swapStore.Rows.Count 1 'a duplicate computer name is collapsed to ONE row'
Assert-Equal $swapStore.ByName.Count 1 'and the lookup agrees with the row list'
Assert-True ([object]::ReferenceEquals($swapStore.ByName['dupe-1'], $dupOne)) 'the FIRST occurrence wins (deterministic)'

'=== 8. clear-list binding is case-insensitive and does not overwrite itself ==='
$clearTokens = $null
$clearErrors = $null
$coreAst = [System.Management.Automation.Language.Parser]::ParseInput($coreSrc, [ref]$clearTokens, [ref]$clearErrors)
$clearAssignments = @($coreAst.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -eq 'clearComputerList'
}, $true))
Assert-Equal $clearErrors.Count 0 'the clear-list regression fixture parses production Core'
Assert-Equal $clearAssignments.Count 1 'clear-list has one binding, not an alias overwriting the same variable'

if ($clearAssignments.Count -eq 1) {
    $clearExpression = $clearAssignments[0].Right.Find({ param($node)
        $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
    }, $true)
    $clearText = $clearExpression.ScriptBlock.Extent.Text
    $clearBody = [scriptblock]::Create($clearText.Substring(1, $clearText.Length - 2))
    $removalTrace = New-Object System.Collections.Generic.List[string]
    $fixtureRows = @([pscustomobject]@{ Computer = 'CLEAR-A' }, [pscustomobject]@{ Computer = 'CLEAR-B' })
    # DECOUPLED (T006.1): the clear-list body must source the set from the ENGINE STORE, not the
    # ListView (which now holds detached view rows). The view here is deliberately EMPTY: if the body
    # read `$uiHash.Listview.Items` it would delegate zero rows, so this fixture is discriminating.
    $savedStore = $global:stateStore
    $global:stateStore = @{ Rows = $fixtureRows }
    & {
        param($Body, $Rows, $Trace)
        $uiHash = @{ Listview = @{ Items = @() } }
        $removeEntry = { param($RowsToRemove)
            foreach ($rowToRemove in $RowsToRemove) { $Trace.Add($rowToRemove.Computer) }
        }
        function Write-InfoLog { param($Message) }
        function Write-SuccessLog { param($Message) }
        function Update-StatusBackground { param($Message) }
        & $Body
    } $clearBody $fixtureRows $removalTrace
    $global:stateStore = $savedStore
    Assert-Equal $removalTrace.Count 2 'actual clear-list body delegates removal for every synthetic row'
    Assert-Equal ($removalTrace -join ',') 'CLEAR-A,CLEAR-B' 'actual clear-list body preserves the target snapshot'
}

''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
