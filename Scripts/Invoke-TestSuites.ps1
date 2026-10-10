#Requires -Version 5.1
<#
.SYNOPSIS
GUI-appropriate test-suite runner for WUU2 (Windows PowerShell 5.1, STA).

.DESCRIPTION
Runs each tests\Test-*.ps1 suite in its OWN child process under Windows PowerShell 5.1
STA, with a per-suite timeout, and classifies the outcome:

    PASS     child exited 0
    FAIL     child exited non-zero without a SKIP marker
    SKIP     child exited non-zero AND printed a line beginning "SKIP:" (environmental
             precondition missing, e.g. elevation required)
    TIMEOUT  child exceeded -TimeoutSec and was killed

WHY A CHILD PROCESS PER SUITE. The suites mutate module import state, global variables and
WPF dispatcher state, and some of them can hang. A per-suite child with a hard timeout is the
only way to get an independent verdict and a bounded wall-clock cost. The child's exit code is
read through System.Diagnostics.Process (Start-Process and cmd ERRORLEVEL both proved
unreliable for this under this terminal - see docs\tasks\phase-0-evidence.md).

WHY THIS IS NOT THE CLI RUNNER. The CLI runner is a line-oriented, console-only edition; WUU2
ships WPF suites (column resize / drag) that the CLI excludes outright. Those suites are NOT
excluded here and are NOT set aside: they were retargeted to the current layout (root WUU.xaml ->
ui\MainWindow.xaml, root WUU.ps1 -> src\Wuu.Core.psm1) and now run as real coverage. There is no
STALE category - see the note above $script:StaleSuites' former position.

.PARAMETER SuiteDirectory
Directory holding Test-*.ps1 suites. Default: <repo>\tests. Point this at a disposable
directory to prove the runner can report FAIL without touching the real suites.

.PARAMETER TimeoutSec
Per-suite wall-clock limit in seconds. Default 120.

.PARAMETER Include
Optional wildcard filter on suite base name (e.g. 'Test-*Remote*').

.PARAMETER Exclude
Optional wildcard filter of suites to omit.

.PARAMETER OutputJson
Optional path to also write machine-readable results.

.EXAMPLE
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Invoke-TestSuites.ps1

.OUTPUTS
A per-suite table plus aggregate counts. Exit code 0 only when every suite PASSed (or SKIPped);
any FAIL or TIMEOUT yields exit 1. A SKIP is reported and never counted as coverage.
#>
[CmdletBinding()]
param(
    [string]$SuiteDirectory,
    [int]$TimeoutSec = 120,
    [string[]]$Include,
    [string[]]$Exclude,
    [string]$OutputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $SuiteDirectory) { $SuiteDirectory = Join-Path $repoRoot 'tests' }
if (-not (Test-Path -LiteralPath $SuiteDirectory)) {
    throw "Suite directory not found: $SuiteDirectory"
}

# NO STALE LIST. Every suite in tests\ now runs on the current module/layout, so there is no
# "reported but not executed" category. The previous list existed because Test-ColumnResize,
# Test-DragResize and Test-CredentialTyping still pointed at the root WUU.xaml/WUU.ps1 removed by the
# module split; all three were retargeted to ui\MainWindow.xaml + src\Wuu.Core.psm1 / src\Wuu.Remote.psm1
# (T025).
#
# The category was REMOVED rather than emptied on purpose: a stale list is a place for a suite that
# has quietly stopped testing anything to hide, still counted in the suite count. A suite that cannot
# run on the current tree should fail, not be quietly set aside. If one must be skipped in future,
# use a 'SKIP:' marker (which the runner already recognises and never counts as coverage), not a name
# in a list here.

function Invoke-SuiteChild {
    <#
    .SYNOPSIS
    Run one suite in a bounded STA child process and return a result record.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $psi.FileName)) { $psi.FileName = 'powershell.exe' }
    $psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $Path
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $repoRoot

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = $proc.Start()

    # Read both streams asynchronously so a chatty suite cannot deadlock on a full pipe.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $timedOut = -not $proc.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) {
        try { $proc.Kill() } catch { }
    }
    $null = $proc.WaitForExit(15000)
    $sw.Stop()

    $stdout = ''
    $stderr = ''
    try { $stdout = $outTask.Result } catch { }
    try { $stderr = $errTask.Result } catch { }

    if ($timedOut) {
        return [pscustomobject]@{
            Verdict = 'TIMEOUT'; ExitCode = -1; Seconds = [math]::Round($sw.Elapsed.TotalSeconds,1)
            StdOut = $stdout; StdErr = $stderr; Note = "exceeded ${TimeoutSec}s and was killed"
        }
    }

    $exitCode = $proc.ExitCode
    $verdict = 'PASS'
    $note = ''
    if ($exitCode -ne 0) {
        # A suite that cannot run because an environmental precondition is missing prints a
        # "SKIP:" line and exits non-zero. Treat that as SKIP, not FAIL - but report it, and
        # never count a SKIP as coverage.
        $skipLine = ($stdout -split "`r?`n") | Where-Object { $_ -match '^\s*SKIP:' } | Select-Object -First 1
        if ($skipLine) { $verdict = 'SKIP'; $note = $skipLine.Trim() }
        else { $verdict = 'FAIL' }
    }

    return [pscustomobject]@{
        Verdict = $verdict; ExitCode = $exitCode; Seconds = [math]::Round($sw.Elapsed.TotalSeconds,1)
        StdOut = $stdout; StdErr = $stderr; Note = $note
    }
}

# ---- normalise filters -----------------------------------------------------------------------
# A PowerShell array cannot survive "powershell.exe -File script.ps1 -Include a,b,c": the child
# host receives them as separate positional arguments. Accept a delimited STRING as well, so
# both call styles work:
#     & .\Invoke-TestSuites.ps1 -Include 'Test-A','Test-B'
#     powershell.exe -File .\Invoke-TestSuites.ps1 -Include 'Test-A,Test-B'
function Expand-FilterList {
    param([string[]]$Values)
    if (-not $Values) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($v in $Values) {
        if ($null -eq $v) { continue }
        foreach ($part in ($v -split '[,;]')) {
            $t = $part.Trim()
            if ($t) { $out.Add($t) }
        }
    }
    return $out.ToArray()
}

$includeList = @(Expand-FilterList -Values $Include)
$excludeList = @(Expand-FilterList -Values $Exclude)

# ---- discover suites -------------------------------------------------------------------------
$suiteFiles = @(Get-ChildItem -LiteralPath $SuiteDirectory -Filter 'Test-*.ps1' -File | Sort-Object Name)
if ($includeList.Count -gt 0) { $suiteFiles = @($suiteFiles | Where-Object { $n = $_.BaseName; @($includeList | Where-Object { $n -like $_ }).Count -gt 0 }) }
if ($excludeList.Count -gt 0) { $suiteFiles = @($suiteFiles | Where-Object { $n = $_.BaseName; @($excludeList | Where-Object { $n -like $_ }).Count -eq 0 }) }

if ($suiteFiles.Count -eq 0) {
    Write-Host "No suites matched in $SuiteDirectory" -ForegroundColor Yellow
    exit 0
}

Write-Host ("WUU2 suite runner: {0} suite(s) from {1} (timeout {2}s)" -f $suiteFiles.Count, $SuiteDirectory, $TimeoutSec) -ForegroundColor Cyan
Write-Host ''

$results = New-Object System.Collections.Generic.List[object]

foreach ($suite in $suiteFiles) {
    $name = $suite.BaseName

    $r = Invoke-SuiteChild -Path $suite.FullName -TimeoutSec $TimeoutSec
    $results.Add([pscustomobject]@{
        Suite = $name; Verdict = $r.Verdict; ExitCode = $r.ExitCode; Seconds = $r.Seconds; Note = $r.Note
    })

    $colour = switch ($r.Verdict) {
        'PASS'    { 'Green' }
        'SKIP'    { 'Yellow' }
        'TIMEOUT' { 'Magenta' }
        default   { 'Red' }
    }
    Write-Host ("{0,-28} {1,-8} exit={2,-4} {3,7}s" -f $name, $r.Verdict, $r.ExitCode, $r.Seconds) -ForegroundColor $colour
    if ($r.Note) { Write-Host ("    note: " + $r.Note) -ForegroundColor $colour }
    if ($r.Verdict -eq 'FAIL') {
        $failLine = ($r.StdOut -split "`r?`n") | Where-Object { $_ -match '^\s*FAIL:' } | Select-Object -First 3
        foreach ($fl in $failLine) { Write-Host ("    " + $fl.Trim()) -ForegroundColor Red }
        $errLine = ($r.StdErr -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 2
        foreach ($el in $errLine) { Write-Host ("    err: " + $el.Trim()) -ForegroundColor Red }
    }
}

# ---- aggregate -------------------------------------------------------------------------------
Write-Host ''
Write-Host '=== SUMMARY ===' -ForegroundColor Cyan
$grouped = $results | Group-Object Verdict | Sort-Object Name
foreach ($g in $grouped) { Write-Host ("{0,-8} {1}" -f $g.Name, $g.Count) }

$failed  = @($results | Where-Object { $_.Verdict -eq 'FAIL' })
$timedOut = @($results | Where-Object { $_.Verdict -eq 'TIMEOUT' })
$skipped = @($results | Where-Object { $_.Verdict -eq 'SKIP' })
$passed  = @($results | Where-Object { $_.Verdict -eq 'PASS' })

Write-Host ''
Write-Host ("PASS {0}  FAIL {1}  SKIP {2}  TIMEOUT {3}" -f $passed.Count, $failed.Count, $skipped.Count, $timedOut.Count)

if ($OutputJson) {
    $payload = [pscustomobject]@{
        GeneratedAt = (Get-Date).ToString('o')
        RepoRoot    = $repoRoot
        TimeoutSec  = $TimeoutSec
        Results     = @($results | ForEach-Object { $_.PSObject.Properties | ForEach-Object { $_ } | Out-Null; $_ })
        Summary     = [pscustomobject]@{
            Pass = $passed.Count; Fail = $failed.Count; Skip = $skipped.Count
            Timeout = $timedOut.Count
        }
    }
    $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
    Write-Host ("JSON written: {0}" -f $OutputJson) -ForegroundColor Cyan
}

# Exit 0 only when nothing FAILed or TIMEOUTed. SKIP is reported, never counted as coverage.
# coverage, and do not by themselves fail the run.
if ($failed.Count -gt 0 -or $timedOut.Count -gt 0) { exit 1 }
exit 0
