<!-- SUMMARY: VmMaintenance release history. SECTIONS: 2.5.0 - 2026-11-14:4-16 | 2.4.0 - 2026-11-14:17-27 | 2.3.0 - 2026-11-14:28-42 | 2.2.1 - 2026-11-14:43-49 | 2.2.0 - 2026-11-14:50-57 | 2.1.0 - 2026-11-14:58-75 | 2.0.0 - 2026-11-14:76-81 | 1.0.0 - 2026-11-14:82-86 -->
# Changelog

## 2.5.0 - 2026-11-14

- Two programs, named as used: the **Manager** (`vmm`) and the **Extractor** (the .ps1 run on a host in RDP/RDM).
- Extractor extracts as soon as it starts (no menu choice) and saves `VMM_<HOST>_<time>.vmm` (encrypted) on the
  host's desktop, plus the clipboard; refreshed after each step; Finish removes the result files too.
  Runs with right-click > Run with PowerShell; extraction needs no administrator rights.
- One Extractor for every host: `vmm extractor` / `E` > `B` (`VmmExtractor.ps1`, carries the laptop key, no plan).
  Per-host Extractor with its plan: `X` on the host (`VmmExtractor_<HOST>_<time>.ps1`).
- Manager imports result files from Desktop and Downloads (`Collect.InboxFolders`) at start, with `E`, with `P`
  on the host, or `vmm inbox`; imported files are deleted; Precheck or Verify chosen by itself.
  `vmm collect -Path <file>` for one file. The RDP collector also saves a result file on the desktop.
- Fix: an imported Extractor result with only an Export event now records Precheck/Verify.

## 2.4.0 - 2026-11-14

- Server inventory: the team's 24 columns per host (`Resources\InventoryFields.psd1`: order, headers, help text,
  agent service names). Automatic columns (domain, IP, licence, Qualys/CrowdStrike/Zabbix/Ivanti/Lansweeper agents,
  legacy TLS, domain controller, SQL) are read by the fleet check, the host agent and the RDP collector; workflow
  columns are derived; the rest is typed with a help window per column or set once as a fleet default.
- `I` on a host (Enter = help + edit, `F` fill missing, `T` help-text issue, `E` export), `N` in the main menu,
  `vmm inventory`, `vmm inventory-set`, `vmm helptext`; CSV export with the exact headers, also with every daily report.
- Setup wizard page Inventory (default technician, company, perimeter, phase, CSV separator).
- GitHub issue template "Help text change".

## 2.3.0 - 2026-11-14

- Media repository layout for `Staging.SourceShare`: Windows Server images at the root
  (`Win_Server_<version>_<LANG>.iso`, `_` or `-`, any case), one folder per host with files only that host needs
  (SQL Server updates). Each host gets the `Staging.OsMediaVersion` image in its install language plus its folder;
  no language fallback. Optional `<file>.sha256` sidecars are verified. `Staging.HostFolders` maps different folder
  names. `Staging.Layout = 'Packages'` keeps the old fixed list.
- Host install language collected by Check, the RDP collector and the host agent (`Lang`).
- `vmm media` / `4` > `M`: images by version and language, host folders vs fleet, what is still missing.
- Staging gate rows show which hosts need each file; SQL Server updates warn when the host has no instance of that version.
- RDP guide: Stage lists the host's own files; Upgrade shows how to mount the staged image.
- Installer: `VM Maintenance` shortcuts on the desktop and in the Start menu (installed copy; refreshed by updates
  unless declined at install); removed by the uninstaller.
- Fix: the host agent ignored the staged-file list in its plan (`Package=` lines were never read).

## 2.2.1 - 2026-11-14

- Setup wizard: time zone accepts cities, countries and IANA ids (Lisbon, London, Portugal, Europe/Lisbon),
  case-insensitive, with a numbered pick list when ambiguous; every question says what it accepts on a wrong
  answer, `?` shows help, choices ignore case, times like 8:00 are accepted, and after 3 wrong answers the
  current value is kept instead of looping. Set-VmmSetting and the time window accept the same names.

## 2.2.0 - 2026-11-14

- GitHub integration through the GitHub CLI (no token stored): `vmm github`, `vmm update` (checks + smoke test
  before install, rollback of the clone on failure), `vmm clone`, `vmm issue` (sanitized), `vmm pr` (leak scan first).
- Console: `U` GitHub / updates menu; update notice at start (`GitHub.CheckOnStart`).
- Installer: GitHub page in the setup wizard (sign-in offer, clone folder defaults to the install source), `-Update` mode.
- GitHub Actions: leak scan, smoke test, Pester on Windows PowerShell 5.1 and PowerShell 7; script analyzer report.

## 2.1.0 - 2026-11-14

- Host agent (`VmmHostAgent.ps1`): second program run inside RDP/RDM; status, steps with reasons,
  local runs with the same time rules, sanitized log in `C:\Temp\VmmAgent`, encrypted `VMM2` export,
  Finish removes all traces. Laptop: `vmm agent`, `X` on a host, `vmm collect` reads `VMM2`.
- VPN: Cisco Secure Client (vpncli), Windows VPN, generic probe; host work stops when the VPN is down.
- Optional AI assistant: Foundry Local / Ollama (loopback only) or Azure OpenAI with Entra ID; sanitized,
  confirm-before-send, advisory only. Future MCP design in docs/AI.md.
- Setup wizard (`vmm setup`, first run, installer): warnings, validated options per page.
- Global flags (`--no-mouse`, `--no-color`, `--config`, `--debug-errors`, `--version`), feature flags,
  exit codes, sanitized error log.
- OS policy: target Windows Server 2019; client OS (Windows 10/11) skipped unless ordered (`vmm order`);
  management warnings for Windows Server 2008 (not R2) and physical machines (`vmm policy -Notice`);
  disk expansion after hours only (no override). Policy columns in the daily report and the host agent.
- README: creator, version, date and TL;DR at the top.
- Security: SQL login no longer pre-filled from config (no usernames stored); prune respects the time window;
  stricter result import validation.

## 2.0.0 - 2026-11-14

- Fleet console: TUI (keyboard + mouse) and CLI, encrypted fleet store, Lisbon time rules with override,
  parallel checks, staging gate, blocker reports, RDP guides, checkpoint snapshots and prune,
  daily CSV/HTML/JSON, installer/uninstaller, smoke test, Pester tests.

## 1.0.0 - 2026-11-14

- Original ten scripts refactored into the VmMaintenance module, all environment values moved to local config.

_Last updated: 2026-11-14 04:53 UTC_
