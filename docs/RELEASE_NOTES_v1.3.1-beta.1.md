# WUU2 v1.3.1-beta.1 — Worker Pool Architecture (Beta)

**Pre-release for testing.** This beta replaces every per-probe background PowerShell job with a shared in-process runspace pool. Please test on your normal workflow and report any hang, stall, or unexpected timeout behavior.

## Why this change

Previously, every bounded remote operation (WMI/CIM probe, service check, credential test, reboot online-probe) wrapped its work in `Start-Job` → `Wait-Job` → `Receive-Job` → `Remove-Job`:

- **Each probe spawned a full child PowerShell process** (its own engine, ~30–60 MB working set) that was created and destroyed per call.
- During a reboot wait, the online-probe **re-spawned a child process every 5 seconds for up to 30 minutes**.
- Ten such sites existed across four modules; a 50-machine scan could spawn well over a hundred child processes.

## What's new

- **`src/Wuu.Workers.psm1`** — a lazily-created, module-scoped **runspace pool** (min 2 / max 8 workers, STA, `UseNewThread` — same threading model as the per-computer workers). Bounded operations now submit to the pool and reuse warm runspaces.
- **`Invoke-WithPoolTimeout`** — the pool's bounded-execution primitive. Returns the exact same `@{ Success; Result; Error }` contract the old helpers did, so call sites are unchanged in behavior.
- **Hard timeout semantics preserved**: if a native call (DCOM/RPC) black-holes, the wrapper requests a bounded stop and then **abandons** the worker rather than blocking the caller — the same "caller always gets a timeout error" guarantee the old `Remove-Job -Force` gave, without process-per-probe overhead.
- **Pool access from isolated worker runspaces**: the pool object and an unbound invoke script are injected into every per-computer runspace (`WuuWorkerPool` / `InvokePooledScript`), so scripts executing there use the pool without needing module imports.
- **All 10 `Start-Job` sites migrated** across `Wuu.Remote`, `Wuu.Network`, `Wuu.WindowsUpdate`, and `Wuu.Core` (including the local helper copies inside the update-search payload). **Zero `Start-Job`/`Wait-Job`/`Receive-Job` calls remain in the codebase.**

## Bug fixes included

- **`SafeUpdateListViewItem` (main-session copy)**: still contained the dispatcher-deadlock pattern (pipeline cmdlets inside a `Dispatcher.Invoke` action) that caused the 2026-09-16 GUI hang — the exact landmine the session set out to remove. Now uses a plain `foreach` lookup, identical to the verified runspace copy.
- **`Test-SystemDependencies`**: read `$script:UseDomainCredentials` / `$script:AlternateCredentials` — variables that were **never defined** after the module split. The old `Start-Job` code masked the crash (failed-job output was truthy), so the function silently reported RPC unreachable on every machine. Now uses the real credential model (cache → custom → default).

## Known limitations

- **Pool capacity vs. concurrency**: pool max is 8 workers while default `$MaxConcurrentJobs` is 10. If you raise `MaxConcurrentJobs` above 8, raise the pool max in `Wuu.Workers.psm1` (`$script:MaxPoolSize`) accordingly — otherwise probes queue briefly behind pool slots rather than failing.
- **Windows Update COM objects are intentionally NOT pooled** — COM interfaces cannot cross runspace boundaries. WUA search/download/install remain in their dedicated per-computer runspaces, unchanged.
- Pooled runspaces keep session state between calls; all submitted scriptblocks are self-cleaning (verified), but any future probe must clean up its CIM sessions in `finally`.

## Testing focus

When validating this beta, please watch specifically for:

1. **Large computer lists** (50+) — check for stalls during "Validating connectivity" or credential probing.
2. **Reboot flow** — the online-wait probe now runs on the pool; confirm the "Restarting... waiting to come online" cycle completes.
3. **Custom credentials** — the credential probe path changed; verify cache-first behavior and the custom → default fallback.
4. **Service actions** (Start/Stop/Restart WU service menus) — remote service actions now run on the pool with a 20-second bound.
5. **Memory footprint** — the app should now spawn far fewer child `powershell.exe` processes; noticeable especially during long scans.

## Verification already performed

- Parser clean on all 9 files (8 modules + entry point)
- 39/39 `Validate-Release.ps1` checks pass (XAML + control/event wiring)
- New `tests/Test-WorkerPool.ps1` (6 cases, incl. isolated-runspace topology) — all pass
- New `tests/Test-RemoteHelpers.ps1` (live CIM/service/RPC probes + hard-timeout on a non-routable address + pool-reuse) — all pass
- `Test-PendingDrain.ps1` + `Test-CrossModuleResolution.ps1` (extended with a real worker-runspace pool-injection check) — all pass

## Compatibility

- Windows PowerShell 5.1, elevated, STA (unchanged)
- No configuration changes; drop-in replacement for v1.3.0