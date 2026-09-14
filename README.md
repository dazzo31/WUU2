# WUU2

Windows Update Utility (WUU) — GUI tool for checking/downloading/installing Windows Updates on remote machines.

This repo is a consolidated/fixed version of the original Windows Update Utility by Tyler Siegrist (PoshPIAG/TechNet) with additional reliability and compatibility improvements.

## Prerequisites

- Windows PowerShell 5.1 (recommended for best WPF compatibility). PowerShell 7+ may work but WPF/AD features can be more limited depending on system components.
- Run as Administrator (required for full functionality).
- PowerShell must run in STA mode (required for WPF): `powershell.exe -STA`.
- PsExec must be available in the repo folder as `psexec.exe`.
	- Download: https://docs.microsoft.com/en-us/sysinternals/downloads/psexec
	- If missing, the script can prompt to download PsTools automatically.

## Run

From an elevated PowerShell prompt in the repo folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WUU.ps1
```

## Key files

- `WUU.ps1` — main script
- `WUU.xaml` — main UI layout
- `OUPicker.xaml` — OU picker UI
- `ComputerList.config` — saved computer lists (if used)
- `Exempt.txt` — host exemptions (if used)
- `Scripts\` — helper scripts

## Packaging (zip)

Use `Scripts\Package-WUU2.ps1` to generate a zip containing the runnable files + docs.

## Credits / upstream

- Original project: https://gallery.technet.microsoft.com/scriptcenter/Windows-Update-Utility-WUU-1d72e520
