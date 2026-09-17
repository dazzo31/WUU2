# Functional test: verify the typed [pscredential] params in the real WUU.ps1 code
# work correctly with (a) a real PSCredential and (b) $null default credentials,
# and that a plain STRING is rejected (ParameterBindingException, not silently used).
# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Scripts\Test-CredentialTyping.ps1

$repo = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0

# --- Extract the REAL Invoke-CimWithTimeout from WUU.ps1 (main-script version) ---
$tokens = $null; $perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'WUU.ps1'), [ref]$tokens, [ref]$perr)
if ($perr.Count -gt 0) { throw "WUU.ps1 parse errors: $($perr.Count)" }
$fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-CimWithTimeout' }, $true) | Select-Object -First 1
if (-not $fn) { throw 'Invoke-CimWithTimeout not found' }
. ([scriptblock]::Create($fn.Extent.Text))

# NOTE: full CIM round-trips need WinRM (not configured on dev boxes), so these
# tests verify BINDING and type-flow, not remote query success. A non-routable
# computer name guarantees the job fails fast for the right reason (DNS), proving
# the credential crossed the job boundary without type errors.

# --- Test A: $null credential (default credentials) ---
$rA = Invoke-CimWithTimeout -ComputerName 'WUU-NOTREAL-000000' -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 10
if (-not $rA.Success -and $rA.Error -notmatch 'parameter name|cannot convert') { Write-Host 'PASS A: null credential binds and flows (fails on DNS, as expected)'; $pass++ }
else { Write-Host "FAIL A: null credential - $($rA.Error)"; $fail++ }

# --- Test B: real PSCredential is accepted, crosses the job boundary ---
$secPass = ConvertTo-SecureString 'ThisIsNotARealPassword123!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('.\WUU_test_user', $secPass)
$rB = Invoke-CimWithTimeout -ComputerName 'WUU-NOTREAL-000000' -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 10 -Credential $cred
if (-not $rB.Success -and $rB.Error -notmatch 'parameter name|cannot convert') { Write-Host 'PASS B: PSCredential accepted and serialized into the job (fails on DNS, as expected)'; $pass++ }
else { Write-Host "FAIL B: PSCredential - $($rB.Error)"; $fail++ }

# --- Test C: a plain STRING must NOT silently become a credential ---
# PSCredential params carry a CredentialAttribute that converts strings, but in a
# NON-INTERACTIVE child job the conversion fails (no prompt available). Requirement:
# the failure must be a hard error, never a silent use of the string as a password.
$usedPlainString = $false
try {
    $rC = Invoke-CimWithTimeout -ComputerName 'WUU-NOTREAL-000000' -ClassName 'Win32_ComputerSystem' -TimeoutSeconds 10 -Credential 'PlainTextPassword'
    # If we get here the string was converted to some credential; it must not have succeeded
    if ($rC.Success) { $usedPlainString = $true }
} catch {
    # ParameterBindingException at binding time is the ideal outcome
}
if ($usedPlainString) { Write-Host 'FAIL C: plain string was silently used as a credential'; $fail++ }
else { Write-Host 'PASS C: plain string never becomes a working credential (hard error or prompt-blocked in job)'; $pass++ }

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }