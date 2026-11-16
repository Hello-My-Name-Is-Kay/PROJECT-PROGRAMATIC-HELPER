<!-- SUMMARY: VmMaintenance release history. SECTIONS: 2.15.2 - 2026-11-16:4-18 | 2.15.1 - 2026-11-16:19-39 | 2.15.0 - 2026-11-16:40-97 | 2.14.0 - 2026-11-15:98-118 | 2.13.0 - 2026-11-15:119-148 | 2.12.0 - 2026-11-14:149-171 | 2.11.0 - 2026-11-14:172-190 | 2.10.0 - 2026-11-14:191-209 | 2.9.0 - 2026-11-14:210-222 | 2.8.0 - 2026-11-14:223-236 | 2.7.0 - 2026-11-14:237-254 | 2.6.0 - 2026-11-14:255-262 | 2.5.0 - 2026-11-14:263-275 | 2.4.0 - 2026-11-14:276-286 | 2.3.0 - 2026-11-14:287-301 | 2.2.1 - 2026-11-14:302-308 | 2.2.0 - 2026-11-14:309-316 | 2.1.0 - 2026-11-14:317-334 | 2.0.0 - 2026-11-14:335-340 | 1.0.0 - 2026-11-14:341-345 -->
# Changelog

## 2.15.2 - 2026-11-16

The Extractor file in the repository checked and labelled as what it is: the template. Still **alpha**.

- **The repository file is the template, not the host copy.** `Resources\VmmHostAgent.ps1` holds no laptop key, so it
  cannot save a result (it says so and exits 1 with `-Extract`). `vmm extractor` builds the file to take to a host. The
  file header and TROUBLESHOOTING now say so. Nothing environment-specific is committed: the key is per laptop and
  its private half never leaves that laptop, so a committed ready-to-run build would be wrong.
- **Tests that keep the template and the generator honest** (they run in CI on Windows PowerShell 5.1 and 7):
  the template carries an empty plan card and no key, address, share, e-mail or id; the build equals the template
  minus the steps code plus the plan card, line by line; a static scan shows nothing in the snapshot code that
  Windows PowerShell 2.0 lacks (the only newer cmdlet, `Get-CimInstance`, is used only when `Get-WmiObject` is
  missing).
- Not tested: a real run on PowerShell 2.0 (Server 2008 R2) or on any real host.

## 2.15.1 - 2026-11-16

The Extractor (the .ps1 that is copied to a host and run there) reviewed end to end. Still **alpha**.

- **Runs on PowerShell 7 too.** All nine WMI reads used `Get-WmiObject`, which PowerShell 7 does not have: every
  field of the snapshot would have been empty with a Problem line each. The reads use `Get-WmiObject` where it
  exists (PowerShell 2.0 to 5.1) and `Get-CimInstance` where it does not. The last boot time handles both
  formats. The inventory probe the laptop pastes into the RDP collector got the same reader, inside itself.
- **SQL instances whose name starts with "PS" are read.** The filter `Name -notlike 'PS*'` was meant to drop
  PowerShell's own properties; an instance such as PSQL01 was skipped without any message. Only those
  properties are left out now, by exact name.
- **The last result file survives a failed write.** The older result files were deleted before the new one was
  written; a full disk or no access lost the previous snapshot. The new file is written first now.
- **`-Extract` has an exit code for failed reads:** 0 = saved and every read worked, 1 = not saved, 2 = saved but
  some reads failed (they are `Problem=` lines in the result). Before, 2 and 0 were both 0.
- **32-bit SQL instances are read.** Only the 64-bit registry view was read, so a 32-bit instance (registered under
  Wow6432Node) was missing from the snapshot. The Extractor, the RDP collector and the laptop fleet check read both
  views; a 32-bit instance is tagged `(32-bit)` after its edition, a name in both views is listed once.
- Tests: new `tests\Extractor.Tests.ps1` (13 Pester tests: both WMI branches, the probe on both, no bare
  `Get-WmiObject` left, the SQL names, both SQL registry views, the result file order and failure, the exit code).

## 2.15.0 - 2026-11-16

Exits, error handling and logging checked end to end, every test suite run again. Still **alpha**.

- **Stage copies from the terminal again.** Since 2.7.0 the copy to the host went through the temporary drive
  that maps its admin share with a .NET call that does not know PowerShell drives, so it failed on every host.
  Paths are resolved first now, and a test copies through a drive the way Stage maps it.
- **Disk expansion never leaves a VM down.** An unexpected error or Ctrl+C after the VMs were switched off left
  them deallocated. A recovery now waits for the Azure operations already sent, starts every VM that was running,
  switches off again the ones that were off, writes the results CSV and names any VM to fix in the Azure portal.
- **Exit codes tell the truth.** A failed or blocked step, and `vmm next` with failed hosts, ended with exit
  code 0. They are recorded first, then end with `VmmStepFailed`, `VmmStepBlocked` or `VmmNextStepFailed`
  (exit code 1); VPN down, the lock and security errors keep their own codes (4, 6, 5). Batch commands finish
  every item, then fail naming the ones that did not work: media mount and dismount (`VmmMediaIncomplete`),
  prune (`VmmPruneIncomplete`), disk from snapshot (`VmmRestoreDiskIncomplete`), SQL update fetch
  (`VmmFetchIncomplete`), the extractor inbox (`VmmInboxFailed`, or exit code 5 when a file failed its integrity
  check), handoff verify (`VmmHandoffNotVerified`), disk expansion (`VmmExpandIncomplete`), snapshots
  (`VmmSnapshotIncomplete`: PreSnapshot is no longer recorded as Success when a disk was missed), and
  `vmm connect` when the VPN did not come up (`VmmVpnDown`, exit code 4).
- **The entry scripts (`Scripts\*.ps1`) use the same exit codes as vmm** (one table, `Get-VmmExitCode`), log
  `done`, `FAILED, exit code N` or `INTERRUPTED` with the duration, and clear the session credentials.
- **Ctrl+C is logged.** The CLI, the console actions, the entry scripts and the workflow steps write
  `INTERRUPTED (Ctrl+C)` with the duration. A change step stopped that way is recorded as `Failed` ("check the
  host before running it again"), so the store never shows the state from before as the truth.
- **Credentials leave memory after every command,** not only when the console closes: after each vmm command,
  entry script and console session, after Ctrl+C, and when the module is unloaded.
- Stage: a file of the right size but with the wrong SHA256 on the host is copied again (before, Stage failed on
  every run); a copy that fails the SHA256 check is deleted; a broken or interrupted copy leaves no `.part` file.
- Only a real lock conflict says "vmm is already running"; any other problem with the lock file is
  `VmmInstanceLockFile` with the path.
- Text sent to the AI assistant or a GitHub issue now also masks GUIDs (tenant and subscription ids), Azure
  resource ids, the values of the settings that name your environment, domains, resource groups and VM names,
  and fails closed (`VmmAiUnsafe`, nothing sent) when the fleet store cannot be read.
- Log: a line logged while another was being written (config load, key creation) was dropped; it is written after
  it now. A log file that cannot be written is shown once as a warning, stays in the on-screen log, and
  `vmm maint -Action Diagnose` reports it.
- Backup, restore, clean temp, settings, blocker reports, the daily report and `vmm import -RemoveSource` could
  report success after a failed write or delete; they fail with the reason now (`VmmCleanIncomplete`,
  `VmmSourceNotRemoved`, ...).
- Extractor: `-Finish` said "Host clean" with files left; `-Finish` and `-Extract` exit 1 when they did not
  finish and name what is left.
- Leak scan: `-History` passed when git failed, when run outside a clone, or on a shallow clone; it fails now.
  A git warning on stderr can no longer stop it in Windows PowerShell with `$ErrorActionPreference = 'Stop'`.
- No silent `catch { }` left where an exit, the recovery or a log write can fail: the power-state recovery logs a
  wait or a power-state read that failed, a step whose `Failed` record cannot be saved says so in the day log,
  an `errors.log` write that fails is logged, the "stopped half way" line of a disk expansion no longer depends on
  the results CSV being writable, credentials that cannot be cleared give a warning, an unreadable exit-code table
  gives exit code 1, and the entry scripts print the error masked, like vmm.
- Small fixes: a relative result file path is read from the PowerShell folder, the SQL password copy is disposed
  after use, a staging setting that cannot be saved is shown, `vmm disconnect` checks the VPN client's exit code,
  a console that cannot load its config says so.
- Tests: new `tests\Exits.Tests.ps1` (29 Pester tests: exit codes from new PowerShell processes, Ctrl+C
  simulated in a separate runspace on a step, a copy and a disk expansion, failed and blocked steps, `vmm next`,
  Stage through a drive with the SHA256 re-copy, the power-state recovery, prune and inbox failures, AI masking,
  lock and log failures) and smoke test section 9 (10 checks). 28 of the 29 new tests fail on 2.14.0.
- Docs: README, TROUBLESHOOTING (exit codes and the error each command ends with), AI, WORKFLOW, SECURITY,
  MANAGER-GUIDE, RELEASE.

## 2.14.0 - 2026-11-15

Release preparation. Still **alpha**: the label is dropped only on Kay's go (see docs/RELEASE.md).

- Marked as alpha: `Prerelease = 'alpha'` in the manifest, "(alpha)" in the README header, `stage` in PROJECT.json.
- Leak scan (`Tools\Test-Sanitized.ps1`) now also finds e-mail addresses, tokens (GitHub, OpenAI, AWS, Slack,
  Google, Hugging Face, Groq, JWT), private keys, storage keys and SAS signatures, passwords in connection strings
  and Azure resource IDs, and checks the media share, VPN profile and VPN probe host from your config. Known test
  fixtures are allow-listed. New `-History` switch scans every line ever added on every branch and every commit
  message; works on Windows and other platforms.
- CI checks out the full history and runs the leak scan with `-History` on every pull request and push to main.
- Full scan of the repository and its history for this release: no host names, IPs, tenant/subscription IDs,
  e-mail addresses, tokens or passwords found.
- New docs: `docs/MANAGER-GUIDE.md` (what the tool does and the rules it enforces, for management),
  `docs/TROUBLESHOOTING.md` (exit codes, common errors, encrypted file recovery, where to look),
  `docs/RELEASE.md` (readiness checklist, known limitations, first run on real hosts, release steps).
- `LICENSE`: proprietary, internal use, all rights reserved (to confirm).
- `.gitignore`: also `.rdp`, `.rdg`, certificates, `.env`, CI test results.
- Fix: Azure sign-in errors pointed at `vmm azure pick`, which does not exist; they now say `vmm azure -Save`.
- SECURITY.md: Pester is no longer listed as untested (it runs in CI).

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

_Last updated: 2026-11-16 09:01 UTC_
