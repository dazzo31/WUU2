#Requires -Version 5.1
<#
.SYNOPSIS
Decision-ready inventory of every PAYLOAD-owned row write (remediation gate G1).

.DESCRIPTION
The broad candidate scan (Get-RemediationInventory.ps1) lists every assignment in every module and
leaves 935 records as "NeedsReview" - it cannot answer the only question the conversion needs:
"which ROW fields does each injected payload write, and is the write inside a Dispatcher envelope?"

This script answers exactly that, using the AST:
  * a PAYLOAD is a top-level `$Name = { ... }` scriptblock assignment (the things handed to AddScript),
    plus any nested scriptblock it contains (the $onProgress callbacks);
  * a ROW WRITE is a property assignment on the payload's row parameter ($Computer/$computer/$Row);
  * ENVELOPE means the write is nested inside a `...Dispatcher.Invoke({...})` / BeginInvoke action - the
    thing the conversion must KEEP;
  * KIND distinguishes `=` from `+=`/`++` (a compound write needs the read-modify-write in the same
    gated call, not a simple set).

Every candidate still needs a SEMANTIC disposition (route / exempt / construction); this script makes
the inventory complete and unambiguous, it does not make the decision.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Get-PayloadWriterInventory.ps1 -OutputJson <path>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$OutputJson
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

# The row contract fields the conversion must classify. Keep in step with New-WuuComputerRow.
$rowFields = @(
    'State', 'Status', 'UpdatesStatus', 'Color',
    'Available', 'Downloaded', 'InstallErrors', 'RebootRequired',
    'RetryCount', 'RetryAt', 'Pending', 'PendingOp',
    'TimeoutExpiresAt', 'TimeoutSource', 'ConnectivityFailures', 'LastConnectivityError'
)

function Get-ScriptBlockExpression {
    # A payload is written `$GetUpdates = { ... }`, which parses the right side as a
    # CommandExpressionAst WRAPPING a ScriptBlockExpressionAst (not a bare ScriptBlockExpressionAst).
    # Unwrap it; return $null for anything that is not a scriptblock-valued assignment.
    param([System.Management.Automation.Language.Ast]$Right)
    if ($Right -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $Right }
    if ($Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
        $Right.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $Right.Expression }
    return $null
}

function Get-PayloadOwnerPath {
    param([System.Management.Automation.Language.Ast]$Node)
    # Build the payload/helper ownership chain from the OUTERMOST payload inward, so a nested
    # $onProgress callback still reports the payload it belongs to.
    $chain = New-Object System.Collections.Generic.List[string]
    $ancestor = $Node.Parent
    while ($ancestor) {
        if ($ancestor -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $ancestor.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            (Get-ScriptBlockExpression -Right $ancestor.Right)) {
            $chain.Insert(0, $ancestor.Left.Extent.Text)
        } elseif ($ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $chain.Insert(0, 'function:' + $ancestor.Name)
        }
        $ancestor = $ancestor.Parent
    }
    if ($chain.Count -eq 0) { return $null }
    return ($chain.ToArray() -join ' > ')
}

function Test-DispatcherEnvelope {
    param([System.Management.Automation.Language.Ast]$Node)
    $ancestor = $Node.Parent
    while ($ancestor) {
        if ($ancestor -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
            $member = $ancestor.Member.Extent.Text
            if ($member -eq 'Invoke' -or $member -eq 'BeginInvoke') {
                # Confirm the receiver really is a Dispatcher, not some other Invoke().
                if ($ancestor.Expression.Extent.Text -match 'Dispatcher') { return $true }
            }
        }
        $ancestor = $ancestor.Parent
    }
    return $false
}

$records = New-Object System.Collections.Generic.List[object]
$files = New-Object System.Collections.Generic.List[object]

foreach ($name in @('Wuu.Core.psm1', 'Wuu.WindowsUpdate.psm1')) {
    $path = Join-Path $repoRoot (Join-Path 'src' $name)
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $relative = 'src/' + $name
    $files.Add([pscustomobject]@{ Path = $relative; Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash })

    $tokens = $null
    $parseErrors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($relative + ': ' + ($parseErrors.Message -join '; ')) }

    foreach ($assign in $tree.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -or
        $n -is [System.Management.Automation.Language.UnaryExpressionAst]
    }, $true)) {
        $field = ''
        $target = ''
        $kind = ''
        if ($assign -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            if ($assign.Left -isnot [System.Management.Automation.Language.MemberExpressionAst]) { continue }
            $target = $assign.Left.Expression.Extent.Text
            $field = $assign.Left.Member.Extent.Text
            $kind = if ($assign.Operator -eq 'Equals') { 'Set' } else { 'Compound' }
        } else {
            if ($assign.TokenKind.ToString() -notmatch 'PlusPlus|MinusMinus') { continue }
            if ($assign.Child -isnot [System.Management.Automation.Language.MemberExpressionAst]) { continue }
            $target = $assign.Child.Expression.Extent.Text
            $field = $assign.Child.Member.Extent.Text
            $kind = 'Increment'
        }
        if ($field -notin $rowFields) { continue }

        # The write must be on the payload's ROW parameter (or a local alias) - not a hashtable key
        # or an unrelated object's property that happens to share a field name.
        $isRowTarget = ($target -match '^\$(Computer|computer|Row|row|item|Item)$')
        if (-not $isRowTarget) { continue }

        $owner = Get-PayloadOwnerPath -Node $assign
        if (-not $owner) { continue }   # module-scope helper, not a payload write

        $records.Add([pscustomobject]@{
            Path       = $relative
            Line       = $assign.Extent.StartLineNumber
            Payload    = $owner
            Field      = $field
            Kind       = $kind
            Envelope   = (Test-DispatcherEnvelope -Node $assign)
            Target     = $target
            Source     = ($assign.Extent.Text -replace '\s+', ' ')
            Disposition = 'NeedsDecision'
        })
    }
}

# Summary by payload, so the conversion can be sequenced group by group.
$byPayload = $records | Group-Object Payload | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{
        Payload     = $_.Name
        Writes      = $_.Count
        Enveloped   = @($_.Group | Where-Object { $_.Envelope }).Count
        Unguarded   = @($_.Group | Where-Object { -not $_.Envelope }).Count
        Fields      = (($_.Group | Select-Object -ExpandProperty Field -Unique | Sort-Object) -join ',')
    }
}

$report = [pscustomobject]@{
    Schema     = 'wuu.payloadwriter.inventory.v1'
    CapturedAt = (Get-Date).ToString('o')
    PowerShell = $PSVersionTable.PSVersion.ToString()
    TargetHead = (git -C $repoRoot rev-parse HEAD)
    Files      = $files.ToArray()
    Summary    = $byPayload
    TotalRowWrites = $records.Count
    Records    = $records.ToArray()
    Limitation = 'AST-attributed payload-owned row writes. Alias/dynamic-member writes and nested string-created scriptblocks still require manual review.'
}

if ($OutputJson) {
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
}

$report.Summary | Format-Table -AutoSize
Write-Output ("TOTAL PAYLOAD ROW WRITES: {0}" -f $records.Count)
$report
