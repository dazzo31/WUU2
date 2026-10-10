#Requires -Version 5.1
<#
.DESCRIPTION
Application CONFIGURATION for WUU2 (GUI edition): the single home for the $global:* startup
settings - version and its provenance, logging flag, timeouts, per-operation deadlines,
credentials, concurrency and paths.

TRANSPLANTED from WUU2-CLI src\Wuu.Configuration.psm1 at donor revision
0566164bba3eb24d86121405bdbb39d58ff2c4ab (SHA-256 B5B42F9F8E7F52DB8F46821462A1DFE828D355DE4C4B7C68D0A59F8B321C9D19).
This is an ADAPTATION, not a copy: the GUI edition keeps its OWN version, its OWN path layout and
its OWN defaults. See docs\tasks\phase-0-evidence.md and docs\tasks\validation.md.

WHY THIS IS A MODULE AND NOT A BLOCK IN CORE. Core.psm1 already carried this as a `#region
Configuration` block inside Start-WuuApplication. It is still evaluated at startup, by an explicit
call at exactly the point the block occupied, so every $global: is set before anything reads it.
What changed is only that configuration is no longer tangled with orchestration - which is what
makes it reachable from a headless test.

ONE CONSTRAINT TRAVELS WITH IT: the version literal must be assigned BEFORE the resolver runs, or
the literal overwrites the resolved value and the provenance silently reverts to the embedded
string. The order is preserved here and must stay.

DEFAULTS POLICY (validation correction, Phase 1 item 1). The table below separates settings that are
UNCHANGED from the GUI edition from settings that are DELIBERATELY changed to the safer value. No CLI
default was transplanted blindly.

  Setting                        GUI before   Now          Why
  -----------------------------  -----------  -----------  ------------------------------------------
  EnableDebugLogging             $true        $false       verbose-by-default writes large logs on
                                                          every run; WUU_DEBUG=1 overrides. GUI has
                                                          no console to justify the chatter.
  OperationTimeoutSeconds        (absent)     per-op table the GUI had no deadline at all, so a hung
                                                          job held its runspace forever (SS5).
  OperationHeartbeatSeconds      (absent)     30s          distinguishes "still working" from "hung".
  PhaseFailurePolicy             (absent)     BlockOnFailure (store default in Wuu.State) - stopping
                                                          is recoverable; continuing past a failed
                                                          canary is not.
  Everything else                unchanged    unchanged    timeouts, credentials, MaxConcurrentJobs,
                                                          PerformanceThreshold, ConfigPaths.

#>

function Initialize-WuuConfiguration {
    <#
    .SYNOPSIS Applies the application's $global:* settings. Called once, at startup.
    .DESCRIPTION Takes $WuuRoot because several paths are derived from it. Returns nothing: every
    effect is a $global: assignment, which is what lets the caller stay a thin bootstrap step.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WuuRoot)

    # ---------------------------------------------------------------------------------------------
    # VERSION. WUU2 keeps its OWN version. The CLI literal ('v1.5.0-rc.1-cli') is deliberately NOT
    # transplanted: the two editions ship independently. The latest GUI release notes are
    # docs\RELEASE_NOTES_v1.3.4.md, so this literal starts there and must be bumped with the notes.
    # A $global: so Wuu.Logging (banner) and, later, Wuu.Audit (version on every record) read the
    # same value.
    # ---------------------------------------------------------------------------------------------
    $global:WuuVersion = 'v1.3.4'

    # PROVENANCE, immediately after the literal so the resolved value cannot be overwritten by it.
    # A release zip has no .git, so a packaged build legitimately falls back to the embedded value.
    # Resolve-WuuVersion lives in Wuu.State (transplanted, exported) - it is deliberately not copied
    # into this module, because one version rule must not exist twice.
    try {
        $resolver = Get-Command Resolve-WuuVersion -ErrorAction SilentlyContinue
        if ($resolver) {
            $versionInfo = Resolve-WuuVersion -Embedded $global:WuuVersion -RepoRoot $WuuRoot
            if ($versionInfo) {
                if ($versionInfo.Version) { $global:WuuVersion = [string]$versionInfo.Version }
                $global:WuuVersionSource = [string]$versionInfo.Source
                $global:WuuVersionTag = [string]$versionInfo.Tag
                if ($versionInfo.Mismatch) {
                    Write-Warning ("Version mismatch: $($versionInfo.Note). Audit records will carry '$global:WuuVersion' (source: $global:WuuVersionSource). Fix the embedded literal or re-tag.")
                }
            }
        }
    } catch {
        Write-Warning "Could not resolve the version from the repository; using '$global:WuuVersion'."
    }

    # ---------------------------------------------------------------------------------------------
    # LOGGING. DEFAULT IS OFF (changed from the GUI's previous $true - see the DEFAULTS POLICY above).
    # A malformed environment value must not stop startup; the default (off) stands.
    # ---------------------------------------------------------------------------------------------
    $global:EnableDebugLogging = $false
    try {
        if ($env:WUU_DEBUG -and @('1', 'true', 'yes', 'on') -contains $env:WUU_DEBUG.ToLowerInvariant()) {
            $global:EnableDebugLogging = $true
        }
    } catch {
        Write-Warning "Could not interpret WUU_DEBUG='$($env:WUU_DEBUG)'; debug logging stays disabled."
    }

    # ---------------------------------------------------------------------------------------------
    # TIMEOUTS (unchanged from the GUI edition).
    # ---------------------------------------------------------------------------------------------
    $global:sessionTimeout = 30       # Timeout for creating Windows Update session
    $global:searchTimeout = 300       # Timeout for update search operation
    $global:rebootCheckTimeout = 60   # Timeout for reboot check

    $global:CimTimeoutSeconds         = 10   # remote probe budget
    $global:ServiceTimeoutSeconds     = 10
    $global:PerformanceTimeoutSeconds = 60
    $global:CredProbeTimeoutSeconds   = 10
    $global:RebootProbeTimeoutSeconds = 10
    $global:OfflineWaitSeconds        = 600
    $global:OnlineWaitSeconds         = 1800

    # Management-endpoint probe used instead of ICMP for state transitions. 135 is the RPC endpoint
    # mapper the DCOM/CIM calls actually depend on. 3s is long enough for a LAN host and short enough
    # that a reboot wait loop stays responsive.
    $global:EndpointProbePort         = 135
    $global:EndpointProbeTimeoutMs    = 3000
    # How many CONSECUTIVE connectivity failures justify removing a computer from the set. More than
    # one, because a single blip must not evict a healthy server.
    $global:ConnectivityFailuresBeforeRemoval = 2

    # SS5: OPERATION-SPECIFIC deadlines (seconds), keyed by the op handed to Start-UpdateCheckJob.
    # WHY PER OP AND NOT ONE NUMBER. Windows Update has no single sensible deadline: a SEARCH can take
    # 20+ minutes against WSUS, an INSTALL can take hours, and a restart is the LONGEST because its
    # offline and online waits are 600s + 1800s. One number either kills healthy work or lets a hung
    # service action hold a runspace for 45 minutes. The deadline is recorded per computer
    # (TimeoutExpiresAt/TimeoutSource) at SUBMISSION, so it is inspectable while the job runs rather
    # than recomputed from a start time a restart could reset.
    $global:OperationTimeoutSeconds = @{
        'Check'             = 2700   # 45 min - large-estate search + download scan
        'Download'          = 2700   # 45 min
        'InstallAndRecheck' = 7200   # 2 h   - servicing-stack installs are genuinely slow
        'AutoFlow'          = 14400  # 4 h   - full chain, must exceed its own reboot waits
        'Restart'           = 2700   # 45 min - covers OfflineWait + OnlineWait (600 + 1800) with margin
        'RemoveOffline'     = 300    # 5 min - a connectivity probe
        'ServiceAction'     = 300    # 5 min - a hung service control is stuck, not slow
        'default'           = 1800   # 30 min - anything unrecognised: bounded, but not punishing
    }
    # The deadline is the BACKSTOP; the heartbeat is what distinguishes "still working" from "hung".
    $global:OperationHeartbeatSeconds = 30

    # ---------------------------------------------------------------------------------------------
    # ERROR HANDLING (unchanged).
    # ---------------------------------------------------------------------------------------------
    $global:EnableEnhancedErrorHandling = $true

    # ---------------------------------------------------------------------------------------------
    # CREDENTIALS (unchanged) plus the Phase 1 credential epoch. A monotonic counter bumped whenever
    # the credential configuration changes; stamped onto a row when its runspace is built, so a
    # submission under changed credentials rebuilds the runspace instead of silently reusing one that
    # captured the previous identity.
    # ---------------------------------------------------------------------------------------------
    $global:UseCustomCredentials = $false
    $global:CustomCredentials = $null
    $global:CredentialCache = @{}
    $global:CredentialConfig = @{ Username = ''; Domain = ''; UseCredentials = $false }
    $global:CredentialEpoch = 0

    # ---------------------------------------------------------------------------------------------
    # CONCURRENCY AND PERFORMANCE (unchanged).
    # ---------------------------------------------------------------------------------------------
    $global:MaxConcurrentJobs = 10
    $global:PerformanceThreshold = @{ CPUPercent = 80; MemoryMB = 1024; NetworkLatencyMs = 1000 }

    $global:backgroundProcessing = [hashtable]::Synchronized(@{ Suspended = $false })

    # ---------------------------------------------------------------------------------------------
    # PATHS (GUI layout preserved: Scripts\, ui\, src\ are relative to $WuuRoot; ComputerList.config
    # lives in the repo root in this edition).
    # ---------------------------------------------------------------------------------------------
    $global:ConfigPaths = @{
        DownloadScript     = Join-Path $WuuRoot 'Scripts\Download-Patches.ps1'
        InstallScript      = Join-Path $WuuRoot 'Scripts\Install-Patches.ps1'
        ComputerListConfig = Join-Path $WuuRoot 'ComputerList.config'
        LogDirectory       = $WuuRoot
    }

    # Audit ANCHOR directory (Phase 4). Deliberately NOT under the audit directory: an anchor beside
    # the log is written through the same access path as the log, so it offers no separation and the
    # anchor verifier refuses it. Overriding it only moves the file - the real control is holding it
    # somewhere the audited operator cannot write.
    $global:AuditAnchorDirectory = Join-Path $env:ProgramData 'WUU2\anchors'
    $global:EnableAuditEventLogAnchor = $false

    # ---------------------------------------------------------------------------------------------
    # REQUIRED EXTERNAL FILES (unchanged): warn, never block startup.
    # ---------------------------------------------------------------------------------------------
    $requiredFiles = @('Scripts\Download-Patches.ps1', 'Scripts\Install-Patches.ps1')
    foreach ($file in $requiredFiles) {
        $fullPath = Join-Path $WuuRoot $file
        if (-not (Test-Path $fullPath)) {
            Write-Warning "Required file not found: $fullPath - functionality may be impaired"
        }
    }
}

Export-ModuleMember -Function @('Initialize-WuuConfiguration')
