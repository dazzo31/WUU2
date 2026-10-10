#Requires -Version 5.1
<#
.SYNOPSIS
Ratchet guard: no NEW unfenced row write may appear in an injected payload (remediation T007.11).

.DESCRIPTION
WHY THIS EXISTS. The payloads hand-write display state (`$computer.State = 'Installing'`) straight onto
the row, bypassing the operation-identity fence. That is the defect being converted group by group.
Without a guard, the very next feature that reaches for `$computer.Status = ...` inside a payload
silently reopens it - which is exactly how ~79 of them accumulated.

HOW IT WORKS. The ceiling below is per PAYLOAD, taken from the G1 inventory. It FAILS when any payload
exceeds its ceiling (a new unfenced write) or when a payload appears that is not listed (a new payload
must be classified deliberately, not inherited). The ceiling is LOWERED as each payload is converted;
a lowering is the proof the conversion removed writes rather than merely adding a fence around them.

NOT PROVABLE HERE: this counts DIRECT assignments. A write laundered through a local alias, a dynamic
member name, or a string-created scriptblock is not matched - those need the manual review recorded in
docs/tasks/payload-writer-inventory-20261009.json. This guard is a ratchet, not a completeness proof.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-PayloadWriterGuard.ps1
Exit code 0 = no regression, 1 = a payload grew or an unclassified payload appeared.
#>
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$script:pass = 0
$script:fail = 0
function Assert-True($Condition, $Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "FAIL: $Name" -ForegroundColor Red; $script:fail++ }
}

# Baseline ceilings, per payload, from the G1 AST inventory (2026-10-09). Lower a number ONLY in the
# same change that converts that payload; never raise one to make the suite pass.
$ceiling = @{
    # All payloads are now fully fenced: 0 direct row writes. The queue fields (Pending/PendingOp) go
    # through the injected precedence-respecting SetPendingOpScript, and retry bookkeeping through the
    # fenced multi-field writer, so nothing bypasses a policy or a fence.
    '$DownloadUpdates'                   = 0
    '$DownloadUpdates > $onProgress'     = 0
    '$GetUpdates'                        = 0
    '$InstallUpdates'                    = 0
    '$InstallUpdates > $onProgress'      = 0
    '$RemoveOfflineComputer'             = 0
    '$RestartComputer'                   = 0
    '$WUServiceAction'                   = 0
}

# Non-payload owners are out of the conversion scope but listed, so a change there is visible rather
# than silent. They are the fence implementations, the scheduler, and UI handlers - not payload writes.
$outOfScope = @(
    'function:New-ComputerRunspace',
    'function:Start-PendingUpdateCheck',
    'function:Start-WuuApplication',
    'function:Set-ComputerState',
    'function:Set-ComputerTimeout',
    '$eventShowUpdateHistory'
)

$rowFields = @(
    'State', 'Status', 'UpdatesStatus', 'Color', 'Available', 'Downloaded', 'InstallErrors',
    'RebootRequired', 'RetryCount', 'RetryAt', 'Pending', 'PendingOp', 'TimeoutExpiresAt',
    'TimeoutSource', 'ConnectivityFailures', 'LastConnectivityError'
)

function Get-ScriptBlockExpression {
    param($Right)
    if ($Right -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $Right }
    if ($Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
        $Right.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $Right.Expression }
    return $null
}

function Get-PayloadOwnerKey {
    param($Node)
    # Collect the payload chain (outermost first), matching the G1 inventory's key format so the two
    # documents agree: '$DownloadUpdates > $onProgress'.
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
    # A module-scope owner (function:...) is not a payload write; only report the payload tail.
    $lastFunction = -1
    for ($i = 0; $i -lt $chain.Count; $i++) { if ($chain[$i] -like 'function:*') { $lastFunction = $i } }
    $payloadChain = @($chain | Select-Object -Skip ($lastFunction + 1))
    if ($payloadChain.Count -eq 0) { return $chain[$chain.Count - 1] }
    return ($payloadChain -join ' > ')
}

$counts = @{}
foreach ($name in @('Wuu.Core.psm1', 'Wuu.WindowsUpdate.psm1')) {
    $path = Join-Path $RepoRoot (Join-Path 'src' $name)
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $tokens = $null; $parseErrors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($name + ': ' + ($parseErrors.Message -join '; ')) }
    foreach ($assign in $tree.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -or
        $n -is [System.Management.Automation.Language.UnaryExpressionAst]
    }, $true)) {
        $field = ''; $target = ''
        if ($assign -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            if ($assign.Left -isnot [System.Management.Automation.Language.MemberExpressionAst]) { continue }
            $target = $assign.Left.Expression.Extent.Text; $field = $assign.Left.Member.Extent.Text
        } else {
            if ($assign.TokenKind.ToString() -notmatch 'PlusPlus|MinusMinus') { continue }
            if ($assign.Child -isnot [System.Management.Automation.Language.MemberExpressionAst]) { continue }
            $target = $assign.Child.Expression.Extent.Text; $field = $assign.Child.Member.Extent.Text
        }
        if ($field -notin $rowFields) { continue }
        if ($target -notmatch '^\$(Computer|computer|Row|row|item|Item)$') { continue }
        $owner = Get-PayloadOwnerKey -Node $assign
        if (-not $owner) { continue }
        if (-not $counts.ContainsKey($owner)) { $counts[$owner] = 0 }
        $counts[$owner] = [int]$counts[$owner] + 1
    }
}

'=== payload writer ratchet (T007.11) ==='
foreach ($payloadName in ($ceiling.Keys | Sort-Object)) {
    $actual = 0
    if ($counts.ContainsKey($payloadName)) { $actual = [int]$counts[$payloadName] }
    Assert-True ($actual -le $ceiling[$payloadName]) ("{0}: {1} direct write(s) - ceiling {2}" -f $payloadName, $actual, $ceiling[$payloadName])
}

Write-Host ''
Write-Host '=== unclassified payloads (must be classified deliberately) ==='
$known = @($ceiling.Keys) + $outOfScope
$unclassified = @($counts.Keys | Where-Object { $_ -notin $known } | Sort-Object)
Assert-True ($unclassified.Count -eq 0) ("no unclassified payload/owner writes (found: {0})" -f (($unclassified -join ', ') -replace '^$', 'none'))

# The twins and the scheduler legitimately write rows without an envelope; assert they are still the
# ones doing it, so a migration that quietly moves writes there is visible.
Assert-True ($counts.ContainsKey('function:Start-PendingUpdateCheck')) 'the scheduler still owns its direct row writes (classified)'

[pscustomobject]@{ Schema = 'wuu.payloadwriter.guard.v1'; CapturedAt = (Get-Date).ToString('o'); Counts = $counts } | ConvertTo-Json -Depth 6 | Write-Host

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
