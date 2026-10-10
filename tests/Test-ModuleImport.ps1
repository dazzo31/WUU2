#Requires -Version 5.1
<#
.SYNOPSIS Import smoke test for the split WUU2 modules.
.DESCRIPTION Imports each src module in dependency order and reports exported commands.
Run from repo root:  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tests\Test-ModuleImport.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

try {
    Get-ChildItem (Join-Path $root 'src\*.psm1') | Sort-Object Name | ForEach-Object {
        Import-Module $_.FullName -ErrorAction Stop
        Write-Host ("IMPORTED  {0}  ({1} exports)" -f $_.BaseName, (Get-Module $_.BaseName).ExportedCommands.Keys.Count)
    }
    Write-Host 'ALL MODULES IMPORT OK' -ForegroundColor Green

    # Verify the key commands the entry point depends on
    $required = @('Start-WuuApplication','New-WuuErrorSuggestions','Write-DebugLog','Invoke-CimWithTimeout','Show-CredentialConfigDialog','New-ComputerRunspace','Initialize-WuuConfiguration')
    foreach ($c in $required) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { Write-Host ("OK  {0}  ({1})" -f $c, $cmd.ModuleName) }
        else { Write-Host ("MISSING  {0}" -f $c) -ForegroundColor Red; throw "Missing required command: $c" }
    }

    # Verify D7: target-owned version constant is initialized and truthful
    Initialize-WuuConfiguration -WuuRoot $root
    if ([string]::IsNullOrWhiteSpace($global:WuuVersion)) {
        throw "D7 assertion failed: `$global:WuuVersion is empty or not set"
    }
    if ($global:WuuVersion -like '*-cli*') {
        throw "D7 assertion failed: `$global:WuuVersion ('$global:WuuVersion') carries CLI suffix; target must keep its own version"
    }
    Write-Host ("OK  `$global:WuuVersion = '{0}' (source: {1}) (D7)" -f $global:WuuVersion, $global:WuuVersionSource) -ForegroundColor Green
} catch {
    Write-Host ("IMPORT FAILED: " + $_.Exception.Message) -ForegroundColor Red
    throw
}