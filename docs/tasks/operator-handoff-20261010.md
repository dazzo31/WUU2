# WUU2 GUI Remediation — Operator Handoff Runbook

Date: 2026-10-10. Target: `C:\Users\dazzo\OneDrive\GitHub\WUU2` (Windows PowerShell 5.1, STA).

This runbook covers the two release gates that **cannot** be run headlessly and are therefore the
operator's to execute, plus the exact commands to reproduce everything that was verified automatically.
Nothing here commits, tags or releases; run them when you are ready.

---

## 1. State you are picking up

- `HEAD` is `f1d5f97` (tag **v1.3.4**). **All remediation work is UNCOMMITTED** (modified `Wuu.Core`,
  `Wuu.WindowsUpdate`, `Wuu.Workers`, `Wuu.Credentials`, `Wuu.Remote`, `ui/MainWindow.xaml`,
  `Scripts/Package-WUU2.ps1`, several tests; new `src/Wuu.State.psm1`, `src/Wuu.Configuration.psm1`,
  `src/Wuu.Gui.psm1` and new `tests/Test-*.ps1`). Decide the branch/commit policy before shipping.
- **Automated evidence (reproduce any time, from the repo root):**
  ```powershell
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Invoke-TestSuites.ps1   # expect 20 PASS / 1 SKIP / 0 FAIL
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Validate-Release.ps1     # expect exit 0
  ```
  The single SKIP is `Test-RemoteTask` (needs elevation to register a SYSTEM task) - see Gate B.
- **Package sanity (optional):**
  ```powershell
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Scripts\Package-WUU2.ps1 -OutputDirectory C:\Temp\pkg
  ```
  Expect 27 entries, **0** backslash entry names. (The packager now fails closed if any survive.)

---

## 2. Operator gate A — elevated interactive desktop smoke test

**Why:** proves the decoupled projection repaints on a REAL desktop, that no WPF edit-transaction is left
open, and that save/load and a clean close work. Headless suites cannot observe a live render pass.

**Preconditions**
- You are on an interactive desktop session (not a service/headless host) and are a local **Administrator**.
- `ComputerList.config` is backed up. A verified copy exists at
  `docs\tasks\operator-config-backup-20261009-083213\ComputerList.config` (SHA-256 starting `F6484FE0`).
  Confirm it still hash-matches your live file before you start:
  ```powershell
  Get-FileHash .\ComputerList.config -Algorithm SHA256 | Select-Object -ExpandProperty Hash
  ```

**Run**
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1
```

**Steps and expected results**

| # | Do this | Expect |
|---|---|---|
| 1 | Turn on debug logging first (new shell): `$env:WUU_DEBUG='1'` then launch. | Log at `%TEMP%\WUU_Debug_<stamp>.log`. |
| 2 | Add `localhost` (right-click → Add, or paste it). | One row appears, `Status` = a real state (not blank). |
| 3 | Right-click `localhost` → **Check for Updates**; watch the row. | Status/State change and the **grid repaints** (row text updates within ~1 s). |
| 4 | While it is still running, click **Check** again. | A clean refusal (no `[ERROR] Runspace creation failed`, no row painted Error); the running check's progress text survives, and it completes normally. |
| 5 | Let the check finish. | Final status shows the update count; no exception dialog. |
| 6 | Set a phase on the row (right-click → Phase menu) and watch. | The `Phase` column updates (projection repaint). |
| 7 | **Configuration → Save** the encrypted list (set a password). | "Encrypted computer list saved…". No exception. |
| 8 | **Configuration → Load** it back (same password). | The fleet swaps in one step; same row(s) present. |
| 9 | Try **Load** with a WRONG password. | A clear error dialog; the existing fleet is **untouched** (not cleared). |
| 10 | Delete a row (select → Delete). | Row disappears; re-adding it works. |
| 11 | Close the window. | Exits promptly (no hang). If debug logging is on, the log ends with shutdown cleanup complete - **no** `Worker pool teardown timed out`. |

**Failure capture:** if anything misbehaves, grab `%TEMP%\WUU_Debug_<stamp>.log` and the newest
`Wuu_*.log`; those name the exact operation/refusal reason.

---

## 3. Operator gate B — disposable-host lab (download / install / reboot / recovery)

**Why:** the payloads were driven against MOCKED remote seams (`InvokeRemoteTaskScript`,
`TestEffectAuthorizedScript`). Only a real SYSTEM scheduled task on a throwaway host proves the
end-to-end remote path. **Never** run this against production servers.

**Use a disposable VM (or a snapshotted test host) with Windows Update reachable.** Then:
1. Elevate. Add the VM to the list. Run a full **Check → Download → Install** from the menus.
2. Watch for: progress text advancing, `InstallErrors` reflecting only genuinely failed updates, and a
   `Reboot required` state when the OS says so. Confirm the target reboots (if auto-reboot is enabled) and
   the follow-up recheck runs in the SAME admitted chain (one operation, not two).
3. **Recovery:** force a failure (offline the WSUS/network briefly) and confirm the row shows a recoverable
   `Timeout` (not a terminal Error) and that a retry is admitted.
4. **Elevation-only suite** (covers the remote-task contract):
   ```powershell
   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-RemoteTask.ps1
   ```
   Expect all PASS (it registers a trivial SYSTEM task and verifies result/cleanup). This is the suite that
   SKIPs in the headless run.
5. Confirm no leftover `\WUU2\` scheduled tasks and no leftover `HKLM:\SOFTWARE\WUU2\Jobs\*` keys.

**Known honest limits:** an authorized already-dispatched remote effect may continue after a local
cancel; local disposal does **not** prove a remote SYSTEM task stopped. Do not over-claim cancellation.

**Rollback:** restore `ComputerList.config` from the backup dir in section 2 if the lab altered it.

---

## 4. What was fixed in this remediation (one-paragraph orientation)

- **Projection (T006.1):** the ListView now holds DETACHED view rows reconciled from the engine store by
  `Update-WuuProjection` (revision-gated); engine writes reach the grid only through that reconcile.
- **Admission & fencing:** every engine submission goes through `Start-UpdateCheckJob` (claim + cap before
  `BeginInvoke`); payload row writes go through the allow-listed fenced writer with identity/reset/terminal/
  live-row rules; the one-slot queue (`Pending`/`PendingOp`) is written under the shared store gate on both
  the payload and scheduler sides.
- **Deadlines & policy:** the per-operation deadline is stamped at submission and enforced by the cleanup
  loop; phase gating honours `PhaseFailurePolicy`; connectivity eviction requires consecutive failures and
  uses an injected store-removal twin.
- **Shutdown:** jobs/runspaces/cleanup runspace are torn down with a bounded helper that abandons a wedged
  join instead of hanging.
- **Packaging:** entry names use `/` (ZIP-spec); operator data (including `ComputerList.config`) is excluded
  and a leak fails the build closed.

Full detail and the independent-review disposition: `docs/tasks/phase-1-evidence.md`.
The active plan (all items complete): `docs/tasks/remediation-plan-20261008.md`.
