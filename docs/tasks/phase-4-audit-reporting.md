# Phase 4 — Audit Trail and Read-Only Reporting (T017-T019)

Binding validation corrections: read `docs/tasks/validation.md`, section 'Phase 4 Corrections', before execution. Those corrections supersede conflicting instructions below: headless Audit services and Gui presentation have fixed ownership; config integration waits for Phase 3; Phase 5 provides a request/reason adapter later; pure reporting is distinguished from wrapper access logging; exports include only captured evidence.

Status: proposed. Depends on Phase 1 + Phase 2 gates (pure services). Config-audit integration also depends on Phase 3. Requirements covered: R06, R07.

## Goal
GUI mutations become fail-closed auditable (intent-before-action + correlated outcome), with qualified anchor verification and evidence export; reporting reads the trail read-only and never over-claims compliance.

## Honesty constraints (write these into the docs)
- Hash-chained audit is tamper-EVIDENT for a careful auditor, not non-repudiable. Local admin can rewrite the log and recompute a chain; Event Log/File anchors are surviving-anchor detection only.
- State the CURRENT implemented reality at the time of the target's release notes.

## Inputs
Donor (read-only):
- `src\Wuu.Audit.psm1` (session/record/canonical JSON/SHA-256 chain/locked append/audit paths; Test-WuuAuditAnchor; Test-WuuAuditAnchorData; Get-WuuAuditEventLogAnchor; Test-WuuAuditEventLogAnchor; transcript capture)
- `src\Wuu.Reporting.psm1` (ConvertTo-WuuReportWindow, Get-WuuAuditHistory, Get-WuuDeploymentReport; batch-level success + target-level failure distinction)
- `src\Wuu.Result.psm1` (versioned JSON envelope used by export/manifest)
- `src\Wuu.Command.psm1` — the audit SUB-VERB slice only, for behaviour reference. Do NOT port the CLI parser/console.
- `tests\Test-AuditTrail.ps1`, `Test-AuditAnchoring.ps1`, `Test-AuditConcurrency.ps1`, `Test-Reporting.ps1`
Target:
- `src\Wuu.Core.psm1` (action handlers — every mutating action needs audited wrap), new `src\Wuu.Audit.psm1`, `src\Wuu.Reporting.psm1`

## Tasks

### T017 [R06] Audit primitives in the GUI
- [ ] Add `src\Wuu.Audit.psm1` transplanting the donor's audit engine: canonical-JSON records, daily JSONL under `%PROGRAMDATA%\WUU2\audit` (LocalAppData fallback; never a synced folder), SHA-256 chain (canonical record + prevHash), locked whole read/compute/append, UTF-8 no-BOM, categories (session/access/configuration_change/data_change/operational/outcome).
- [ ] Classify each action: target mutation / local config or inventory mutation / read-only access / authorization denial / outcome. A cancelled or denied review does NOT imply a mutation occurred.
- [ ] Expose start-session / write-record / audited-action primitives; confirm the actual exported names rather than guessing. The audited wrapper consumes a UI-INDEPENDENT confirmed-request + reason contract (T022 supplies the production dialog later; use a stub request provider here).
- [ ] Wire every GUI mutating action through the audited wrapper: a fail-closed INTENT record appended BEFORE execution (a failed intent write BLOCKS the action); a correlated best-effort OUTCOME record follows. Accepted/refused/outcome records retain stable request/operation correlation; an audit admission refusal is NOT a machine failure.
- [ ] Required non-empty Reason: automated/internal follow-ups carry the initiating reason/correlation rather than reopening prompts; internal auto-recovery service changes are in-scope mutations (prior authorised scope) or refused.
- [ ] Read operations (show/report/export) are logged best-effort and NEVER block on a logging failure; reads never carry mutation intent.
- [ ] Secrets never enter the trail: assert no password/credential material is recorded.
Pass criteria: intent-before-action proven (kill-order probe); failed audit device blocks mutation; read logging degrades; secrets-negative assertions pass.

### T018 [R06] Anchoring, verification, export — headless services + GUI adapter
- [ ] Port Test-WuuAuditAnchorData (seq+head-hash comparison; unchanged / valid append / truncation / same-length replacement) plus file + Event Log anchor readers/writers.
- [ ] `Wuu.Audit` OWNS the headless verify/anchor/export services; `Wuu.Gui` owns the WPF actions/rendering that call them. Define the export schema/version contract here (via `Wuu.Result` or an existing suitable utility); do NOT call CLI Command rendering.
- [ ] Evidence bundle: matching-day captured diagnostics + matching external anchor + `evidence-manifest.json` with SHA-256 entries EXCLUDING itself, BOM-less, via the versioned JSON envelope. Include only evidence ACTUALLY captured; WPF actions are not auto-recorded by a terminal transcript — mark missing diagnostic capture explicitly and never fabricate transcripts or durations.
- [ ] Combined verdict: a chain that verifies clean but whose anchor says REWRITTEN still reports failure; a valid prefix + legitimate appends passes.
- [ ] Report missing/unconfigured/unavailable anchor explicitly and distinctly from tamper; never invent provenance.
Pass criteria: synthetic day-1/append/rewrite fixtures produce CorrectOk / append-accepted / rewrite-failed verdicts; manifest excludes itself; BOM-less files.

### T019 [R07] Read-only reporting surface (pure aggregation)
- [ ] Add `src\Wuu.Reporting.psm1` transplanting Get-WuuAuditHistory + Get-WuuDeploymentReport with the donor's correctness rules: batch-level success vs TARGET-level failure (no fabricated per-machine success rate); a refusal is never a machine failure; refused-vs-failed kept separate; malformed lines counted and skipped; 'declined' not folded into 'denied'.
- [ ] Functions return PLAIN report/view-model data, not WPF controls/brushes. Aggregation never changes the source trail.
- [ ] Build the WPF report models here (Phase 5 renders them); durations only where recorded; do not infer bottlenecks or per-machine compliance from absent per-target data. Optional best-effort access logging belongs to the UI/service wrapper and is EXCLUDED from report outcome counts.
Pass criteria: port `Test-Reporting.ps1` cases against the GUI module with a synthetic JSONL log.

## Phase 4 gate
All of: intent-before-action verified; anchor rewrite fails combined verdict while valid append passes; export manifest correct; report never mutates the trail; batch/target levels and refusal semantics proven. Document the tamper-evidence limitation in the GUI docs honestly.
