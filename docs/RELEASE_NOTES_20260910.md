# WUU2 Release Notes - 2026-09-10

## Summary
Investigation and resolution of the update-count discrepancy between WUU and the Windows Settings UI, plus a new WSUS audit capability.

## Update Count Discrepancy - Explained (Not a Bug)
Windows Settings can show one more pending update than WUU when a **Malicious Software Removal Tool (MSRT)** release is pending.

**Root cause:** MSRT is delivered outside the Windows Update Agent (WUA) update store. It is not returned by any WUA search (`IsInstalled=0`, including hidden), and `Title` is not valid WUA search criteria (attempting it returns `0x80240032 WU_E_INVALID_CRITERIA`). No WUA-based tool can see or count MSRT.

**Resolution:** WUU intentionally reports only WUA-visible updates. A code comment now documents this limitation at the point where counts are calculated. MSRT installs automatically via Windows Update regardless.

## What's New

### WSUS Audit (right-click → "Audit WSUS Updates")
- Shows configured WSUS server (registry policy)
- Compares counts across search criteria: standard, including hidden, WSUS-assigned (`IsAssigned=1`)
- Downloaded vs not-downloaded breakdown, reboot state
- Detailed update list in GridView

### New Scripts
- `Scripts/Audit-WSUSUpdates.ps1` - standalone WSUS/update-state diagnostic
- `Scripts/Diagnostic-FindMissingUpdates.ps1` - compares WUA search results across criteria
- `Scripts/Validate-Release.ps1` - validates XAML load and event-handler/control wiring

## Validation Performed
- All PowerShell scripts pass the PS 5.1 language parser
- WUU.xaml and OUPicker.xaml load via XamlReader (STA)
- Every control wired with an event handler in WUU.ps1 resolves via FindName (36 controls checked)
- Confirmed `Title like` criteria is rejected by WUA (hence removal of the earlier MSRT-detection attempt)

## Compatibility
- Windows PowerShell 5.1+ (STA, elevated), PowerShell 7 compatible patterns preserved
- Windows 10/11, Windows Server 2016+
