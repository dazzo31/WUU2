#Requires -Version 5.1
<#
.DESCRIPTION
WUU2 GUI EDITION — the WPF projection adapter (Phase 1, T006).

THIS MODULE OWNS THE PURE ENGINE->VIEW PROJECTION. It is the home of the mapping, the colour-name ->
brush function, and the key-based selection helpers. It is deliberately HEADLESS on import: importing it
loads no WPF assembly, and only Get-WuuColorBrush creates a Brush, lazily.

OWNERSHIP (corrected - see docs/tasks/validation.md Phase 1 correction 2). The WPF surface is NOT split
with "all WPF lives in Wuu.Gui". That would contradict the retained architecture: Core's event wiring and
the credential/OU dialogs legitimately touch WPF on the owning (UI) dispatcher, and so does the XAML load.
What the uplift requires is the OTHER direction, which this module exists to enable:
  * ENGINE modules (Wuu.State, Wuu.Configuration, Wuu.Scheduler) must not load or access WPF at all.
  * INJECTED WORKER TWINS (the scriptblocks New-ComputerRunspace injects) must be headless - a worker
    runspace has no dispatcher and may not marshal to one.
This module reads engine rows and produces view rows; it never mutates engine state. Core drives it from
the UI thread (the JobTimer tick calls Update-WuuProjection).

WHAT IT REPLACED. Before this module the presentation state and the engine state were the SAME objects:
row objects were created as ListView items, workers were handed those items by reference, and they
mutated them in place under a dispatcher Invoke. There was no engine state to speak of - the ListView WAS
the database. As of T006.1 the ListView instead holds DETACHED view rows reconciled from the engine
store, so the two states are genuinely separate.

WHAT THIS MODULE IS
    engine row (plain data, worker-safe)  ->  view row (WPF-bound, UI-thread owned)

    ConvertTo-WuuViewRow      maps ONE engine row to ONE view row (pure; no WPF types)
    Sync-WuuViewCollection    reconciles a view collection against the engine rows, by KEY
    Get-WuuColorBrush         the ONLY function that creates a WPF Brush
    Get-WuuSelectedKeys       reads a ListView selection as engine keys (not item references)
    Select-WuuRowKeys         writes an engine key selection back onto a ListView

WHY THE MAPPING IS PURE AND THE BRUSH IS NOT
    ConvertTo-WuuViewRow deliberately returns a COLOUR NAME, not a Brush. Creating a brush needs
    PresentationCore loaded, which would make the mapping untestable in a headless process and would
    drag WPF into any test that merely wanted to check the mapping. Splitting the two means the
    projection rules are covered by ordinary tests, and exactly one small function needs a live
    dispatcher. Colour is also only ever mapped by NAME on the engine row (see Set-WuuComputerRowColor
    in Wuu.State), so the name is the natural interchange value.

WHY SELECTION IS BY KEY
    A view row is rebuilt whenever the engine row changes (Sync-WuuViewCollection replaces it), so an
    index or object reference into the view is invalidated by any update - and by every sort or filter.
    Selection therefore has to be expressed as a set of Computer keys, which survive all of it. This is
    what makes "the selection must survive sort/filter/refresh" true rather than aspirational.

WHAT THIS MODULE DELIBERATELY DOES NOT DO
    It does not create, own or mutate engine rows. It does not decide what an operation does. It reads
    engine rows and writes view rows; anything else belongs in Wuu.State (the funnel) or Wuu.Core (the
    action layer). A projection that can mutate the thing it projects is not a projection.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Colour NAME -> WPF brush. Kept as a name on the engine row so that workers can set presentation
# intent without touching WPF (a worker cannot create a Brush - it has no dispatcher and may not have
# PresentationCore loaded).
#
# LightGray/LightYellow are the colours the app already used for Error/Timeout rows; they are
# preserved exactly so this refactor is not also a visual change. The names 'Success'/'Default' map to
# "no special fill" rather than to a green/grey, because colour must never be the only signal (R07) -
# the status token carries the meaning.
$script:WuuColorBrushes = $null

function Get-WuuColorBrush {
    <#
    .SYNOPSIS
    Maps an engine row's colour NAME to a WPF Brush. The only WPF-creating function in the module.
    .DESCRIPTION
    Lazy: PresentationCore is loaded on first call, not at import, so importing this module in a
    headless context does not drag WPF in. Called on the UI thread only.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Default', 'Error', 'Timeout', 'Success')]
        [string]$Color
    )

    if ($null -eq $script:WuuColorBrushes) {
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        $script:WuuColorBrushes = @{
            Default = $null                                              # inherit the row style
            Error   = [System.Windows.Media.Brushes]::LightGray
            Timeout = [System.Windows.Media.Brushes]::LightYellow
            Success = $null                                              # no fill; the token carries it
        }
    }
    return $script:WuuColorBrushes[$Color]
}

function ConvertTo-WuuViewRow {
    <#
    .SYNOPSIS
    Projects ONE engine row into ONE view row. Pure - returns data, creates no WPF type.
    .DESCRIPTION
    The view row is a SNAPSHOT. It carries the engine fields the grid binds to plus the presentation
    fields (colour name, glyph token, formatted status). It intentionally does NOT carry Runspace,
    Pending, PendingOp or the operation identity: those are engine mechanics, and putting them on a
    bound object invites a handler to read them off the view instead of the engine.
    #>
    param(
        [Parameter(Mandatory)]$Row
    )

    # Deadline/heartbeat are optional on a row (present on the engine contract, but a row that has
    # never run an operation has no deadline). Read them defensively rather than assuming.
    $remaining = ''
    if ($Row.PSObject.Properties['TimeoutExpiresAt'] -and $Row.TimeoutExpiresAt) {
        try {
            $left = (Get-Date) - [datetime]$Row.TimeoutExpiresAt
            $remaining = if ($left.TotalSeconds -gt 0) { 'expired' } else { ('{0:N0}s left' -f [math]::Abs($left.TotalSeconds)) }
        } catch { $remaining = '' }
    }

    $heartbeatAge = ''
    if ($Row.PSObject.Properties['LastHeartbeat'] -and $Row.LastHeartbeat) {
        try { $heartbeatAge = ('{0:N0}s ago' -f ((Get-Date) - [datetime]$Row.LastHeartbeat).TotalSeconds) }
        catch { $heartbeatAge = '' }
    }

    [pscustomobject]@{
        # KEY. The stable identity of the row across sort, filter and refresh.
        Computer        = [string]$Row.Computer

        # Engine fields the grid binds to.
        Phase           = [string]$Row.Phase
        State           = [string]$Row.State
        Available       = [int]$Row.Available
        Downloaded      = [int]$Row.Downloaded
        InstallErrors   = [int]$Row.InstallErrors
        RebootRequired  = [bool]$Row.RebootRequired
        UpdatesStatus   = [string]$Row.UpdatesStatus
        Status          = [string]$Row.Status

        # Presentation-only projections.
        Color           = [string]$Row.Color
        ColorBrush      = $null                 # filled by the view layer, not here
        StatusToken     = Get-WuuStatusToken -Row $Row
        Operation       = [string]$Row.OpState
        Deadline        = $remaining
        HeartbeatAge    = $heartbeatAge
    }
}

function Get-WuuStatusToken {
    <#
    .SYNOPSIS
    A short text token for a row, so status is never conveyed by colour alone (R07).
    .DESCRIPTION
    Returns a bracketed token. UNKNOWN STATES ARE NOT REPORTED AS OK: a state this function does not
    recognise produces '[?]', not the '[OK]' default that hides exactly the case worth knowing about.

    PRECEDENCE MATTERS AND IS NOT OBVIOUS. A fresh row carries State='Queued' AND
    UpdatesStatus='Initializing' from Wuu.State's row contract, so a naive "prefer UpdatesStatus" rule
    reports [WAIT] for a row whose State is 'Error' - the terminal state is masked by a default. The
    settled/terminal states are therefore read from State FIRST and outrank any progress text; only
    then is UpdatesStatus consulted for the in-flight wording.
    #>
    param(
        [Parameter(Mandatory)]$Row
    )

    $state   = if ($Row.PSObject.Properties['State'] -and $Row.State) { [string]$Row.State } else { '' }
    $updates = if ($Row.PSObject.Properties['UpdatesStatus'] -and $Row.UpdatesStatus) { [string]$Row.UpdatesStatus } else { '' }

    # 1. TERMINAL STATES FIRST. These are the answers that must never be masked by 'Initializing'.
    switch -Regex ($state) {
        '^(Error)$'          { return '[ERR]' }
        '^(Timeout)$'        { return '[TMO]' }
        '^(Complete)$'       { return '[DONE]' }
        '^(RebootRequired)$' { return '[REBOOT]' }
    }

    # 2. In-flight wording, preferring the finer-grained UpdatesStatus when it has moved on from the
    #    row's initial value.
    $progress = if ($updates -and $updates -ne 'Initializing') { $updates } else { $state }
    switch -Regex ($progress) {
        '^(Installing|Downloading|Searching|Checking|Connecting|Verifying|Rebooting)$' { return '[...]' }
        '^(Queued|Initializing)$' { return '[WAIT]' }
        '^(UpdatesFound)$'   { return '[FOUND]' }
        '^(Connected)$'      { return '[ONLINE]' }
        '^(Error)$'          { return '[ERR]' }
        '^(Timeout)$'        { return '[TMO]' }
        '^(Complete)$'       { return '[DONE]' }
        '^(RebootRequired)$' { return '[REBOOT]' }
    }

    # 3. Nothing recognised - and that is NOT the same as OK.
    return '[?]'
}

function Sync-WuuViewCollection {
    <#
    .SYNOPSIS
    Reconciles a view collection against engine rows, by key. Returns the keys that were added.
    .DESCRIPTION
    ADD / REMOVE / UPDATE, matched on Computer. The collection is NOT rebuilt: rebuilding would
    discard selection and scroll position on every tick, and would make the ListView flicker on a
    fleet of any size.

    An unchanged row is left ALONE (its view object is reused) so the grid does not re-render it. A
    changed row has its fields written in place, so the object identity - and therefore the selection
    - is preserved.

    REVISION-GATED (T008.1). When the caller supplies -Revision, a snapshot OLDER than -AppliedRevision
    is REFUSED (returns $null and leaves the collection alone). Without this, a projection tick that was
    queued before a change could be applied after a newer tick had already rendered, resurrecting a
    removed row or a pre-reset display. A caller that has no revision (a one-off manual refresh) passes
    none and is applied unconditionally.

    Must be called on the UI thread: it touches an ObservableCollection.
    #>
    param(
        # AllowEmptyCollection is REQUIRED, not decorative: a Mandatory parameter rejects an empty
        # collection at binding time, so the very first reconcile of an empty view (the normal case
        # when the fleet is loaded) threw ParameterArgumentValidationErrorEmptyCollectionNotAllowed.
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ObjectModel.ObservableCollection[object]]$Collection,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EngineRows,
        # The revision this snapshot was taken at, and the revision already rendered. Omitted = apply.
        [Parameter(Mandatory=$false)][AllowNull()]$Revision = $null,
        [Parameter(Mandatory=$false)][AllowNull()]$AppliedRevision = $null
    )

    if ($null -ne $Revision -and $null -ne $AppliedRevision) {
        try {
            if ([int]$Revision -lt [int]$AppliedRevision) { return $null }   # superseded - do not apply
        } catch { }
    }

    $added = New-Object System.Collections.Generic.List[string]

    # Index the engine rows by key first, so the reconcile is O(n) rather than O(n^2).
    $byKey = @{}
    foreach ($r in $EngineRows) {
        if ($null -eq $r) { continue }
        $byKey[[string]$r.Computer] = $r
    }

    # 1. REMOVE view rows whose engine row is gone.
    for ($i = $Collection.Count - 1; $i -ge 0; $i--) {
        if (-not $byKey.ContainsKey([string]$Collection[$i].Computer)) {
            $Collection.RemoveAt($i)
        }
    }

    # 2. UPDATE rows already present, in place.
    $present = @{}
    for ($i = 0; $i -lt $Collection.Count; $i++) { $present[[string]$Collection[$i].Computer] = $i }

    foreach ($key in $byKey.Keys) {
        $engineRow = $byKey[$key]
        if ($present.ContainsKey($key)) {
            $view = $Collection[$present[$key]]
            $fresh = ConvertTo-WuuViewRow -Row $engineRow
            # Write field-by-field: reassigning the object would break the ListView's item identity.
            foreach ($p in $fresh.PSObject.Properties) {
                if ($p.Name -eq 'ColorBrush') { continue }   # owned by the WPF layer, not the reconciler
                $view.$($p.Name) = $p.Value
            }
        }
    }

    # 3. ADD rows for keys not yet shown.
    $missing = @($byKey.Keys | Where-Object { -not $present.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        foreach ($key in ($missing | Sort-Object)) {
            $Collection.Add((ConvertTo-WuuViewRow -Row $byKey[$key]))
            $added.Add($key) | Out-Null
        }
    }

    return $added.ToArray()
}

function Get-WuuSelectedKeys {
    <#
    .SYNOPSIS
    Reads a ListView selection as ENGINE KEYS, not as item references.
    .DESCRIPTION
    Callers act on the returned keys against the engine store. Holding the view objects instead is
    what made the old handlers act on stale rows after a refresh.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$ListView
    )

    if ($null -eq $ListView) { return @() }
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($ListView.SelectedItems)) {
        if ($null -eq $item) { continue }
        if ($item.PSObject.Properties['Computer']) { $keys.Add([string]$item.Computer) | Out-Null }
    }
    return $keys.ToArray()
}

function Select-WuuRowKeys {
    <#
    .SYNOPSIS
    Restores a selection (a set of keys) onto a ListView after a refresh.
    .DESCRIPTION
    The counterpart to Get-WuuSelectedKeys. Without it, a refresh that rebuilds or reorders items
    silently drops the operator's selection, and the next toolbar click acts on nothing.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$ListView,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Keys
    )

    if ($null -eq $ListView) { return 0 }
    $wanted = @{}
    foreach ($k in $Keys) { if ($k) { $wanted[$k] = $true } }

    $ListView.SelectedItems.Clear()
    $restored = 0
    foreach ($item in @($ListView.Items)) {
        if ($null -eq $item) { continue }
        if (-not $item.PSObject.Properties['Computer']) { continue }
        if ($wanted.ContainsKey([string]$item.Computer)) {
            $ListView.SelectedItems.Add($item) | Out-Null
            $restored++
        }
    }
    return $restored
}

Export-ModuleMember -Function @(
    'Get-WuuColorBrush',
    'ConvertTo-WuuViewRow',
    'Get-WuuStatusToken',
    'Sync-WuuViewCollection',
    'Get-WuuSelectedKeys',
    'Select-WuuRowKeys'
)
