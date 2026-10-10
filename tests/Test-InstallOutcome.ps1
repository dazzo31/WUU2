#Requires -Version 5.1
<#
.SYNOPSIS T010 - the REAL $InstallUpdates payload maps a remote install result onto the row correctly.
.DESCRIPTION
WHY THIS SUITE EXISTS. The install result carries independent facts - the ERROR count and RebootRequired -
and T010 requires them preserved independently, driven by the REAL result-handling path. That mapping is a
few lines inside the $InstallUpdates payload: a classifier test would re-implement it and prove only that
the test agrees with itself.

HOW IT IS DRIVEN. Each case runs the REAL payload in a CHILD PowerShell process with the remote seam
(InvokeRemoteTaskScript) MOCKED. Two reasons it is a child process, not an in-process runspace:
  1. The payload's error path calls `exit` - in-process that would abort the suite.
  2. A faithful envelope runs the dispatcher action on the UI thread (a SEPARATE thread), so the worker
     runspace's engine stays free. A stub that invokes the action inline on the worker's OWN (busy)
     pipeline thread DEADLOCKS the moment the action calls a module function. In the child the payload
     runs in the MAIN session (one runspace), where nested inline invocation is safe and the module
     writer resolves - exactly like the real UI thread.
The child prints ROW=<State>|<InstallErrors>|<RebootRequired>|<UpdatesStatus>|OUTCOME=<Get-WuuTargetOutcome>,
which the parent asserts.

Run: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-InstallOutcome.ps1
#>

$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$ErrorActionPreference = 'Stop'

$script:pass = 0
$script:fail = 0
function Assert-True($Condition, $Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "FAIL: $Name" -ForegroundColor Red; $script:fail++ }
}

# --- The child runner: real payload, mocked remote seam, main-session envelope ------------------------
$runner = Join-Path $env:TEMP ("WuuInstallOutcome_{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
$runnerBody = @'
param([string]$Repo, [string]$Case, [string]$ResultFile)
$ErrorActionPreference = 'Stop'
Set-Location $Repo

# The payload calls `exit` on its error path, and an `exit` SKIPS the rest of the script but DOES run a
# `finally` block. So the row is captured in `finally` - the only place guaranteed to run whether the
# payload returned normally or exited.
$row = $null
$status = 'ok'
function Write-Result {
    $outcome = ''
    if ($null -ne $row) { try { $outcome = Get-WuuTargetOutcome -Row $row } catch { $outcome = '' } }
    $line = if ($null -ne $row) {
        "STATUS={0}`nROW={1}|{2}|{3}|{4}|OUTCOME={5}" -f $status, $row.State, $row.InstallErrors, $row.RebootRequired, $row.UpdatesStatus, $outcome
    } else { "STATUS=$status`nROW=" }
    Set-Content -Path $ResultFile -Value $line -Force
}

try {
    Import-Module (Join-Path $Repo 'src\Wuu.Core.psm1') -Force
    Import-WuuModules -WuuRoot $Repo | Out-Null

    # Extract the REAL $InstallUpdates payload from Core's AST (braces stripped, or it evaluates to a
    # nested scriptblock literal and runs nothing).
    $src = [System.IO.File]::ReadAllText((Join-Path $Repo 'src\Wuu.Core.psm1'))
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)
    $assign = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq 'InstallUpdates'
    }, $true) | Select-Object -First 1
    $sb = $assign.Right.Expression
    $text = $sb.ScriptBlock.Extent.Text.Trim()
    $payload = [scriptblock]::Create($text.Substring(1, $text.Length - 2))

    # Scripted remote result per case.
    $remote = switch ($Case) {
        'errors' { @{ Success = $true; Count = 2; Total = 3; RebootRequired = $false; ExitCode = 2; Error = $null } }
        'reboot' { @{ Success = $true; Count = 0; Total = 2; RebootRequired = $true;  ExitCode = 0; Error = $null } }
        'fail'   { @{ Success = $false; Count = 0; Total = 0; RebootRequired = $false; ExitCode = 9999; Error = 'simulated install failure' } }
    }
    $global:InvokeRemoteTaskScript = { param($ComputerName, $ScriptPath, $Operation, $Credential, $ProgressCallback) $global:__WuuMockResult }
    $global:__WuuMockResult = $remote
    # The payload revalidates ownership at the effect boundary (G6) via an INJECTED twin. My child
    # bypasses New-ComputerRunspace, so inject the equivalent permissive stub (Authorized=$true) - without
    # it `& $null` would throw and the payload's catch would paint Error before it ever mapped the result.
    $global:TestEffectAuthorizedScript = { param($Computer) @{ Authorized = $true; Reason = '' } }

    # Main-session context. The envelope runs the dispatcher action INLINE (one runspace, like the UI
    # thread), and the payload takes the module-writer branch (`Set-WuuComputerFencedFields`) - so no
    # injected twin is needed and the writer resolves.
    $store = New-WuuStateStore
    $global:stateStore = $store
    $items = New-Object PSObject
    foreach ($m in @('EditItem', 'CommitEdit', 'Refresh')) { Add-Member -InputObject $items -MemberType ScriptMethod -Name $m -Value { param($i) } -Force }
    $dispatcher = New-Object PSObject
    Add-Member -InputObject $dispatcher -MemberType ScriptMethod -Name Invoke -Value { param($p, $a) if ($a -is [System.Delegate]) { $a.Invoke() } else { & $a } } -Force
    $global:uiHash = @{ Listview = [pscustomobject]@{ Items = $items; Dispatcher = $dispatcher } }
    $global:updatesHash = @{}
    $global:path = $Repo
    $global:UseCustomCredentials = $false
    $global:CustomCredentials = $null
    $global:ConfigPaths = @{ DownloadScript = 'unused'; InstallScript = 'unused' }
    $global:WuuOperationId = 'op-install'
    $global:PerformanceThreshold = @{ CPUPercent = 80; MemoryMB = 1024; NetworkLatencyMs = 1000 }
    # A row with NO injected fenced-writer scriptblock -> the payload uses the module writer.
    $row = New-WuuComputerRow -Computer 'inst'
    Add-WuuComputerRow -Store $store -Row $row | Out-Null
    $null = Update-WuuOperationState -Row $row -OperationIdNew 'op-install' -OpState 'Running' -State 'Downloading'

    # Drive the payload. It may call `exit` on the error path - that ends THIS child via the finally.
    & $payload $row
} catch {
    $status = "error: $($_.Exception.Message)"
} finally {
    Write-Result
}
'@
Set-Content -Path $runner -Value $runnerBody -Encoding UTF8

function Invoke-InstallCase([string]$Case) {
    $out = Join-Path $env:TEMP ("wuio_{0}.out" -f ([guid]::NewGuid().ToString('N')))
    $err = Join-Path $env:TEMP ("wuio_{0}.err" -f ([guid]::NewGuid().ToString('N')))
    $result = Join-Path $env:TEMP ("wuio_{0}.res" -f ([guid]::NewGuid().ToString('N')))
    $p = Start-Process powershell.exe -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $runner, $repo, $Case, $result -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
    if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { } ; throw "install case '$Case' timed out" }
    # The ROW line is written to its OWN file (stdout/Write-Host capture across a child process is not
    # reliable), so read that - not the redirected stdout.
    $text = ''
    try { $text = Get-Content $result -Raw -ErrorAction SilentlyContinue } catch { }
    $errText = ''
    try { $errText = Get-Content $err -Raw -ErrorAction SilentlyContinue } catch { }
    Remove-Item $out, $err, $result -Force -ErrorAction SilentlyContinue
    # Parse ROW=State|InstallErrors|RebootRequired|UpdatesStatus|OUTCOME=X
    if ($text -match 'ROW=([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|OUTCOME=([^\r\n]*)') {
        return [pscustomobject]@{ State = $matches[1]; InstallErrors = $matches[2]; RebootRequired = $matches[3]; UpdatesStatus = $matches[4]; Outcome = $matches[5].Trim() }
    }
    if ($errText) { Write-Host ("  child stderr for '{0}': {1}" -f $Case, ($errText -replace '\s+', ' ')) -ForegroundColor DarkYellow }
    return $null
}

''; '=== install outcome mapping (real payload, mocked remote seam) ==='

# 1. SUCCESS WITH ERRORS. Two updates failed (Count=2): InstallErrors=2, and the target is FAILED even
#    though the operation settled to Complete - errors are not masked by a settled state.
$r1 = Invoke-InstallCase 'errors'
Assert-True ($null -ne $r1) 'the errors case produced a row'
if ($r1) {
    Assert-True ($r1.InstallErrors -eq '2') 'Count maps to InstallErrors (the failure count is preserved)'
    Assert-True ($r1.RebootRequired -eq 'False' -or $r1.RebootRequired -eq '$false') 'RebootRequired=false is preserved'
    Assert-True ($r1.State -eq 'Complete') 'a no-reboot install settles to Complete'
    Assert-True ($r1.Outcome -eq 'Failed') 'InstallErrors>0 yields Failed even though State=Complete (errors are NOT masked)'
}

# 2. SUCCESS NEEDING A REBOOT. Zero errors, RebootRequired -> State=RebootRequired, flag set, and the
#    error count is INDEPENDENT (0 here, 2 above).
$r2 = Invoke-InstallCase 'reboot'
Assert-True ($null -ne $r2) 'the reboot case produced a row'
if ($r2) {
    Assert-True ($r2.InstallErrors -eq '0') 'a clean install records zero errors (independent of the reboot flag)'
    Assert-True ($r2.RebootRequired -eq 'True') 'RebootRequired=true is preserved independently of the error count'
    Assert-True ($r2.State -eq 'RebootRequired') 'a reboot-required install settles to RebootRequired'
}

# 3. REMOTE FAILURE. Success=$false -> the payload throws, its catch paints Error (not a stale success).
$r3 = Invoke-InstallCase 'fail'
Assert-True ($null -ne $r3) 'the fail case produced a row'
if ($r3) {
    Assert-True ($r3.State -eq 'Error') 'a failed remote install settles the row to Error'
    Assert-True ($r3.UpdatesStatus -eq 'Error') 'and marks UpdatesStatus=Error so the failure is visible'
    Assert-True ($r3.Outcome -eq 'Failed') 'a failed install classifies as Failed'
}

Remove-Item $runner -Force -ErrorAction SilentlyContinue

''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
