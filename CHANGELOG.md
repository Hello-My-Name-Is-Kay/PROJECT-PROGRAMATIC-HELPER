<!-- SUMMARY: VmMaintenance release history. SECTIONS: 2.9.0 - 2026-11-14:4-16 | 2.8.0 - 2026-11-14:17-30 | 2.7.0 - 2026-11-14:31-48 | 2.6.0 - 2026-11-14:49-56 | 2.5.0 - 2026-11-14:57-69 | 2.4.0 - 2026-11-14:70-80 | 2.3.0 - 2026-11-14:81-95 | 2.2.1 - 2026-11-14:96-102 | 2.2.0 - 2026-11-14:103-110 | 2.1.0 - 2026-11-14:111-128 | 2.0.0 - 2026-11-14:129-134 | 1.0.0 - 2026-11-14:135-139 -->
# Changelog

## 2.9.0 - 2026-11-14

- Agent health, not only "installed": for Qualys, CrowdStrike, Zabbix, Ivanti and the Lansweeper agent the
  Extractor, the RDP collector and the fleet check now report OK / WARN / FAIL with the version and the reason.
  FAIL: not installed, service not running, required kernel driver not running (CrowdStrike `CSAgent`).
  WARN: start type not Automatic, port not listening (Zabbix 10050; from the laptop: not reachable), agent log
  not written for `Agents.LogMaxAgeHours` (48; Qualys), version below `Agents.MinVersion.<Agent>`.
- Version from Programs and Features, else from the service executable.
- One set of rules (`Get-AgentVerdict` in the Extractor) used on the host and from the laptop. What is checked
  per agent is in `Resources\InventoryFields.psd1` (`Agent = @{ Products; Drivers; Ports; Log }`).
- Shown in the inventory columns (`OK - Running, v7.16...`), `vmm agents [-Problems]`, `A` on a host, the fleet
  check table; a FAIL agent makes the host health Warn (`Agents.AffectHealth`).

## 2.8.0 - 2026-11-14

- SQL Server updates fetched for you: `vmm fetch` (or `F` on the staging screen) works out, per SQL instance, the
  service pack and/or CU it needs (SP first when the target CU belongs to a newer SP) from the last check and the
  dbatools build reference; `-Preview` shows the plan only. `SqlUpdates.MaxBehind` (e.g. `1CU`) relaxes "latest".
- Downloaded once: each KB goes into a cache on the share (`<share>\_Downloads\SQL\<KB>`, setting
  `Downloads.CacheFolder`), is kept only with a valid Microsoft signature, gets a `.sha256`, and is then copied
  into every host folder that needs it. Next time it is copied over the network, not downloaded. A host folder
  that already has a file with that KB number is left alone. Folders starting with `_` are not host folders.
- Language: service packs before SQL 2017 come per language; the check now reads each instance's install
  language (falls back to the OS language). CUs are one file for all languages.
- Nothing is installed by vmm. The Windows Server ISO stays a manual download (licensed media has no API).
  Needs dbatools once: `Install-Module dbatools -Scope CurrentUser`.

## 2.7.0 - 2026-11-14

- Live log on every screen: the bottom rows of each menu show the newest log lines as they happen
  (`Log.PaneLines`, default 6). `F2` shows/hides it on any screen (remembered as `Log.Live`, `--no-log` for one
  run), `F3` opens the full log, `L` in the main menu too.
- Long operations say what they are doing: the fleet check logs each host's step (DNS, ping, ports, WMI, SQL,
  licence query, services, software), each finished host with its time, and every `Log.HeartbeatSeconds` (5)
  how many are done and which hosts have been running longest. Staging copies show MB, speed and time left;
  Azure jobs (snapshots, resize) say what they are still waiting on.
- Everything goes to a day log `logs\vmm_<date>.log` (every line, the result of each action with its duration,
  the tables an action printed, CLI commands), masked for secrets and encrypted per line with the store key.
  `vmm log` reads it (`-Follow` live in a second window, `-Level`, `-Find`, `-Date`, `-List`, `-Export` plaintext
  copy). Kept `Log.KeepDays` (30) days.
- Maintenance tools (`M`, `vmm maint`): diagnose (versions, settings, data key, store, backups, logs, leftovers,
  gh/Az, disk, console size), check the fleet store, back up / list / restore it, clean logs and temp files,
  log options, reset the UI. One encrypted store backup is made per day at start (`Maintenance.AutoBackup`,
  14 kept).

## 2.6.0 - 2026-11-14

- New machines from external data: CSV with hostname or FQDN, domain, IP (`,` `;` or tab, header optional, any
  column order with a header). Preview, add new hosts, fill empty values of existing ones (`-Update` replaces).
- Menu `0`: drag the file or Enter for a file dialog, preview, confirm, optionally delete the plaintext file.
- Fleet check connects by the imported FQDN and falls back to the imported IP when the name does not resolve;
  staging and `L` (mstsc) use the FQDN too. Domain and IP feed the inventory.

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

_Last updated: 2026-11-14 13:07 UTC_
