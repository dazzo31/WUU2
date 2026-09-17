# WSUS Update Audit Tool

## Overview
This tool provides accurate reporting of WSUS-approved updates and helps identify discrepancies between WSUS approval status and what Windows Update reports.

## Files Added

### 1. `Scripts/Audit-WSUSUpdates.ps1`
Standalone diagnostic script that audits WSUS update configuration and counts.

**Usage:**
```powershell
# Run on local machine
.\Scripts\Audit-WSUSUpdates.ps1

# Run on remote machine
.\Scripts\Audit-WSUSUpdates.ps1 -ComputerName SERVER01

# Include hidden updates
.\Scripts\Audit-WSUSUpdates.ps1 -IncludeHidden -Verbose
```

**What it checks:**
- WSUS server configuration (registry)
- WSUS-approved updates count
- Standard Windows Update search count
- Update download status
- Reboot required state
- Windows Update service status
- Recent update history
- WSUS client log files

### 2. Integrated WSUS Audit in WUU.ps1
Right-click context menu option: **"Audit WSUS Updates"**

**Location:** Right-click computer in list → Audit WSUS Updates

**What it shows:**
- WSUS server URL (if configured)
- Update counts from different search queries:
  - Standard Search (IsInstalled=0 and IsHidden=0)
  - Including Hidden Updates
  - WSUS-Assigned Updates (IsAssigned=1)
- Downloaded vs Not Downloaded breakdown
- Reboot required status
- Detailed update list in GridView

## Why WSUS Updates May Not Match Windows Update Count

### Common Scenarios:

1. **MSRT (Malicious Software Removal Tool)**
   - Not returned by Windows Update COM API
   - Managed separately by Microsoft Defender
   - Will show in Windows Settings UI but not in WUU

2. **Hidden Updates**
   - WSUS may approve updates that are hidden on the client
   - Use `-IncludeHidden` parameter to see these

3. **Already Downloaded/Installing**
   - Updates in "Installing" state may not appear in searches
   - Check update history for in-progress installations

4. **WSUS Synchronization Issues**
   - Client hasn't checked in with WSUS recently
   - Run `wuauclt /detectnow` or `usoclient StartScan`
   - Check WSUS server approval status

5. **Different Update Categories**
   - Some updates (Defender definitions, MSRT) use separate channels
   - Not all "updates" are Windows Update agent updates

## Troubleshooting Steps

### If WSUS-approved updates are missing:

1. **Verify WSUS Configuration**
   ```powershell
   Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUServer"
   ```

2. **Force WSUS Detection**
   ```powershell
   wuauclt /detectnow
   # or
   usoclient StartScan
   ```

3. **Check Windows Update Service**
   ```powershell
   Get-Service wuauserv
   ```

4. **Review Update History**
   - Use "Show Update History" in WUU
   - Look for failed installations or errors

5. **Clear Windows Update Cache**
   ```powershell
   net stop wuauserv
   Remove-Item -Path "$env:WINDIR\SoftwareDistribution\*" -Recurse -Force
   net start wuauserv
   ```

6. **Check WSUS Server**
   - Verify updates are approved for the computer's group
   - Check WSUS synchronization status
   - Review WSUS server logs

## Update Search Queries Explained

| Query | Purpose | Includes |
|-------|---------|----------|
| `IsInstalled=0 and IsHidden=0` | Standard WUU search | Non-installed, non-hidden |
| `IsInstalled=0` | Include hidden | All non-installed updates |
| `IsInstalled=0 and IsAssigned=1` | WSUS-specific | Only WSUS-assigned updates |
| `IsInstalled=1` | Installed updates | Already installed updates |

## Known Limitations

1. **MSRT (Malicious Software Removal Tool)**
   - Not detectable via Windows Update COM API
   - Will always be 1 less than Windows Settings UI when MSRT is pending

2. **Defender Platform Updates**
   - May use separate update mechanism
   - Sometimes not visible in COM API results

3. **Feature Updates**
   - Large feature updates may appear differently
   - Check "IsMandatory" property for required updates

## Example Output

```
=== WSUS Update Audit Tool ===
Target: SERVER01
Date: 09/10/2026

1. WSUS Configuration Check:
   WSUS Server: 3 (WSUS)
   Update Source: 34a36e8c-50d4-46d3-9b16-0b1d5a7e3d1b
   WSUS URL: http://wsus.contoso.com:8530
   WSUS Status: http://wsus.contoso.com:8530

2. WSUS-Approved Updates (IsInstalled=0):
   Search Query: IsInstalled=0 and IsHidden=0
   Total Found: 3
   Updates:
     - SQL Server Management Studio [NOT DOWNLOADED]
     - 2026-09 Cumulative Update for .NET Framework [DOWNLOADED]
     - Update for Microsoft Defender Antivirus Platform [NOT DOWNLOADED]

3. WSUS-Specific Search (IsAssigned=1):
   Assigned Updates Found: 3

4. Reboot Status:
   Reboot Required: True

5. Windows Update Service Status:
   Service: Running
   Startup: Automatic

=== Summary ===
This tool shows WSUS-approved updates visible to the Windows Update Agent.
```

## Integration with WUU Workflow

1. **Check for Updates** → Shows standard count
2. **Audit WSUS Updates** → Verifies WSUS approval and counts
3. **Compare Results** → Identify discrepancies
4. **Troubleshoot** → Use diagnostic steps above
5. **Download/Install** → Proceed with WSUS-approved updates

## Best Practices

- Run WSUS audit **before** downloading updates to verify approval status
- Use the standalone script for detailed diagnostics
- Use the integrated tool for quick checks during normal operations
- Document any discrepancies for WSUS administrator review
- Clear Windows Update cache if counts seem inconsistent

## Support

For WSUS-specific issues:
- Check WSUS server event logs
- Review client WindowsUpdate.log
- Verify network connectivity to WSUS server
- Check WSUS client group membership
- Confirm update approval and target group assignment
