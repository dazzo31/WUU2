# WUU2 — Provenance, Lineage, and Attribution

This document records the development lineage of **WUU2 (GUI Edition)**, tracing its origin from earlier open-source PowerShell patch management tools, documenting all copyright holders, and detailing how the codebase evolved from early scripts into an enterprise utility.

---

## 1. Lineage Overview

`mermaid
flowchart TD
    PoshPAIG["1. PoshPAIG (2011–2014)<br>Author: Boe Prox<br>Original: CodePlex / GitHub (proxb/PoshPAIG)<br>License: MIT (2014)"]
    WUU["2. Windows Update Utility / WUU (2016)<br>Author: Tyler Siegrist<br>Publication: TechNet Script Center / GitHub<br>Lineage: Rewrite of PoshPAIG"]
    WUU2_ORIG["3. WUU2 (2018)<br>Assembler: HanSolo71<br>Fixes: Phaere<br>License: MIT (2018)"]
    WUU2_GUI["4. WUU2 — GUI Edition (2025–2026)<br>Author: dazzo31<br>Repository: dazzo31/WUU2<br>License: MIT"]

    PoshPAIG -->|Rewrote into unified script + native WUA COM API| WUU
    WUU -->|Forum bug fixes applied & GitHub repository created| WUU2_ORIG
    WUU2_ORIG -->|Phases, credentials, CIM/DCOM, scheduled tasks, deadlock fixes| WUU2_GUI
`

---

## 2. Upstream Projects and Authors

### Stage 1: PoshPAIG (2011–2014)
* **Author:** Boe Prox
* **Repositories:** CodePlex (poshpaig.codeplex.com, archived) and GitHub ([proxb/PoshPAIG](https://github.com/proxb/PoshPAIG))
* **License:** The MIT License (MIT), Copyright (c) 2014 Boe Prox
* **Historical Context:**
  PoshPAIG (PowerShell Patch Audit/Installation GUI) was created by Boe Prox in mid-2011 to simplify Windows update management across remote servers. Featured on Microsoft’s *"Hey, Scripting Guy!"* blog in August 2011, it introduced multi-threaded background runspaces for patch auditing, host exemption lists (Exempt.txt), and remote patch execution.

### Stage 2: Windows Update Utility (WUU) (2016)
* **Author:** Tyler Siegrist
* **Publication:** Microsoft TechNet / Script Center (ID 1d72e520, December 14, 2016) and GitHub ([HashGambit97/WindowsUpdateUtility](https://github.com/HashGambit97/WindowsUpdateUtility))
* **License:** MIT-compatible permissive release acknowledging PoshPAIG
* **Historical Context:**
  Tyler Siegrist completely re-architected PoshPAIG into a unified ~1,100-line script (WUU.ps1) accompanied by XAML files (WUU.xaml, OUPicker.xaml). Rather than generating temporary VBScripts as early PoshPAIG versions did, WUU interacted directly with the Windows Update Agent (WUA) COM APIs (Microsoft.Update.Session, Microsoft.Update.UpdateColl) and established the classic operational scriptblocks: $GetUpdates, $DownloadUpdates, $InstallUpdates, $RestartComputer, $RemoveOfflineComputer, and $WUServiceAction.

### Stage 3: WUU2 (2018)
* **Maintainer:** HanSolo71
* **Contributor:** Phaere (TechNet Script Center community)
* **Repository:** GitHub ([HanSolo71/WUU2](https://github.com/HanSolo71/WUU2))
* **License:** MIT License, Copyright (c) 2018 HanSolo71
* **Historical Context:**
  HanSolo71 collected community fixes posted by Phaere on the TechNet discussion forums (addressing runspace variable isolation, COM casting issues, and UI binding glitches), packaged them into a git repository, and published the project under the MIT License on October 28, 2018.

### Stage 4: WUU2 GUI Edition (2025–2026)
* **Author:** dazzo31
* **Repository:** [dazzo31/WUU2](https://github.com/dazzo31/WUU2)
* **License:** MIT License, Copyright (c) 2025-2026 dazzo31
* **Historical Context:**
  dazzo31 overhauled the application for enterprise stability:
  * Eliminated UI thread deadlocks between WPF dispatchers and background runspaces.
  * Introduced 5-wave phased deployment automation with automated phase gates.
  * Added custom credential management via DCOM CIM sessions ([pscredential]).
  * Replaced PsExec execution with temporary SYSTEM scheduled tasks reporting progress through the registry (HKLM:\SOFTWARE\WUU2\Jobs).
  * Built the WSUS audit engine (Audit-WSUSUpdates.ps1).

---

## 3. Licensing and Legal Compliance

All source projects in this lineage are licensed under the **MIT License**.

Because the MIT License requires that the copyright notice and permission notice be preserved in all copies or substantial portions of the software, LICENSE preserves the complete attribution chain:

`	ext
Copyright (c) 2014 Boe Prox (PoshPAIG)
Copyright (c) 2016 Tyler Siegrist (Windows Update Utility)
Copyright (c) 2018 HanSolo71 (WUU2)
Copyright (c) 2025-2026 dazzo31 (WUU2)
`

There are no copyleft restrictions (such as GPL), proprietary software components, or viral licensing terms anywhere in the codebase.

---

## 4. Code Ancestry and Transformation Matrix

| Component / Subsystem | Ancestral Origin | Status in WUU2 | Transformation Details |
| :--- | :--- | :--- | :--- |
| **Runspace collections** (`$jobs`, `$jobCleanup`, `$updatesHash`) | PoshPAIG (2014) | Refactored | Migrated from monolithic script variables into structured modules (`Wuu.State`, `Wuu.WindowsUpdate`, `Wuu.Workers`). |
| **Exemption filter** (`Exempt.txt`) | PoshPAIG (2014) | **Retired** | Exemption list placeholder file and packaging inclusion retired; fleet management belongs in structured configuration, not an untracked local text file. |
| **Elevation check** | PoshPAIG (2014) | Preserved | Requires elevated administrative session for local and remote operations. |
| **PsExec remote execution** | PoshPAIG (2014) / WUU (2016) | **Replaced** | Replaced by temporary SYSTEM scheduled tasks registered over WMI/DCOM. |
| **WUA COM query engine** (`Microsoft.Update.Session`) | WUU (2016) | Evolved | Direct descendant of Tyler Siegrist's WUA COM search logic; now wrapped in structured timeouts and runspace isolation. |
| **Worker payloads** (`$GetUpdates`, `$DownloadUpdates`, `$InstallUpdates`) | WUU (2016) | Evolved | Operational bodies descend from WUU/WUU2 scriptblocks, now coordinated through `Wuu.State` and `Wuu.Workers`. |
| **GUI / XAML interfaces** (`MainWindow.xaml`, `OUSelector.xaml`) | WUU (2016) | Evolved | Modernized WPF XAML layouts separated from logic modules into `ui/`. |
| **Phased deployments** (5 waves) | WUU2 (2025) | Active | Controls wave progression across computer fleets. |
| **WSUS update audit** | WUU2 (2025) | Active | Implemented via `Scripts/Audit-WSUSUpdates.ps1`. |
| **DCOM CIM sessions & credentials** | WUU2 (2025) | Active | Secure credential caching and remoting without requiring WinRM listeners for update queries. |
| **State machine & funnel** (`Wuu.State`) | WUU2-CLI (2026) | **Transplanted** | Headless state store with identity fencing, admission lock, and invariant verification. |
| **Configuration core** (`Wuu.Configuration`) | WUU2-CLI (2026) | **Adapted** | Single-sourced target version constant (`v1.3.4`) and defaults policy. |