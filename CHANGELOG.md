<!-- SUMMARY: VmMaintenance release history. SECTIONS: 2.13.0 - 2026-11-15:4-33 | 2.12.0 - 2026-11-14:34-56 | 2.11.0 - 2026-11-14:57-75 | 2.10.0 - 2026-11-14:76-94 | 2.9.0 - 2026-11-14:95-107 | 2.8.0 - 2026-11-14:108-121 | 2.7.0 - 2026-11-14:122-139 | 2.6.0 - 2026-11-14:140-147 | 2.5.0 - 2026-11-14:148-160 | 2.4.0 - 2026-11-14:161-171 | 2.3.0 - 2026-11-14:172-186 | 2.2.1 - 2026-11-14:187-193 | 2.2.0 - 2026-11-14:194-201 | 2.1.0 - 2026-11-14:202-219 | 2.0.0 - 2026-11-14:220-225 | 1.0.0 - 2026-11-14:226-230 -->
# Changelog

## 2.13.0 - 2026-11-15

- Hands-on staging over remote desktop, with checks. When the Stage step cannot copy to a host from the terminal
  (admin share closed, access denied, broken copy), it offers to go on by hand (`Handoff.Offer = Ask | Always |
  Never`). Not offered when RDP cannot help: files missing on the share, share or VPN down, credential prompt
  cancelled, or nobody at the keyboard. Also on its own: `T` on a host or on the Stage guide, `vmm handoff -HostName x`.
- The handoff asks which client to use: **RDP** (mstsc with a one-off `.rdp` file: clipboard on, only the needed
  drive shared), **RDM** (Devolutions Remote Desktop Manager quick connect, `/Template:RDP /Host:<host>`,
  `Handoff.RdmTemplate`, optional `Handoff.RdmDataSource`), **RDCMan** (a one-off `.rdg`) or none. Clients are
  found in App Paths, Program Files and PATH, or set with `Handoff.RdmPath` / `Handoff.RdcManPath`; a missing one
  is listed with the reason. No user name or password is passed to any client or saved.
- It puts a short script on the clipboard for the host (PowerShell 2.0+). The script writes only in
  `Staging.TargetFolder` (`C:\Temp`): creates it, copies each missing file from the share, else from this laptop
  over `\\tsclient` (optional outbox, `Handoff.Outbox`), reads size and SHA256 on the host and puts a one-line
  `VMMSTAGE1` report on the clipboard. It lists every file with size and SHA256 for copying by hand.
- Back in vmm, `V` verifies: the `VMMSTAGE1` report (clipboard or `P`), else WinRM (hash read on the host), the admin
  share, then WMI (size only). Stage becomes `Success` only when every file is right, with a note saying it was done
  by hand and how it was verified; otherwise it says which file is missing or wrong and nothing is recorded. A known
  SHA256 must be read on the host unless `Handoff.AcceptSizeOnly = $true`. `vmm handoff -VerifyOnly` or `-Report`
  checks later without a session.
- Same rules as Stage: client OS refused without an order, and in business hours only into `C:\Temp`. Every step,
  answer and per-file result goes to the day log.
- `vmm rdp -HostName x` opens RDP / RDM / RDCMan for a host (`L` on the host and guide screens now asks which);
  `vmm rdp -List` shows which clients this laptop has. Client OS hosts are refused without an order.
- The `.rdp` / `.rdg` files and the host script are removed when the handoff ends; `vmm maint -Action CleanTemp`
  also empties leftover handoff files and vmm's own outbox after a day.
- Settings screen and `config.example.psd1`: new `Handoff` section. README, USAGE, WORKFLOW and SECURITY updated.
- Tests: smoke section 8 (`.rdp` / `.rdg` text, client detection, `VMMSTAGE1` parsing and comparison, the host
  script run end to end on a temp folder) and Pester `RDP / RDM handoff`.

## 2.12.0 - 2026-11-14

- One vmm at a time. The console and every command that can change something take a lock on the data folder
  (`vmm.lock`, an exclusive open file; the system drops it when the process ends, so a crash leaves nothing
  stale). A second vmm stops with `VmmInstanceLocked` (exit code 6) and names the process, start time and
  command that hold it. Read-only commands still run beside a busy vmm: `log`, `status`, `plan`, `time`,
  `progress`, `vpn`, `guide`, `agents`, `media`, `github`, `policy`, `inventory`, `config`, `stage`. Saving
  the fleet store takes the same lock, so module functions called by hand are covered too.
- The CLI logs every command to the encrypted day log: the command line (option names only), the tables and
  objects it printed (level `Output`, masked), the result with its duration, or `FAILED` with the message
  and error id, and the exit code. Before, `vmm status`, `vmm plan`, `vmm agents` and other table commands
  left nothing in the log, and a failed command only reached `errors.log`.
- `Out-VmmHost` replaces `Out-Host` everywhere: what a screen or command shows as a table is also in the log.
- The one-task scripts in `Scripts\` log their name and their error to the day log.
- Trace lines for work that was silent: media inventory scan, staging hash check, Lansweeper query, Resource
  Graph query.
- A one-line footer after CLI commands that take a second or more: duration and where the log is.
- Theme: deeper iceberg blue. The background is a blue-black (4,16,27) instead of black, text and hints are
  ice-tinted, the top bar and selected row are a stronger deep iceberg (24,92,138), the key bar is deep blue,
  section titles and the log pane rule are iceberg. Green, orange and red are unchanged and still only mark
  statuses. The console's black is redefined while the UI runs and put back on exit; `UI.DeepBackground =
  $false` keeps a black background.

## 2.11.0 - 2026-11-14

- Theme: black, deep iceberg blue, and green / orange / red for statuses only. All colours are defined in one
  place (`Get-VmmTheme`); no screen sets a colour by hand. List rows show a one-cell status block and neutral
  text instead of a fully coloured row; the selected row and the top bar are deep iceberg blue; titles are
  iceberg; hints, headers and the key bar are grey. Info lines are plain text, warnings are orange.
- 24-bit colour when the console takes it (Windows Terminal, Windows 10+ console), else the 16 console
  colours; `UI.TrueColor` = `Auto` | `$true` | `$false`. `--no-color` still prints plain text.
- The Extractor uses the same palette in the 16 console colours (old servers).
- Main menu grouped in four sections (daily work, hosts in and out, access, this program); the cursor steps
  over section titles. Keys are unchanged.
- Security: a result from a host can no longer mark a change step (Stage, PreSnapshot, ExpandDisk, Upgrade) as
  done or record an override unless `Extractor.AllowSteps` is on. The result is encrypted to a public key that
  is inside every extractor file, so it is confidential but not proof of who wrote it. Such events are kept
  as `Ignored` history notes.
- The fleet check loads the store again after the parallel run, so a result imported meanwhile (or another
  vmm window) is not overwritten.
- Test: one version in the manifest, the Extractor, the README, PROJECT.json and the changelog.

## 2.10.0 - 2026-11-14

- Terminal first. `vmm snapshot` (menu `3`, `S` on a host) reads hosts from the laptop and tries, per host,
  DCOM (TCP 135), then WinRM (5985), then WinRM-SSL (5986); the route that answered is stored and shown.
  Before, a closed TCP 135 ended the check even when WinRM was open.
- Hands-on only where every route fails: the reason per route is listed, the Extractor is built and the steps
  are printed. `vmm access` tests the routes only. The guide (`G`) and `X` say when a host needs no hands-on.
- A failed terminal read no longer erases facts that an Extractor result brought in.
- Extractor is snapshot-only by default. The steps code sits between `VMM-STEPS-BEGIN` and `VMM-STEPS-END`
  and is cut out when the file is built, so a snapshot Extractor cannot change a host. It writes one file
  (the encrypted result on the desktop): no work folder, no log, no `icacls`. Its card carries no host name,
  share path or upgrade command. Steps return for the per-host Extractor with `Extractor.AllowSteps = true`.
- Extractor reads stand alone: a WMI class or key that fails becomes a `Problem=` line, the rest is still
  sent; the laptop shows it as a snapshot gap. Before, one failing read could stop the whole extraction.
- Snapshot no longer hashes staged multi-GB images (name check only). Pending reboot now also reads
  `PendingFileRenameOperations`, like the laptop check. `-NoClipboard` leaves the host clipboard alone.
- `Fleet.WindowsLicence = $false` skips the licence read (it wakes the Software Protection service).
- New settings: `Fleet.Routes`, `Fleet.AccessMaxAgeHours`, `Fleet.WindowsLicence`, `Extractor.AllowSteps`.

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

_Last updated: 2026-11-15 22:00 UTC_
