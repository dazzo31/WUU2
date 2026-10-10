# Phase 3 — Cross-Edition Shared Computer-List Config (T014-T016)

Binding validation corrections: read `docs/tasks/validation.md`, section 'Phase 3 Corrections', before execution. Those corrections supersede conflicting instructions below: port headless storage only, keep WPF dialogs, place safe replacement in the storage writer, validate schema strictly and report ambiguous decryption failure honestly rather than promise corruption/password discrimination.

Status: proposed. Depends on Phase 1 gate PASS. May run in parallel with Phase 2 only on distinct files (this phase owns `src\Wuu.Credentials.psm1` config functions; Phase 2 owns the credential resolver — sequence edits to avoid churn). Requirements covered: R04, R05.

## Goal
WUU2 and WUU2-CLI read and write the SAME named-list encrypted computer-list file, with non-destructive legacy migration. Shared FORMAT, never simultaneous writers.

## Inputs
Target:
- `src\Wuu.Credentials.psm1` (Protect-ComputerListData ~L543, Unprotect ~L576, Save-ComputerListConfig ~L609, Import-ComputerListConfig ~L658) — currently FLAT v1 single-list.
- `src\Wuu.Core.psm1` (`$eventSaveConfig` ~L3894 / `$eventLoadConfig` ~L3929 — flat save/load via GUI password dialog).
- `src\Wuu.Core.psm1` Show-PasswordPrompt ~L534 (existing fast WPF dialog).
Donor (read-only):
- `src\Wuu.Credentials.psm1` (`$script:WuuDefaultListName`; Protect/Unprotect-ComputerListData; Save-ComputerListConfig; Write-WuuConfigFile; Read-WuuConfigFile; Get-WuuComputerListNames; Import-ComputerListConfig; New-WuuComputerListPrompt; Test-WuuPasswordMatch; Confirm-WuuPasswordPrompt)
- `tests\Test-ComputerLists.ps1` (v1/v2 round trip, wrong-passphrase, overwrite refusal, chooser)
NOTE: persistence lives in `Wuu.Credentials`, NOT `Wuu.Session`. `Wuu.Session` handles computer-set/name parsing; do not copy the CLI acquisition workflow or its console prompts.

## Decisions (binding)
- Schema: `wuu.computerlist.v2` — `{ Schema; SavedDate; Lists:[ { Name; SavedDate; ComputerCount; Computers:[{Computer;Phase}]; CredentialConfig } ] }`. Only Computer+Phase per row; transient status is never saved. CredentialConfig carries MODE + username only, never a password.
- Keep the EXISTING wire crypto (SHA256(password)-keyed SecureString serialization via `ConvertFrom/To-SecureString -Key`) for interop. Do NOT change the crypto format in this uplift; document it honestly as legacy passphrase encryption, not PBKDF2/authenticated encryption.
- BOM-less UTF-8 on disk.
- A v1 flat file reads as a list named 'default' and is NOT rewritten on read; upgrading to v2 happens only on an explicit save.
- Simultaneous cross-edition saves are NOT supported. Sequential saves OK. Do not claim a GUI-side lock makes concurrent writers safe.

## Tasks

### T014 [R04][R05] Port the headless storage functions (writer owns safety)
- [ ] In `src\Wuu.Credentials.psm1`, port HEADLESS storage only: Protect/Unprotect-ComputerListData, Read-WuuConfigFile, Write-WuuConfigFile, Get-WuuComputerListNames, Import-ComputerListConfig (ListName-capable), Save-ComputerListConfig (named list, `-AllowOverwrite`), Test-WuuPasswordMatch. Add `$script:WuuDefaultListName='default'`. Do NOT port console prompt workflows.
- [ ] `Save-ComputerListConfig`: decrypt existing file via Read-WuuConfigFile so OTHER lists survive; refuse un-asked same-name overwrite (return `Exists=$true`); wrong passphrase changes NOTHING; merge then write via Write-WuuConfigFile.
- [ ] `Write-WuuConfigFile` owns: encrypt to temp file, protected backup of a legacy file before explicit upgrade, safe same-volume replacement, rollback on failure, temp cleanup. No second writer in GUI handlers.
- [ ] `Read-WuuConfigFile`: strict v2 `Schema`/shape validation; legacy only by documented shape; unknown/malformed -> unreadable (never 'empty fleet'). Report decryption failure honestly as 'incorrect passphrase or damaged file' when corruption and wrong password cannot be separated.
- [ ] Remove the old flat Save/Import implementations (replace, do not leave two competing writers).
Pass criteria: module round-trips v1 and v2 headless in-memory; fault injection proves the original file survives encryption/write/replace failure.

### T015 [R05] Rewire GUI save/load handlers to named lists
- [ ] `$eventSaveConfig`: keep GUI Show-PasswordPrompt; NEW passphrase confirmed twice ONLY when the file would be created; ask for a ListName (default 'default'); if the name exists require confirmation -> `Save-ComputerListConfig -AllowOverwrite`.
- [ ] `$eventLoadConfig`: read list names via Get-WuuComputerListNames after authentication; present a chooser (number / exact name / unambiguous prefix) reusing a GUI list dialog; single-list file loads directly; import the chosen named list. Stage the entire load before committing to the engine inventory under the state protocol.
- [ ] Every failure/cancel leaves the current file and the current fleet UNCHANGED.
- [ ] A malformed/truncated/unknown-schema file is reported as unreadable, NEVER treated as "empty fleet."
Pass criteria: save-cancel adds nothing; wrong password changes nothing and is reported truthfully; same-name save requests confirmation; legacy file reads as 'default' and is only rewritten on explicit save with backup.

### T016 [R05] Cross-edition conformance tests (separate processes)
- [ ] Create `tests\Test-ConfigInterop.ps1`: each run uses a SEPARATE powershell.exe process importing EITHER the target OR donor `Wuu.Credentials` (assert the loaded module path first).
- [ ] Cases: GUI-write -> CLI-read; CLI-write -> GUI-read; two named lists coexist and saving one preserves the other; default selection on unattended load; duplicate names collapse case-insensitively with first spelling winning; blank/whitespace lines; empty list; single-element list keeps `.Count`; 500-computer list; Unicode names; wrong passphrase; unknown/corrupt bytes; rollback leaves original intact.
- [ ] Assert NO transient/operation fields (OperationId/OpState/PendingOp/Status/heartbeat) in the saved document.
Pass criteria: all interop cases pass in BOTH directions with fresh processes, and no secrets/transient fields appear in the artefact.

## Phase 3 gate
Bidirectional compatibility proven; legacy migration non-destructive with backup; no concurrent-write support claimed. Reporting of Phase 3 completion must name the crypto format honestly.
