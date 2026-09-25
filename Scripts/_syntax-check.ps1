param([Parameter(Mandatory=$true)][string]$Path)
$errors = $null
[void][System.Management.Automation.PSParser]::Tokenize((Get-Content $Path -Raw), [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    Write-Output "ERRORS in $Path :"
    $errors | ForEach-Object { Write-Output $_.Message }
    exit 1
} else {
    Write-Output "$Path OK"
    exit 0
}
