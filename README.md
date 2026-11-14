<!-- SUMMARY: VmMaintenance: Windows PowerShell fleet console (vmm) + remote host Extractor for pre-upgrade server maintenance; encrypted store, no stored credentials, environment-agnostic, GitHub updates/issues/PRs; 24-column server inventory; TL;DR at the top. SECTIONS: TLDR:6-24 | Overview:25-43 | At a glance:44-60 | Quick start:61-84 | Adding machines external dat:85-107 | Media repository:108-136 | Server inventory:137-170 | Extractor the program on the:171-196 | Console UI:197-229 | CLI:230-274 | GitHub integration:275-291 | OS policy:292-306 | Workflow per host:307-320 | Directory tree:321-351 | Where your data lives never:352-366 | Testing:367-379 | Errors:380-393 | Future your work AI model wi:394-403 -->
# VmMaintenance

**Creator:** Kay (GitHub: Hello-My-Name-Is-Kay) &nbsp;|&nbsp; **Version:** 2.6.0 &nbsp;|&nbsp; **This file:** 2026-11-14

## TL;DR

- **Goal:** every server on **Windows Server 2019**. Windows 10/11 and other client OS are skipped unless ordered (`vmm order`).
- **Warn management** about Windows Server 2008 (not R2; 2008 R2 is fine) and physical machines: `vmm policy -Notice`.
- **Business hours, Mon-Fri 08:00-17:00 Lisbon:** read-only checks and staging into `C:\Temp` only. Changes off-hours and weekends.
- **Disk expansion** (Azure) is after hours only, no override: the VM is shut down, the disk resized, the VM started.
- **Install:** `Get-ChildItem -Recurse . | Unblock-File` then `powershell -ExecutionPolicy Bypass -File .\Install.ps1`, then `vmm` or the **VM Maintenance** desktop shortcut. Runs from any folder; the installed copy does not depend on it.
- **Test first:** `.\Tools\Invoke-SmokeTest.ps1`. GitHub checks pass on Windows PowerShell 5.1 and 7 (211 smoke checks, 60 Pester tests); real hosts, Azure, VPN and the UI are not tested yet.
- **New machines:** a CSV with three columns, *hostname or FQDN, domain, IP* (`,` or `;`, header optional). `0` in the menu (drag the file, or Enter to browse; preview, then confirm) or `vmm import -Path hosts.csv`. The check then connects by FQDN, or by IP when the name does not resolve.
- **Media repository** (`Staging.SourceShare`): Windows Server images at the root (`Win_Server_2019_FR_FR.iso`), one folder per host for its own files (SQL Server updates). Each host gets the 2019 image **in its install language** plus its folder. `vmm media` shows what is there and what is missing.
- **Server inventory:** the 24-column team sheet per host. Read automatically where possible (check, Extractor), worked out from the workflow, else typed by you with a help window per column. `N` in the menu, `I` on a host, `vmm inventory -Export`. Help text unclear? `T` opens a GitHub issue.
- **Day:** `V` VPN, `6` credentials, `3` check fleet, `4` staging gate, `1` plan. Target 10 machines per day, shown in the header.
- **Two programs:** the **Manager** (`vmm`, your laptop) and the **Extractor** (a .ps1 you run on a remote host in RDP/RDM). Hosts the Manager cannot reach: copy the Extractor to the host's desktop, right-click > Run with PowerShell, copy the `VMM_<HOST>_<time>.vmm` file it leaves on the desktop back to your laptop's Desktop or Downloads. The Manager imports it by itself.
- **Blocked by access:** `B` writes the manager report (clipboard); answer Sent / Later / Bypass; the queue moves on.
- **Never stored:** usernames, passwords, tokens. Fleet data is encrypted on this laptop for your Windows account only.
- **Never in this repo:** hosts, IPs, tenant/subscription IDs, company names. Run `.\Tools\Test-Sanitized.ps1` before every push.
- **Updates:** `U` in the console (or `vmm update`): fetch, show changes, check GitHub results, smoke test, reinstall. GitHub CLI sign-in only; no token stored.
- **Help:** `vmm help`, `Get-Help <Function> -Full`, [docs/USAGE.md](docs/USAGE.md).

## Overview

Terminal fleet console for Windows server maintenance ahead of in-place OS upgrades.
Two PowerShell programs:

| Program | Runs on | Role |
|---|---|---|
| **Manager**: `vmm` (module VmMaintenance) | your laptop | All hosts, encrypted store, keyboard-and-mouse text UI + CLI, parallel checks over the network, staging, Azure disk/snapshot work, VPN, inventory, reports for your manager. Builds the Extractor and reads what it brings back |
| **Extractor**: `VmmExtractor.ps1` (any host) or `VmmExtractor_<HOST>_<time>.ps1` (with that host's plan) | one remote host, inside RDP/RDM | For hosts the Manager cannot reach. Extracts the host's facts and inventory at once and leaves an encrypted `VMM_<HOST>_<time>.vmm` file on the host's desktop; shows current and future steps and *why*; runs the steps that must happen inside the host; sanitized log; removes itself at the end |

Rule: everything the Manager can do over the network it does by itself. When you have to be hands-on
(RDP/RDM), the Extractor reduces it to copy a file in, right-click, copy a file out.

- Windows PowerShell 5.1 and PowerShell 7, Windows only.
- Environment-agnostic: no host, IP, tenant, subscription or company value is in this repository.
- No usernames or passwords are stored, ever. Each session asks again.
- Machine records are encrypted on disk (AES-256 + HMAC-SHA256, key protected by Windows DPAPI).
- Host-to-laptop results are encrypted to a key only your laptop holds (RSA-3072 OAEP + AES-256 + HMAC).

## At a glance

| Need | How the tool handles it |
|---|---|
| 10+ machines per 9-hour day | Header shows the Lisbon clock, `done/target`, expected-by-now and hours left; the Plan screen lists the next step for every host |
| Business hours rule | Mon-Fri 08:00-17:00 Lisbon: read-only checks and staging into `C:\Temp` only. Off-hours and weekends: all steps. Override needs typing `OVERRIDE` plus a reason, and is logged |
| Many hosts at once | Parallel checks (ping, ports, CIM, SQL version, C: space, pending reboot, software) in a runspace pool |
| Missing install files | Staging gate lists exactly which file is missing (e.g. the 2019 image in a host's language), the exact name and path to save it under, and which hosts need it |
| Access denied / blocked | Ready-to-send manager report (copied to clipboard). You must answer "contacted manager?" - Sent / Later / Bypass. The tool never sends email |
| No remote access | RDP/RDM guide: numbered steps, confirm each, paste the collector line back |
| Azure sign-in stuck on "Select a tenant and subscription" | Picker turned off for the process, tenant + subscription passed explicitly; device-code sign-in available |
| Rollback | Checkpoint snapshot after each successful changing step (Azure VMs); prune expired ones at the end, preview first |
| Work inside a host | Extractor: extracts at once to an encrypted file on the desktop; status, steps with reasons, run, history, Finish removes every trace |
| VPN | Cisco Secure Client (vpncli), Windows VPN profiles, or any client via a probe host; host work stops with a clear error when the VPN is down |
| First run | Setup wizard: warnings you confirm, every option explained and validated (`vmm setup`) |
| AI help (optional, off) | Microsoft Foundry Local / Ollama on the laptop, or your organisation's Azure OpenAI with your work account; sanitized, confirm-before-send, advisory only |

## Quick start

```powershell
# From the unzipped folder, in Windows PowerShell or pwsh (no admin needed)
Get-ChildItem -Recurse . | Unblock-File
powershell -ExecutionPolicy Bypass -File .\Install.ps1

# New terminal window, then:
vmm                 # opens the console UI
vmm help            # CLI commands
```

The installer asks for the settings it needs (network share, time zone, daily target,
Azure tenant/subscription, credential mode), shows the important warnings and makes you
type `YES` to each, then offers the smoke test. Every answer can be changed later in
Settings (key `9`) or with `vmm set -Name <Key> -Value <value>`.

Install location: run `Install.ps1` from any folder. It copies the module to your Documents module folders and
`vmm` to `%LOCALAPPDATA%\VmMaintenance\bin` (on PATH), and creates **VM Maintenance** shortcuts on the desktop and
in the Start menu that point at that installed copy. The source folder can be moved or deleted afterwards;
only `vmm update` uses a git clone (`GitHub.SourcePath`).

To remove: `.\Uninstall.ps1` (removes the shortcuts; asks separately before deleting config, encrypted data and reports).

## Adding machines (external data)

New machines usually arrive as a CSV with three columns:

```
Hostname,Domain,IP                <- header optional; any column order when there is one
srv01.corp.example,corp.example,<IP>
SRV02,corp.example,<IP>
```

| Rule | Detail |
|---|---|
| Column 1 | Hostname or FQDN. The short name (first label) is the host's name in vmm |
| Column 2 | Domain. Empty: taken from the FQDN |
| Column 3 | IPv4. Invalid values are dropped with a warning; the host is still imported |
| Separator | `,` `;` or tab, detected. Blank lines and `#` comments skipped |
| New host | Added with its FQDN, domain and IP (encrypted store). The fleet check connects by FQDN and falls back to the IP when the name does not resolve from your laptop; domain and IP fill the inventory |
| Host already there | Empty values are filled in; nothing measured is overwritten (`-Update` replaces FQDN/domain/IP from the file) |

How: `0` in the menu (type or drag the path, or Enter for a file dialog; a preview table, then confirm, then
optionally delete the plaintext file), or `vmm import -Path hosts.csv -Preview` and then without `-Preview`.
A `.txt` with one name per line, or names on the command line, still work.

## Media repository

One network folder holds everything the hosts need (`Staging.SourceShare`, asked at install):

```
\\<FILESERVER>\<SHARE>\<PROJECT>\<ISO_REPOSITORY>
|   Win_Server_2016_EN_US.ISO
|   Win_Server_2019_EN_US.ISO
|   Win_Server_2019_FR_FR.ISO          <- one image per version and language
|   Win_Server_2022_ES-ES.ISO          (_ or -, any case)
|   Win_Server_2019_FR_FR.ISO.sha256   <- optional: SHA256 to verify against
+---<SERVER_01>
|       SQLServer2014SP3-KB4022619-x64-FRA.exe   <- only this host gets these
|       SQLServer2016SP3-KB5003279-x64-FRA.exe
\---<SERVER_02>
        SQLServer2014SP3-KB4022619-x64-ENU.exe
```

| Rule | Detail |
|---|---|
| Image per host | `Staging.OsMediaVersion` (default 2019) in the host's **install language** (read by Check, the collector and the Extractor). An in-place upgrade needs the same language, so there is no fallback: a missing language closes the gate and names the exact file to download |
| Host folder | `<share>\<HOST>\` (top level), matched to the fleet name, case-insensitive; different folder names go in `Staging.HostFolders` |
| SQL updates | Staged with the host; a warning when the host has no SQL Server instance of that version. Not run by vmm |
| Destination | `Staging.TargetFolder` (`C:\Temp`) on the host, verified by size and SHA256 when known |
| Extra files | `Staging.Packages` (optional), for every host or by OS wildcard |
| Check | `vmm media`, `4` > `M`; `vmm stage` for the gate |

`Staging.Layout = 'Packages'` keeps the pre-2.3 fixed list instead.

## Server inventory

The team keeps one sheet per server with 24 columns. vmm fills it **as early as possible, automatically
first, and helps you with the rest**:

1. **Automatic (from a terminal, no typing).** The fleet check (`3`, or `C` on a host) reads them over
   WMI from the laptop. When a host cannot be reached that way, the Extractor (it saves a result file on the host's desktop) or the
   RDP collector reads the same columns on the host and brings them back in the encrypted result.
2. **Worked out by vmm.** From the workflow it already tracks: what is left to do, how far the host is,
   when the upgrade happened.
3. **Typed by you, with help.** Everything only people know. `I` on a host shows every column: red =
   missing. Enter opens the column's **help window** (what it means and exactly where to find it, with the
   command to run on the host when there is one), then asks for the value. `F` walks through all missing
   columns. Values that are the same for most hosts (your name as technician, the phase) are set once in
   the setup wizard, page Inventory.
4. **Help text unclear?** `T` on the column (or `vmm helptext`) opens a GitHub issue with the current text
   and your proposal (masked, previewed, confirmed). Help texts live in one file in the repository
   (`VmMaintenance\Resources\InventoryFields.psd1`), so a fix reaches everyone with `vmm update`.

| Column | How it is filled |
|---|---|
| Hostname, OS Version, SQL Present | Automatic: fleet check / Extractor / collector |
| Domain, IPAddress, Domain controller | Automatic (DNS, `Win32_ComputerSystem`, network adapters) |
| Windows License | Automatic (activation state, as `slmgr /dli` shows it) |
| QUALYS Cloud AGENT, CrowdStrike Agent, Zabbix, IVANTI, LANSWEEPER AGENT | Automatic: service found and running / installed (stopped) / not installed. Service names per agent are in the field file |
| TLS 1.0-1.1 DISABLED | Automatic: SCHANNEL server keys; no key = Windows default = enabled |
| Actions to be executed, Actions Status, Execution Date | From the workflow steps; a typed value replaces it |
| Company, Perimeter, Localisation, Phase, Server Owner, Assigned Technician, Comments, Aplication | Typed by you (help window) or a fleet default |

Nothing about the six workflow steps changes: the inventory never blocks a step. The export
(`vmm inventory -Export`, `E` in the inventory screen, and with every daily report) writes
`Reports\Inventory\Inventory_<date>.csv` with exactly these headers in this order
(`Inventory.CsvDelimiter`: `,` or `;` for Excel with Portuguese/French settings).

## Extractor (the program on the remote host)

For hosts the Manager cannot reach over the network (no WMI/RPC, other domain, RDP-only):

| # | Where | You do | The programs do |
|---|---|---|---|
| 1 | Laptop | `E` > `B` once (or `vmm extractor`): one `VmmExtractor.ps1` for every host. With a host's plan (to run steps there): `X` on the host | Writes the file with this laptop's public key and puts it on the clipboard |
| 2 | Host (RDP/RDM) | Paste on the desktop. Right-click > **Run with PowerShell** | Extracts at once (read-only, no admin needed) and saves `VMM_<HOST>_<time>.vmm` on the desktop, encrypted for your laptop only. Also on the clipboard |
| 3 | Laptop | Copy that `.vmm` file to your Desktop or Downloads | Imported when vmm starts, with `E`, `P` on the host, or `vmm inbox`; the file is deleted after import. Precheck or Verify is chosen by itself |
| 4 | Host, end of cycle | Extractor menu `6` Finish | Removes `C:\Temp\VmmAgent`, the Extractor, its result files and the clipboard |

The Extractor's menu (after the extraction): `1` Status, `2` Steps (current / future / why), `3` Run a step
(the result file is refreshed after each step), `4` History, `5` Export again, `6` Finish. Change steps need
PowerShell as administrator and the per-host Extractor.

Without copying a file: `G` on the host shows a collector script to paste into PowerShell on the host; it
saves the same kind of file (not encrypted).

Run by hand instead of right-click: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\VmmExtractor.ps1"`
(Bypass applies to that process only; if Group Policy enforces AllSigned, sign the file).

The Extractor works on Windows PowerShell 2.0 to 5.1, refuses change steps for a plan made for another host,
applies the same Lisbon time rules and override rules, and logs only sanitized lines
(no IPs, user names, share paths or secrets) to `C:\Temp\VmmAgent\agent.log`, readable by
Administrators, SYSTEM and you only.

## Console UI

Three header rows stay on screen: Lisbon clock and laptop clock; the current rule
(green "MAINTENANCE WINDOW" or yellow "BUSINESS HOURS: checks + staging only, changes from ...");
and today's progress bar with Azure context and credential state.

| Key | Screen |
|---|---|
| 1 | Plan today: what is allowed now and the next host for each step |
| 2 | Fleet: every host with health, stage, OS, SQL, C: free; open a host |
| 3 | Check fleet now (read-only, allowed any time) |
| 4 | Staging gate: OS images and host files on the media repository? `M` media report |
| 5 | Azure: sign in, pick tenant + subscription |
| 6 | Credentials: set or clear this session's Windows / SQL credentials |
| 7 | Reports: daily CSV + HTML, blocker reports |
| 8 | Snapshots: preview and prune expired |
| 9 | Settings: every option, saved to your local config |
| 0 | Import hosts |
| E | Extractor: import `VMM_*.vmm` result files, build the Extractor |
| N | Inventory: columns filled / missing per host, export CSV |
| V | VPN status, connect, disconnect |
| A | Assistant (optional AI) |
| W | Setup wizard |
| U | GitHub / updates: status, update, sign in, clone, issue, pull request |
| H / Q | Help / Quit (clears session credentials) |

On a host screen: Enter run step, `G` RDP guide, `X` Extractor with this host's plan, `P` import result (clipboard, then Desktop/Downloads), `Y` confirm a
guided step, `B` blocker report and move on, `R` resolve, `L` mstsc, `H` hold, `C` check, `I` inventory.

Arrows, PgUp/PgDn, Home/End move; Enter opens; Esc goes back; letters run the actions shown
in the footer. Mouse: click selects, double-click opens, wheel scrolls (classic console and
Windows Terminal; QuickEdit is turned off while the UI runs and restored on exit).

## CLI

Every UI action has a command. `vmm help` prints this list.

| Command | Does |
|---|---|
| `vmm status [-Filter srv*]` | Fleet table |
| `vmm check [-Name a,b] [-Azure]` | Parallel read-only check |
| `vmm import -Path hosts.csv [-Preview] [-Update] [-RemoveSource]` | Add/update hosts from a CSV (hostname or FQDN, domain, IP), a .txt list, or `-Name a,b` |
| `vmm remove -Name a,b` | Remove hosts |
| `vmm plan` | Work queue: next step per host and whether it is allowed now |
| `vmm next [-HostName x] [-All]` | Run the next automatic step |
| `vmm step -HostName x -Step Upgrade` | Run one step (`-Override -OverrideReason ".."` in business hours) |
| `vmm guide -HostName x -Step Upgrade` | RDP/RDM checklist |
| `vmm collect [-Path VMM_x.vmm \| -Line "VMM2..."]` | Record one result (file, pasted line, or clipboard) |
| `vmm inbox` | Import every `VMM_*.vmm` result file from Desktop/Downloads (also at start and with `E`) |
| `vmm stage` | Staging gate: share reachable, files present, hashes |
| `vmm inventory` | Server inventory: filled/missing per host; `-HostName x` all columns with source; `-Missing`; `-Export` CSV |
| `vmm inventory-set` | Set a column by hand: `-HostName x[,y] -Field "Server Owner" -Value ".."` or `-Clear` |
| `vmm helptext` | Ask for a help text change on GitHub: `-Field "<column>"` or `-Screen "<name>"` |
| `vmm media` | Media repository: images by version and language, host folders, what the fleet still needs |
| `vmm blocker -HostName x -Step y -Message ".."` | Manager report for an access problem |
| `vmm resolve -HostName x` | Access granted, unblock |
| `vmm report [-Open]` | Daily CSV + HTML + JSON |
| `vmm progress` / `vmm time` | Today vs target / clock and window |
| `vmm prune [-Apply]` | Expired snapshots, preview unless `-Apply` |
| `vmm azure [-Save] [-DeviceCode]` | Sign in and pick the subscription |
| `vmm set -Name Key -Value v` | Change a setting |
| `vmm config` | Show / reload the config |
| `vmm extractor` / `vmm extractor -HostName x` | Build the Extractor: for any host, or with that host's plan (`vmm agent` = same) |
| `vmm vpn` / `vmm connect` / `vmm disconnect` | VPN |
| `vmm ai -Prompt ".." [-IncludeFleet]` | Optional assistant |
| `vmm setup [-Page Vpn]` | Setup wizard |
| `vmm github` / `vmm update [-CheckOnly]` / `vmm clone` | GitHub status, update vmm, clone the repo |
| `vmm issue [-FromErrorLog]` / `vmm pr [-NewBranch x -Message ..] [-Draft]` | Report an issue, open a pull request |
| `vmm policy [-Notice]` | OS policy per host, management note |
| `vmm order -HostName x -Reason ".."` / `-Clear` | Work on a client-OS host by order |

Global flags: `--no-mouse`, `--no-color`, `--config <file>`, `--debug-errors`, `--version`.
Exit codes: 0 ok, 1 error, 2 usage, 3 blocked by the time window, 4 VPN down, 5 security check failed.
Feature flags in the config (`Features.HostAgent`, `Features.Vpn`, `Features.Ai`) switch whole areas on or off.

The classic one-task scripts (`Scripts\Expand-AzOsDisk.ps1`, `CreateSnapshots.ps1`, ...) still
work and honour the same time window. See [docs/USAGE.md](docs/USAGE.md).

## GitHub integration

Needs the GitHub CLI (`winget install GitHub.cli`) and `gh auth login` once; gh keeps the login in
Windows Credential Manager and vmm never reads it. Set up during install (wizard page GitHub) or later
with `U` > `W` / `vmm setup -Page GitHub`.

| Action | Console | CLI | Safety |
|---|---|---|---|
| Status | `U` > `S` | `vmm github` | Read-only |
| Update vmm | `U` > `U` | `vmm update` | Shows new commits; needs GitHub checks passed (else type YES); smoke test must pass before install, else the clone is moved back; settings and data untouched |
| Clone | `U` > `C` | `vmm clone -Path <dir>` | Sets `GitHub.SourcePath` |
| Issue | `U` > `I` | `vmm issue -FromErrorLog` | Masked like the AI assistant, preview + confirm |
| Pull request | `U` > `P` | `vmm pr -NewBranch x -Message ".." -Title ".."` | Leak scan against your local values first; preview + confirm |

GitHub checks (`.github/workflows/ci.yml`) run the leak scan, smoke test and Pester on Windows
PowerShell 5.1 and PowerShell 7 for every push and pull request.

## OS policy

| Host OS / platform | Scope | What the tool does |
|---|---|---|
| Windows Server 2019 (`Policy.TargetOs`) | AtTarget | Nothing to upgrade; left out of the queue |
| Server 2022 / 2025 | NewerThanTarget | Never downgraded; left out |
| Windows 10, 11 and other client OS | ClientOs | Not touched: change steps refused, left out of the queue. `vmm order -HostName x -Reason "..."` puts it in scope (logged) |
| Windows Server 2008 (not R2) | InScope + warning | Management warning: no direct in-place path to 2019 |
| Windows Server 2008 R2, 2012 (R2), 2016 | InScope | Normal workflow |
| Physical machine | InScope + warning | Management warning: no Azure snapshot or disk resize |

`vmm policy` lists the scope of every host; `vmm policy -Notice` writes the management note, copies it
and records your Sent / Later / Bypass answer. The daily report has Policy, ManagementWarning and
ManagementNotified columns.

## Workflow per host

| # | Step | Class | Business hours | Off-hours / weekend | Checkpoint after |
|---|---|---|---|---|---|
| 1 | Precheck | Read-only | Yes | Yes | No |
| 2 | Stage | Staging | Yes (into `C:\Temp`) | Yes | No |
| 3 | PreSnapshot | Change | Override only | Yes | Is the snapshot |
| 4 | ExpandDisk | Change | No (VM is shut down) | Yes | Yes (Azure) |
| 5 | Upgrade | Change | Override only | Yes | Yes (Azure) |
| 6 | Verify | Read-only | Yes | Yes | No |
| - | Prune | Change | Override only | Yes | - |

Details and the snapshot-after-each-step answer: [docs/WORKFLOW.md](docs/WORKFLOW.md).

## Directory tree

```
VmMaintenance\
  .github\workflows\ci.yml       GitHub checks (Windows, PS 5.1 + 7)
  Install.ps1 / Uninstall.ps1       per-user install, no admin
  README.md  CHANGELOG.md  llms.txt  PROJECT.json
  docs\
    ARCHITECTURE.md                 modules, data flow, store format
    USAGE.md                        daily runbook
    SECURITY.md                     what is protected, how, honest limits, untested list
    WORKFLOW.md                     steps, time rules, checkpoints, prune
    AI.md                           optional AI providers, access request text, future MCP
  VmMaintenance\                    the module
    VmMaintenance.psd1 / .psm1      manifest / loader
    Public\                         exported functions, one per file
    Private\                        helpers and TUI screens, one per file
    Resources\                      VmmHostAgent.ps1 (program 2), VmmConsoleInput.cs, LansweeperDiskSpace.sql
  Scripts\
    vmm.ps1                         CLI/UI entry point
    _Bootstrap.ps1 + 10 classic task scripts
  config\
    config.example.psd1             settings template, placeholders only
    servers.example.txt             list format
  Tools\
    Invoke-SmokeTest.ps1            offline smoke test
    Test-Sanitized.ps1              pre-commit leak check
  tests\
    VmMaintenance.Tests.ps1         Pester 5
```

## Where your data lives (never in this folder)

| What | Location | Protection |
|---|---|---|
| Settings | `%APPDATA%\VmMaintenance\config.psd1` | Plaintext, no secrets (Set-VmmSetting refuses credential-like keys) |
| Host lists | `%APPDATA%\VmMaintenance\lists\*.txt` | Plaintext; use `import -RemoveSource` to delete after import |
| Fleet store | `%LOCALAPPDATA%\VmMaintenance\data\fleet.vmm` | AES-256-CBC + HMAC-SHA256 |
| Store key | `%LOCALAPPDATA%\VmMaintenance\data\store.key` | DPAPI, your Windows user on this laptop only |
| Reports | `%LOCALAPPDATA%\VmMaintenance\Reports\` | Plaintext by design (they are for your manager) |
| Inventory values | Inside the fleet store | Encrypted like the rest of the store; the export `Reports\Inventory\*.csv` is plaintext |
| Agent key | `%LOCALAPPDATA%\VmMaintenance\data\agent.key` | RSA private key, DPAPI |
| Built agents | `%LOCALAPPDATA%\VmMaintenance\agents\` | Plaintext plan for one host; older copies deleted on export |
| Error log | `%LOCALAPPDATA%\VmMaintenance\logs\errors.log` | Sanitized, 1 MB cap |
| Credentials | Process memory only, as `PSCredential` | Never written; cleared on quit. VPN credentials go only to the VPN client |

## Testing

```powershell
.\Tools\Invoke-SmokeTest.ps1                                       # offline, no Pester needed
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path .\tests -Output Detailed
.\Tools\Test-Sanitized.ps1                                         # before every commit/push
```

Status (2.4.0): the offline smoke test (211 checks) and Pester (60 tests) pass on GitHub's Windows runners in
PowerShell 5.1 and 7. Everything that needs real hosts, Azure, SQL, a VPN or an interactive console is
still untested: see [docs/SECURITY.md](docs/SECURITY.md).

## Errors

Every error says what failed, on which object, the raw error, the likely cause and the fix:

```
ERROR: Could not copy the staging package.
  Target : <host> C:\Temp\<file>
  Error  : Access is denied.
  Cause  : Your account is not a local administrator on the host (C$ needs admin).
  Fix    : Use a Windows credential with local admin (Credentials screen), or raise a blocker report.
```

Colours: cyan info, green success, yellow warning, red error, dark grey skipped.

## Future: your work AI model with tools (MCP)

Planned, not built. An MCP server inside the module would expose a small, allow-listed set of
`vmm` functions (read fleet status, explain a host, draft a report, propose a config change) to an
AI model your organisation approves (Copilot Studio agent, Azure AI Foundry agent, or a local
model), signed in with your work account. Every change would come back as a diff that you approve
in the console; no credentials, and no write access outside the vmm config and reports folders.
Details and the access request text: [docs/AI.md](docs/AI.md).

_Last updated: 2026-11-14 04:56 UTC_
