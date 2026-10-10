# Phase 2 — Credentials, Remote Results, Worker Lifecycle (T009-T013)

Binding validation corrections: read `docs/tasks/validation.md`, section 'Phase 2 Corrections', before execution. Those corrections supersede conflicting instructions below, including the T009 `.psm1` target path, request-identity-safe pending consumption, auxiliary worker distinction and explicit reusable/retired runspace shutdown policy.

Status: proposed. Depends on Phase 1 gate PASS. Requirements covered: R02, R03, R04.

## Goal
Make every operation attributed, bounded, credential-deterministic and failure-accurate, across all GUI action entry points. A failed install must never read as Complete; a superseded worker must never overwrite its replacement; refused work must stay queued.

## Inputs
Target:
- `src\Wuu.Core.psm1` (action handler closures; Start-PendingUpdateCheck caller; cleanup)
- `src\Wuu.Credentials.psm1` (Protect/Unprotect, Get-RemoteCredentials, dialogs, runtime cache)
- `src\Wuu.WindowsUpdate.psm1` (New-ComputerRunspace injection; Start-UpdateCheckJob)
- `src\Wuu.Workers.psm1` (pool; Invoke-WithPoolTimeout; job cleanup)
- `src\Wuu.Remote.psm1` (Invoke-CimWithTimeout; Invoke-WuuRemoteTask), `src\Wuu.Network.psm1`
- `Scripts\Download-Patches.ps1`, `Scripts\Install-Patches.ps1`
Donor (read-only):
- `src\Wuu.Credentials.psm1` (Resolve-WuuOperationCredential, Update-WuuCredentialEpoch, Get-WuuCredentialStateSignature)
- `src\Wuu.Scheduler.psm1` (acceptance-then-consume), `src\Wuu.WindowsUpdate.psm1` (claim under `-OperationIdNew`; rollback), `src\Wuu.Workers.psm1` (identity-guarded cleanup incl. OperationId retirement)
- `tests\Test-PendingPolicy.ps1`, `Test-SchedulerSerialization.ps1`, `Test-OperationTimeouts.ps1`, `Test-CredentialDeterminism.ps1`, `Test-InstallOutcome.ps1`

## Tasks

### T009 [R04] Deterministic credential identity
- [ ] Port Resolve-WuuOperationCredential + Update-WuuCredentialEpoch + Get-WuuCredentialStateSignature into `src\Wuu.Credentials.psm1` WITHOUT removing the GUI dialogs. Keep prompts on the UI thread only.
- [ ] A failed custom credential REFUSES the operation; it must NOT silently fall back to the process account. Keep the GUI runtime cache; credentials are never persisted as passwords.
- [ ] Rebuild idle per-computer runspaces when the credential epoch/signature changes; an in-flight job keeps the identity it started under.
- [ ] Stamp CredentialEpoch/CredentialIdentity on the row at runspace creation.
Pass criteria: custom-cred failure is reported and refused (no fallback); changing credential config flags stale runspace; identity recorded and inspectable.

### T010 [R02][R03] Remote result + task semantics
- [ ] Make `Invoke-WuuRemoteTask` return an explicit result model `{ Success; Count; Total; RebootRequired; ExitCode; Error }` and interpret `Install-Patches.ps1` `Count` as FAILED updates (not progress).
- [ ] Ensure `Scripts\Install-Patches.ps1` reports `Result='Failed'` when error count > 0, and that `Wuu.Remote` preserves Count AND RebootRequired on a non-success result.
- [ ] Failure classification must not depend solely on English exception message matching; prefer explicit Result/ExitCode/InstallErrors.
- [ ] Preserve target task cleanup uncertainty semantics: no over-claiming completion when remote telemetry is absent.
Pass criteria: a mocked install with 2 failed of 3 + RebootRequired produces Failed (not Complete) and keeps RebootRequired=true. Drive the REAL InstallUpdates payload path, not only source-pattern regexes.

### T011 [R02][R03] Single admission path + pending refusal safety
- [ ] Add `src\Wuu.Scheduler.psm1` (donor model): every GUI operation-affecting action (check/download/install/restart/service/composite deploy) submits through ONE admission path. Do not repoint unrelated AD-discovery or read-only auxiliary runspaces.
- [ ] Accept-then-consume: resolve PendingOp BEFORE submission; only clear Pending/PendingOp AFTER `Start-UpdateCheckJob` returns success. On refusal the request stays intact for the next tick.
- [ ] An accepted submission must NOT erase a newer pending request queued during admission; queue requests carry stable identity/revision and only the accepted request is consumed.
- [ ] Claim under `-OperationIdNew` BEFORE BeginInvoke, with identity-checked rollback through the funnel if reservation fails.
- [ ] Remove any alternate direct BeginInvoke submission path that bypasses admission.
Pass criteria: concurrent submission cannot exceed the cap; a refusal leaves Pending and PendingOp intact and is retried; busy-computer double-submit is refused.

### T012 [R02][R03] Identity-guarded cleanup and terminal protection
- [ ] Port donor Workers cleanup semantics: stale-writer guard on completion/failure; detach BEFORE releasing the per-computer lock on timeout; retire OperationId/deadline/heartbeat metadata when settling.
- [ ] Cache the runspace reference BEFORE detaching, then `Close()`+`Dispose()` exactly once (removal and shutdown paths). `PowerShell.Dispose()` does NOT close the assigned runspace.
- [ ] Document reusable-idle vs retired runspace policy; a completed job may keep an idle reusable runspace but must not keep a retired OperationId.
- [ ] A queued follow-up on a terminal row is admitted as a NEW attributed operation; ClearOperation must not launder a settled Error/Timeout display into Queued.
- [ ] A failed install must not be overwritten by a later restart/recheck success (operation-scoped result retention).
Pass criteria: invariant check (no OperationId on Idle rows; no half-cleared deadline) returns empty after success AND timeout paths; no handle leaks across 100 synthetic jobs.

### T013 [R03] Pending precedence, refusal records, phase policy, connectivity
- [ ] Port pending-op precedence (Set-WuuPendingOperation / Get-WuuPendingOpRank) so an operator request is not displaced by an internal auto-follow-up.
- [ ] Port refusal recording (RefusedCount/RefusedReason/RefusedAt) + stall detection so a permanently unadmittable row stops the phase VISIBLY rather than hanging silently. A capacity refusal is NOT a machine failure.
- [ ] Phase failure policy: BlockOnFailure default; ContinueOnTimeout/ContinueOnFailure honoured exactly. A refused row is reported as stalled, distinct from a machine failure.
- [ ] Connectivity: inventory membership is not a ping result; prune offline is a reviewed inventory mutation with a consecutive-failure threshold, not a single-ICMP deletion.
Pass criteria: phase gate advances only per policy; refused row surfaces; single lost ping does not evict a host; precedence upgrades but never silently downgrades.

## Phase 2 gate
Deterministic fake-worker tests pass for: cap enforcement, refusal retention, late completion after supersede, install+reboot failure, phase policy, retry promotion, credential-epoch rebuild, and shutdown leak check. No identity-free Running rows; no leaked handles.
