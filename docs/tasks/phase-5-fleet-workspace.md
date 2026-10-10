# Phase 5 — Fleet Workspace + Deployment Review Redesign (T020-T024)

Binding validation corrections: read `docs/tasks/validation.md`, section 'Phase 5 Corrections', before execution. Those corrections supersede conflicting instructions below, including shared-command/event wiring, stale-telemetry interaction, live-action dependencies and supported accessible glyph/resources.

Status: proposed. Depends on Phase 1 contracts (engine store + `Wuu.Gui` adapter). XAML/resource styling may proceed in parallel with Phases 2-4; production ACTION wiring depends on Phases 2 (engine), 3 (config), 4 (audit). Requirements covered: R01, R02, R06, R07.

## Approved design (user decision)
- A persistent **Fleet workspace** with an action toolbar, details pane, and a **Deployment review** dialog before mutations — NOT a forced step-by-step wizard.
- **System-aware** light/dark themes + dedicated **HighContrast** theme, with text/icons alongside every status colour (no red-green-only encoding).
- Views: Fleet · Deployment review · Reports/Audit · Settings.

## Non-negotiable constraints
- Retain WPF/XAML + PowerShell 5.1. No new chart/GUI package (no Graphical, no WPF toolkit download, no web view).
- Preserve AD acquisition, file/manual import, named lists, phases, credentials, service actions, Remote Desktop, history/WSUS/update-log views, export and clipboard actions.
- Background updates stay off the UI thread except via the dispatcher; coalesced refresh (Phase 1 T008), not one `Items.Refresh` per heartbeat.
- Colour is never the only signal: every status has a text token + an icon/glyph.
- Layout/resources may parallel Phases 2-4 after Phase 1 interfaces are stable; LIVE mutation wiring waits for engine, config and audit gates.

## Inputs
- `ui\MainWindow.xaml` (current single-window layout; x:Name inventory; ListView styles)
- `ui\CredentialDialog.xaml` (existing templated dialog pattern to reuse for chooser/reason)
- `src\Wuu.Core.psm1` (findName wiring ~L2552; Add_* handler wiring ~L4398)
- `src\Wuu.Gui.psm1` (NEW — from Phase 1 T006; projection + theme selection live here)
- Phase 4 report models; Phase 3 named-list chooser

## Tasks

### T020 [R01][R07] Restructure MainWindow into the workspace
- [ ] Replace the free-standing menu/table layout with: a persistent fleet region (table + toolbar + status strip) plus a navigation region switching Deployment-review / Reports-Audit / Settings content.
- [ ] Keep list/table virtualised (VirtualizingStackPanel) so large fleets stay responsive.
- [ ] Validate every NEW or RENAMED interactive control's x:Name resolves in Core with its INTENDED event/command wiring; passive controls need no handler. Shared commands across toolbar/menu/context controls are valid — detect accidental DUPLICATE subscriptions, not multiple legitimate callers. Extend `Scripts\Validate-Release.ps1` wiring checks accordingly.
- [ ] Menus/context menus remain as accelerators (keyboard shortcuts + right-click), not the only path.
Pass criteria: every retained legacy action remains reachable and wired; gate passes; window usable at the supported minimum size.

### T021 [R02][R07] Fleet grid + details pane
- [ ] Fleet grid columns: Computer, Phase, State, Updates (A/D), Reboot, Operation/Deadline/Heartbeat, Status.
- [ ] Toolbar with search and filters (state, phase, reboot-required, failed-only); selected-target count shown; actions act on the CURRENT selection.
- [ ] Selection is by Computer key (stable across sort/filter/refresh) per Phase 1 T006/T008.
- [ ] Details pane: per-computer state, last operation, deadline budget + remaining, heartbeat age, last error, reboot evidence, refusal record, credential identity. Unknown/unchecked renders as Unknown — never as success.
- [ ] Row detail updates are coalesced (batch refresh), keeping the grid responsive during a 100+ host fleet.
Pass criteria: filtering never changes underlying state ownership; stale telemetry is visibly distinct and actions REVALIDATE current engine state (do not disable all inspection on a stale heartbeat); responsiveness holds with synthetic large fleets.

### T022 [R02][R06] Deployment review dialog (gated by audit)
- [ ] Before any mutating action: show selected targets + phases, intended steps, unresolved prerequisites, credential identity in effect, phase-failure policy, auto-reboot setting, and a required Reason field.
- [ ] Review PREVIEW is read-only: it does NOT write audit. Confirmation revalidates the reviewed target snapshot and authorization before effects.
- [ ] On confirm, re-resolve/re-validate admission at execution time (review is not a slot reservation); then record intent through the audit wrapper (Phase 4) and submit through the single admission path (Phase 2 T011).
- [ ] Outcome presentation distinguishes queued / refused (with reason) / running / succeeded / failed / timed out / uncertain-remote-continuation; retry-failed acts on failure EVIDENCE, not on a colour.
- [ ] Closing/cancelling mid-operation states truthfully what continues (a started remote SYSTEM task may continue); no invented cancellability is promised.
Pass criteria: empty Reason blocks execution; review cannot run against a selection that changed after review without re-resolution; audit intent precedes any mutation.

### T023 [R07] Theme system with accessible status
- [ ] Add `ui\Themes\Light.xaml`, `Dark.xaml`, `HighContrast.xaml` resource dictionaries; the window merges ONE dictionary chosen at startup and on a Windows theme change (OS-version-safe fallback — SystemParameters/registry detection guarded by try/catch).
- [ ] Optional local theme override stored in a SEPARATE WUU2-local settings file — NEVER in the shared computer-list config.
- [ ] Status mapping is text+icon (e.g. OK, pending, warning, failed, reboot) plus colour; success uses a palette distinct from failure; colour is supplementary. Use glyph assets available on supported Windows versions and keep source encoding PS5.1-safe; verify contrast rather than asserting a palette name.
- [ ] HighContrast uses system high-contrast resources; add AutomationProperties.Name/HelpText for all interactive controls; logical tab order; visible focus cues. Verify keyboard/Narrator behaviour, not palette names.
Pass criteria: usable in light, dark and HighContrast; no status conveyed by colour alone; keyboard-only navigation complete; Narrator reads control purposes.

### T024 [R07] Reports/Audit view
- [ ] Render Phase 4 report models: period/phase filters, run-outcome and cause bar visualisations from PROVEN counts, plus export/verify/anchor controls.
- [ ] Bars are drawn in WPF (Border/Rectangle lengths bound to the model) — no third-party chart package, no terminal-glyph matrices.
- [ ] Provide an accessible TABULAR equivalent of every chart (screen reader can read the numbers).
- [ ] Include empty / loading / error / unconfigured-anchor states explicitly, each with text.
Pass criteria: charts and tables agree; verify/export/anchor reflect the Phase 4 verdicts; empty-anchor is labelled, not blank.

## Phase 5 gate
All legacy capabilities retained and reachable; no engine bypass through UI; keyboard + HighContrast usable; text fits at minimum size and 100/150/200 % DPI with no freeze/deadlock; deployment review blocks unreasoned mutation.
