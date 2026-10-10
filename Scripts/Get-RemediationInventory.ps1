#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputJson
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$records = New-Object System.Collections.Generic.List[object]
$files = New-Object System.Collections.Generic.List[object]

function Get-AstOwner {
    param([System.Management.Automation.Language.Ast]$Node)
    $owners = New-Object System.Collections.Generic.List[string]
    $ancestor = $Node.Parent
    while ($ancestor) {
        if ($ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $owners.Add('function:' + $ancestor.Name)
        }
        if ($ancestor -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            $container = $ancestor.Parent
            while ($container -and $container -isnot [System.Management.Automation.Language.AssignmentStatementAst] -and
                $container -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $container -isnot [System.Management.Automation.Language.ScriptBlockAst]) {
                $container = $container.Parent
            }
            if ($container -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                $owners.Add('block:' + $container.Left.Extent.Text)
            } elseif ($container -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                $owners.Add('injection:' + $container.Extent.StartLineNumber)
            } else {
                $owners.Add('block@' + $ancestor.Extent.StartLineNumber)
            }
        }
        $ancestor = $ancestor.Parent
    }
    return ($owners.ToArray() -join ' <- ')
}

foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -Filter '*.psm1' -File | Sort-Object Name) {
    $tokens = $null
    $parseErrors = $null
    $syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($file.Name + ': ' + ($parseErrors.Message -join '; ')) }
    $relativePath = 'src/' + $file.Name
    $files.Add([pscustomobject]@{ Path = $relativePath; Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash })
    foreach ($node in $syntaxTree.FindAll({ param($candidate)
        $candidate -is [System.Management.Automation.Language.AssignmentStatementAst] -or
        $candidate -is [System.Management.Automation.Language.UnaryExpressionAst] -or
        $candidate -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or
        $candidate -is [System.Management.Automation.Language.CommandAst]
    }, $true)) {
        $kind = ''
        $target = ''
        $member = ''
        if ($node -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            $target = $node.Left.Extent.Text
            if ($node.Left -is [System.Management.Automation.Language.MemberExpressionAst]) {
                $kind = 'MemberWrite'
                $member = $node.Left.Member.Extent.Text
            } elseif ($node.Left -is [System.Management.Automation.Language.IndexExpressionAst]) {
                $kind = 'IndexWrite'
            } elseif ($node.Right.Find({ param($candidate)
                $candidate -is [System.Management.Automation.Language.HashtableAst]
            }, $true)) {
                $kind = 'PropertyBagOrContext'
            }
        } elseif ($node -is [System.Management.Automation.Language.UnaryExpressionAst]) {
            if ($node.TokenKind.ToString() -match 'PlusPlus|MinusMinus') {
                $kind = 'Increment'
                $target = $node.Child.Extent.Text
            }
        } elseif ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
            $member = $node.Member.Extent.Text
            if ($member -match '^(BeginInvoke|SetVariable|Add|Remove|Clear|Touch|SetStatus|Create)$') {
                $kind = 'InvocationBoundary'
                $target = $node.Expression.Extent.Text
            }
        } else {
            $commandName = $node.GetCommandName()
            if (-not $commandName -or $commandName -match '^(Set-|Update-|Add-Wuu|Remove-Wuu|Start-UpdateCheckJob|New-ComputerRunspace|Invoke-WuuRemoteTask|Invoke-AutoRecovery|Restart-Computer)') {
                $kind = 'CommandBoundary'
                $target = $commandName
                if (-not $target) { $target = $node.CommandElements[0].Extent.Text }
            }
        }
        if ($kind) {
            $records.Add([pscustomobject]@{
                Path = $relativePath
                Line = $node.Extent.StartLineNumber
                Kind = $kind
                OwnerChain = Get-AstOwner -Node $node
                Target = $target
                Member = $member
                Source = $node.Extent.Text
                Disposition = 'NeedsReview'
            })
        }
    }
}

$report = [pscustomobject]@{
    Schema = 'wuu.remediation.inventory.v1'
    CapturedAt = (Get-Date).ToString('o')
    PowerShell = $PSVersionTable.PSVersion.ToString()
    TargetHead = (git -C $repoRoot rev-parse HEAD)
    TargetStatus = @(git -C $repoRoot status --short)
    DonorHead = (git -C (Join-Path (Split-Path $repoRoot -Parent) 'WUU2-CLI') rev-parse HEAD)
    Files = $files.ToArray()
    Records = $records.ToArray()
    Limitation = 'Syntactic candidates, not alias/data-flow proof. Every candidate requires semantic disposition.'
}
if ($OutputJson) {
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
}
$report