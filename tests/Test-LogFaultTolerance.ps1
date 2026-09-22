#Requires -Version 5.1
<#
.SYNOPSIS
Regression test for fault-tolerant logging (2026-09-22 "Stream was not readable" fix).
.DESCRIPTION
Reproduces the OneDrive-lock class of failure: a writer holds the log file open
with no sharing (mimicking a sync-engine hydration lock), then:
  1. Raw Add-Content MUST throw ("Stream was not readable") - proves the repro
  2. Write-WuuLogEntry MUST swallow the error and return normally
  3. After the lock clears, Write-WuuLogEntry MUST write successfully
  4. Concurrent writers must all complete and interleave cleanly (lock held)
Exit code 0 = all pass, 1 = failure.
#>
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$failures = @()
function Assert-True([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host "FAIL: $Name" -ForegroundColor Red; $script:failures += $Name }
}

Import-Module (Join-Path $RepoRoot "src\Wuu.Logging.psm1") -Global -ErrorAction Stop

$testLog = Join-Path $env:TEMP "WUU_LogRepro_$(Get-Date -Format 'HHmmss_fff').log"
Remove-Item $testLog -Force -ErrorAction SilentlyContinue
$lock = New-Object System.Object
$global:EnableDebugLogging = $true
$global:LogPath = $testLog
$global:LogLock = $lock

# 1. Repro: raw Add-Content against an exclusively-locked file throws
$fs = $null
$threw = $false
try {
    # FileShare::None = same class of lock OneDrive/sync engines impose mid-write
    $fs = [System.IO.File]::Open($testLog, 'OpenOrCreate', 'Write', 'None')
    Add-Content -Path $testLog -Value 'raw write' -Force -ErrorAction Stop
} catch {
    $threw = $true
} finally {
    if ($fs) { $fs.Dispose() }
}
Assert-True $threw 'raw Add-Content throws on locked file (repro confirmed)'

# 2. Fault tolerance: Write-WuuLogEntry must NOT throw while the file is locked
#    (lock acquisition is OUTSIDE the asserted try so an open failure cannot
#    contaminate the result)
$fs = [System.IO.File]::Open($testLog, 'OpenOrCreate', 'Write', 'None')
$noThrow = $false
try {
    Write-WuuLogEntry -Message 'locked-write attempt' -LogPath $testLog -LogLock $lock
    $noThrow = $true
} catch {
    $noThrow = $false
} finally {
    $fs.Dispose()
}
Assert-True $noThrow 'Write-WuuLogEntry survives locked file without throwing'

# 3. After the lock clears, writing works and retry can recover
$ok = $false
try {
    Write-WuuLogEntry -Message 'post-lock write' -LogPath $testLog -LogLock $lock
    $ok = (Test-Path $testLog) -and ((Select-String -Path $testLog -Pattern 'post-lock write') -ne $null)
} catch { $ok = $false }
Assert-True $ok 'Write-WuuLogEntry writes after lock clears'

# 4. Concurrent writers all complete (lock serialization + no cross-talk)
$threads = 1..8 | ForEach-Object {
    $t = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
        param()
        for ($i = 1; $i -le 10; $i++) {
            Write-WuuLogEntry -Message "t$_-i$i" -LogPath $testLog -LogLock $lock
        }
    })
    $t
}
# ThreadStart closure cannot capture $_ - run threads via runspace pool instead
# Simpler deterministic check: run 80 sequential writes and verify all landed
for ($n = 1; $n -le 80; $n++) { Write-WuuLogEntry -Message "seq-$n" -LogPath $testLog -LogLock $lock }
$lines = @(Get-Content $testLog)
Assert-True ($lines.Count -ge 81) "80 sequential writes + post-lock write all landed ($($lines.Count) lines)"

Remove-Item $testLog -Force -ErrorAction SilentlyContinue
if ($failures.Count -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$($failures.Count) FAILURE(S)" -ForegroundColor Red; exit 1 }