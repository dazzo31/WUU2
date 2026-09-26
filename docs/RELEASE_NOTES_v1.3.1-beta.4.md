# WUU2 v1.3.1-beta.4 — Auto Download/Install fix (Beta)

**Pre-release for testing.** Fourth beta of the 1.3.1 line: fixes **Auto Download** and **Auto Install** silently doing nothing.

## What's fixed

With the *Auto Download* and/or *Auto Install* checkboxes ticked, a check that found updates would report them correctly but then never download or install. The computer row just sat there.

### Root cause
The auto-chained operations (`GetUpdates` → `DownloadUpdates`, and `DownloadUpdates` → `InstallUpdates`) started a brand-new `PowerShell` pipeline pointed at **the same per-computer runspace that was already busy** running the current step, and called `BeginInvoke()` from inside it.

A runspace runs one pipeline at a time. `BeginInvoke` on a busy runspace returns success and its handle reports complete instantly, but the chained payload **never executes** — the eventual `EndInvoke` throws *"pipeline already running"*, which the background cleanup swallowed. The follow-up step was silently discarded, so no download or install ever happened.

Manual buttons worked because those queue all steps as multiple `AddScript` calls in **one** pipeline.

### The fix
Chained operations now run the same way the working manual path does:

- After a check finds updates, the auto logic **queues the follow-up instead of firing it inline**. With both *Auto Download* and *Auto Install* on, the full unattended chain runs as a single pipeline: **Download → Install → Reboot (if needed & *Auto Reboot* on) → Re-check**.
- With only *Auto Download* on, just the download is queued. A manual *Download* with *Auto Install* on queues *Install → Reboot → Re-check*.
- The job scheduler (the existing 1-second timer) starts the chain once the computer's runspace is free, so pipelines never collide.

No UI or setting changes — the checkboxes now drive the behavior they always implied.

## Also fixed

**Release packaging no longer drops the zip.** `Compress-Archive` intermittently threw when writing into the OneDrive-synced `dist/` folder and left no file behind while still printing "Created package". The packager now uses the `System.IO.Compression.ZipFile` API, verifies the archive exists, and reports the real entry count (25 entries), failing loudly if it's missing or empty.

## Validation
- Release checks pass (XAML load + control/event wiring).
- Module import, cross-module runspace resolution, and the pending-job drain tests pass.
- Not yet exercised end-to-end against a machine with pending updates — this fix depends on in-GUI scheduling, so it's a beta. Run it on a host that actually has updates waiting, tick both boxes, and confirm the row flows through *Downloading → Installing → Up-to-date*.

## Notes
- Pure PowerShell + WPF; PS 5.1 STA, elevated. PSExec not required (removed in beta.3).
- Debug log: `%TEMP%\WUU_Debug_*.log`.
