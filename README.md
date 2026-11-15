<!-- SUMMARY: VmMaintenance: Windows PowerShell fleet console (vmm) + remote host Extractor for pre-upgrade server maintenance; encrypted store, no stored credentials, environment-agnostic, GitHub updates/issues/PRs; 24-column server inventory; live log pane on every screen, encrypted day logs, maintenance tools; TL;DR at the top. SECTIONS: TLDR:6-33 | Overview:34-52 | At a glance:53-69 | Quick start:70-93 | Adding machines external dat:94-116 | Media repository:117-145 | Server inventory:146-179 | Snapshot terminal first hand:180-195 | Hands-on staging over RDP RD:196-218 | Extractor the program on the:219-251 | Console UI:252-293 | CLI:294-355 | GitHub integration:356-372 | OS policy:373-387 | Workflow per host:388-401 | Directory tree:402-435 | Where your data lives never:436-452 | Testing:453-466 | Errors:467-481 | Future your work AI model wi:482-491 -->
# VmMaintenance

**Creator:** Kay (GitHub: Hello-My-Name-Is-Kay) &nbsp;|&nbsp; **Version:** 2.14.0 (alpha) &nbsp;|&nbsp; **This file:** 2026-11-15

## TL;DR

- **Goal:** every server on **Windows Server 2019**. Windows 10/11 and other client OS are skipped unless ordered (`vmm order`).
- **Warn management** about Windows Server 2008 (not R2; 2008 R2 is fine) and physical machines: `vmm policy -Notice`.
- **Business hours, Mon-Fri 08:00-17:00 Lisbon:** read-only checks and staging into `C:\Temp` only. Changes off-hours and weekends.
- **Disk expansion** (Azure) is after hours only, no override: the VM is shut down, the disk resized, the VM started.
- **Install:** `Get-ChildItem -Recurse . | Unblock-File` then `powershell -ExecutionPolicy Bypass -File .\Install.ps1`, then `vmm` or the **VM Maintenance** desktop shortcut. Runs from any folder; the installed copy does not depend on it.
- **Test first:** `.\Tools\Invoke-SmokeTest.ps1`. GitHub checks pass on Windows PowerShell 5.1 and 7 (278 smoke checks, 99 Pester tests); real hosts, Azure, VPN and the UI are not tested yet.
- **New machines:** a CSV with three columns, *hostname or FQDN, domain, IP* (`,` or `;`, header optional). `0` in the menu (drag the file, or Enter to browse; preview, then confirm) or `vmm import -Path hosts.csv`. The check then connects by FQDN, or by IP when the name does not resolve.
- **Media repository** (`Staging.SourceShare`): Windows Server images at the root (`Win_Server_2019_FR_FR.iso`), one folder per host for its own files (SQL Server updates). Each host gets the 2019 image **in its install language** plus its folder. `vmm media` shows what is there and what is missing.
- **Snapshot, terminal first:** `vmm snapshot` reads every host from the laptop (DCOM, then WinRM, then WinRM-SSL), read-only. Only hosts where every route fails need hands-on: vmm then builds the Extractor, which is snapshot-only and writes one encrypted file on the host desktop, nothing else. `vmm access` shows the route per host.
- **Terminal copy failed? Hands-on with checks:** when Stage cannot copy to a host (admin share closed, access denied), vmm offers to continue over **RDP, RDM (Devolutions Remote Desktop Manager) or RDCMan**: it opens the client you pick, puts a copy-and-check script on the clipboard, lists every file for `C:\Temp` with size and SHA256, and when you come back (`V`) **verifies the files on the host** before Stage is marked done. `T` on a host, or `vmm handoff -HostName x`; `vmm rdp -HostName x` just opens a session. No account or password is passed to the client or saved.
- **Look:** deep iceberg blue: blue-black background, ice-tinted text, deep iceberg top bar, key bar and selected row, iceberg titles; green, orange and red only for statuses (a small block in front of each row, the text stays neutral). 24-bit colour where the console takes it, 16 colours otherwise (`UI.TrueColor`), `--no-color` for none, `UI.DeepBackground = $false` for a black background.
- **One vmm at a time:** a second vmm that could change something stops and says which process is running; read-only commands (`vmm log -Follow`, `vmm status`, `vmm plan`) still work beside it.
- **Agent health:** Qualys, CrowdStrike, Zabbix, Ivanti and Lansweeper agents are reported as OK / WARN / FAIL with version and reason (stopped, start type, driver, port, silent log, old version), by the fleet check and by the Extractor. `vmm agents -Problems`, `A` on a host, and the inventory columns.
- **SQL Server updates:** `vmm fetch -Preview` shows the SP/CU each SQL instance needs; `vmm fetch` (or `F` on the staging screen) downloads each one once into `<share>\_Downloads`, checks Microsoft's signature, and copies it into the host folders, so staging and RDP users find it there. Needs `Install-Module dbatools -Scope CurrentUser` once. The Windows Server ISO stays a manual download.
- **Server inventory:** the 24-column team sheet per host. Read automatically where possible (check, Extractor), worked out from the workflow, else typed by you with a help window per column. `N` in the menu, `I` on a host, `vmm inventory -Export`. Help text unclear? `T` opens a GitHub issue.
- **Live log on every screen:** the bottom rows show what vmm is doing right now; long operations (fleet check, staging copies, Azure jobs) print each host's step, each finished host with its time, and every 5 s who is still running. `F2` hides/shows it on any screen, `F3` opens the full log. Everything also goes to an encrypted day log: `vmm log`, `vmm log -Follow` in a second window.
- **Maintenance:** `M` in the menu or `vmm maint`: diagnose vmm, check / back up / restore the fleet store (one backup a day is automatic), clean old logs and temp files.
- **Day:** `V` VPN, `6` credentials, `3` check fleet, `4` staging gate, `1` plan. Target 10 machines per day, shown in the header.
- **Two programs:** the **Manager** (`vmm`, your laptop) and the **Extractor** (a .ps1 you run on a remote host in RDP/RDM). Hosts the Manager cannot reach: copy the Extractor to the host's desktop, right-click > Run with PowerShell, copy the `VMM_<HOST>_<time>.vmm` file it leaves on the desktop back to your laptop's Desktop or Downloads. The Manager imports it by itself.
- **Blocked by access:** `B` writes the manager report (clipboard); answer Sent / Later / Bypass; the queue moves on.
- **Never stored:** usernames, passwords, tokens. Fleet data is encrypted on this laptop for your Windows account only.
- **Never in this repo:** hosts, IPs, tenant/subscription IDs, company names. Run `.\Tools\Test-Sanitized.ps1` before every push.
- **Updates:** `U` in the console (or `vmm update`): fetch, show changes, check GitHub results, smoke test, reinstall. GitHub CLI sign-in only; no token stored.
- **Help:** `vmm help`, `Get-Help <Function> -Full`, [docs/USAGE.md](docs/USAGE.md), [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
- **Status: alpha.** Tested offline only; nothing has run on a real host, Azure, VPN or SQL yet. For management: [docs/MANAGER-GUIDE.md](docs/MANAGER-GUIDE.md). Release checklist and known limitations: [docs/RELEASE.md](docs/RELEASE.md).

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

## Snapshot: terminal first, hands-on last

`vmm snapshot` (menu `3`, or `S` on a host) reads every host **from this terminal**, read-only, any time:

| Order | Route | Port | Used when |
|---|---|---|---|
| 1 | DCOM (WMI over RPC) | TCP 135 | Open and it answers |
| 2 | WinRM | TCP 5985 | DCOM closed or refused |
| 3 | WinRM-SSL | TCP 5986 | The two above closed or refused |
| last | Hands-on: the Extractor in RDP/RDM | - | Every route failed. vmm says why per route, builds the Extractor and lists the steps |

`vmm access` only tests the routes (fast) and shows who needs hands-on. The order is `Fleet.Routes`.
Nothing is written, started, stopped or configured on a host, and nothing is reconfigured on the laptop
(no TrustedHosts edit, no firewall change). The Windows licence read wakes the Software Protection service
on the host for a moment; `Fleet.WindowsLicence = $false` skips it.

## Hands-on staging over RDP / RDM

When vmm cannot copy the staging files to a host from the terminal (the admin share `\\host\C$` is closed,
access is denied, the copy breaks) and the alternatives already failed, the Stage step offers to go on by hand
(`Handoff.Offer = Ask`). You can also start it yourself: `T` on a host or on the Stage guide, or
`vmm handoff -HostName x`. Policy and time rules are the same as Stage: client OS only with an order, and in
business hours only into `C:\Temp`.

| # | Who | What |
|---|---|---|
| 1 | vmm | Builds the file list (same as the terminal copy; the staging gate applies), and asks whether to copy the files to this laptop first (**outbox**, for hosts that cannot open the share: the host then takes them from `\\tsclient\C\...`) |
| 2 | vmm | Puts a short script on the clipboard and asks **RDP**, **RDM**, **RDCMan** or **none** (you open the session yourself). Missing clients are shown with the reason |
| 3 | vmm | Opens the client: RDP with a one-off `.rdp` file (clipboard on, only the outbox drive shared), RDM with a quick connect (`/Template:RDP /Host:<host>`), RDCMan with a one-off `.rdg`. You sign in: vmm passes and keeps no account |
| 4 | You, on the host | PowerShell > paste. The script writes only in `C:\Temp`: copies each missing file (from the share, else from the laptop), reads size and SHA256 on the host and puts one `VMMSTAGE1\|...` line on the clipboard. Or copy the listed files by hand (Explorer, RDM file transfer) |
| 5 | You, in vmm | `V` verifies: the `VMMSTAGE1` report (clipboard, or `P` to paste it), else WinRM (hash read on the host), the admin share, WMI (size). `C` copies the script again, `O` reopens the session, `S` shows the steps, `Q` stops |
| 6 | vmm | Every file right (size, and SHA256 when one is known) = Stage `Success` with a note saying it was done by hand and how it was verified. Anything else = nothing recorded, and it says which file is missing or wrong |

Later, without a session: `vmm handoff -HostName x -VerifyOnly` (reads the host) or `-Report "VMMSTAGE1|..."`.
Settings: `Handoff.Client` (default client), `Handoff.Outbox`, `Handoff.RdmPath` / `Handoff.RdcManPath` (when not
found by themselves), `Handoff.RdmTemplate`, `Handoff.AcceptSizeOnly` (default `$false`: a known SHA256 must be read
on the host). `vmm rdp -List` shows which clients this laptop has. Everything goes to the day log; the `.rdp` /
`.rdg` files and the host script are deleted at the end, the outbox by `vmm maint -Action CleanTemp` after a day.

## Extractor (the program on the remote host)

Only for hosts the terminal cannot read (no WMI/RPC, no WinRM, other domain, RDP-only). It is **snapshot
only**: it reads the host and writes one encrypted result file on the host's desktop. The file holds no code
that can change a host (the steps code is cut out when it is built), no host name, share path or address.

| # | Where | You do | The programs do |
|---|---|---|---|
| 1 | Laptop | `vmm snapshot` (or `E` > `B`, `vmm extractor`): one `VmmExtractor.ps1` for every host | Writes the file with this laptop's public key and puts it on the clipboard |
| 2 | Host (RDP/RDM) | Paste on the desktop. Right-click > **Run with PowerShell** | Reads the host (no admin needed) and saves `VMM_<HOST>_<time>.vmm` on the desktop, encrypted for your laptop only. Shows what it read and any read that failed |
| 3 | Laptop | Copy that `.vmm` file to your Desktop or Downloads | Imported when vmm starts, with `E`, `P` on the host, or `vmm inbox`; the file is deleted after import. Precheck or Verify is chosen by itself |
| 4 | Host | `F` in the Extractor | Deletes the Extractor and its result files from the desktop |

What it touches on the host: the result file on the desktop, and the clipboard (`-NoClipboard` leaves it
alone). No folder, no log, no registry change, no service change, no network connection. Each read stands
alone: one that fails is listed (`Problem=`) and shown on the laptop as a snapshot gap; the rest still go.
Staged files are checked by name only (no hashing of multi-GB images during a snapshot).

Keys after the snapshot: `Enter` close, `I` inventory columns, `R` read again, `F` finish.

Run by hand instead of right-click: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\VmmExtractor.ps1"`
(Bypass applies to that process only; if Group Policy enforces AllSigned, sign the file).
Without copying a file: `G` on the host shows a collector script to paste into PowerShell on the host; it
saves the same kind of file (not encrypted).

**Steps from inside the host (second priority, off by default):** `vmm set -Name Extractor.AllowSteps -Value true`
makes the per-host Extractor (`X` on a host) also carry the six workflow steps, with the same Lisbon time
rules and override rules, a sanitized log in `C:\Temp\VmmAgent` (Administrators, SYSTEM and you only) and
the menu `1` Status, `2` Steps, `3` Run, `4` History, `5` Export, `6` Finish. It refuses change steps for a
plan made for another host. The any-host Extractor never carries steps.

The Extractor works on Windows PowerShell 2.0 to 5.1.

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
| L | Log: everything vmm did today (filter, another day, plaintext export) |
| M | Maintenance: diagnose, check / back up / restore the fleet store, clean logs and temp files, log options |
| H / Q | Help / Quit (clears session credentials) |

On a host screen: Enter run step, `G` RDP guide, `X` Extractor with this host's plan, `P` import result (clipboard, then Desktop/Downloads), `Y` confirm a
guided step, `B` blocker report and move on, `R` resolve, `L` remote desktop (RDP / RDM / RDCMan), `T` stage by hand over remote desktop with checks, `H` hold, `C` check, `I` inventory.

Arrows, PgUp/PgDn, Home/End move; Enter opens; Esc goes back; letters run the actions shown
in the footer. Mouse: click selects, double-click opens, wheel scrolls (classic console and
Windows Terminal; QuickEdit is turned off while the UI runs and restored on exit).

**Live log (every screen).** The bottom `Log.PaneLines` rows (default 6) show the newest log lines as they
happen. `F2` shows or hides the pane on any screen (remembered as `Log.Live`; `--no-log` for one run), `F3` opens
the full log. While an action runs, its window is the live log: time-stamped progress lines say which host is at
which step (DNS, ping, ports, WMI, licence query...), when each host finished and how long it took, and every
`Log.HeartbeatSeconds` (5) how many are done and which hosts have been running longest, so a stuck host is obvious.
Staging copies report MB done, speed and time left; Azure jobs say what they are waiting on.

## CLI

Every UI action has a command. `vmm help` prints this list.

| Command | Does |
|---|---|
| `vmm status [-Filter srv*]` | Fleet table |
| `vmm snapshot [-Name a,b]` | Read-only snapshot, terminal first; Extractor built only for hosts with no route |
| `vmm access [-Name a,b]` | Which terminal route works per host; who needs hands-on |
| `vmm check [-Name a,b] [-Azure] [-AccessOnly]` | Parallel read-only check (what snapshot runs) |
| `vmm import -Path hosts.csv [-Preview] [-Update] [-RemoveSource]` | Add/update hosts from a CSV (hostname or FQDN, domain, IP), a .txt list, or `-Name a,b` |
| `vmm remove -Name a,b` | Remove hosts |
| `vmm plan` | Work queue: next step per host and whether it is allowed now |
| `vmm next [-HostName x] [-All]` | Run the next automatic step |
| `vmm step -HostName x -Step Upgrade` | Run one step (`-Override -OverrideReason ".."` in business hours) |
| `vmm guide -HostName x -Step Upgrade` | RDP/RDM checklist |
| `vmm handoff -HostName x [-Client Rdp\|Rdm\|RdcMan\|None] [-Outbox Always]` | Stage by hand over remote desktop, then verify size and SHA256 on the host; `-VerifyOnly` or `-Report "VMMSTAGE1\|.."` to check later |
| `vmm rdp -HostName x [-Client Ask\|Rdp\|Rdm\|RdcMan]` / `vmm rdp -List` | Open RDP / RDM / RDCMan for a host (no account passed) / which clients are installed |
| `vmm collect [-Path VMM_x.vmm \| -Line "VMM2..."]` | Record one result (file, pasted line, or clipboard) |
| `vmm inbox` | Import every `VMM_*.vmm` result file from Desktop/Downloads (also at start and with `E`) |
| `vmm stage` | Staging gate: share reachable, files present, hashes |
| `vmm agents [-HostName a,b] [-Problems]` | Agent health and version per host (Qualys, CrowdStrike, Zabbix, Ivanti, Lansweeper) |
| `vmm inventory` | Server inventory: filled/missing per host; `-HostName x` all columns with source; `-Missing`; `-Export` CSV |
| `vmm inventory-set` | Set a column by hand: `-HostName x[,y] -Field "Server Owner" -Value ".."` or `-Clear` |
| `vmm helptext` | Ask for a help text change on GitHub: `-Field "<column>"` or `-Screen "<name>"` |
| `vmm fetch [-Preview] [-HostName a,b]` | SQL Server SP/CU per host: download once into the share cache, copy into host folders (never installs) |
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
| `vmm log [-Follow] [-Level Error] [-Find x] [-Date yyyy-MM-dd] [-List] [-Export]` | The log: last lines, live in a second window, filters, plaintext copy for a ticket |
| `vmm maint -Action Diagnose` | Maintenance: `Diagnose`, `CheckStore`, `Backup`, `ListBackups`, `Restore -BackupFile x`, `CleanLogs [-All]`, `CleanTemp`, `ResetUi` |

Global flags: `--no-mouse`, `--no-color`, `--no-log`, `--config <file>`, `--debug-errors`, `--version`.
Exit codes: 0 ok, 1 error, 2 usage, 3 blocked by the time window, 4 VPN down, 5 security check failed, 6 another vmm is running.

**Logging.** Every command is written to the encrypted day log: the command line (option names, not values),
each message, the tables it printed, progress lines, then the result with its duration or `FAILED` with the
error, and the exit code. Read it with `vmm log`; `vmm log -Follow` in a second window shows it live.

**One vmm at a time.** The console and every command that can change something hold a lock on the data
folder. A second one stops (exit code 6) and names the process that holds it. Read-only commands run anyway:
`log`, `status`, `plan`, `time`, `progress`, `vpn`, `guide`, `agents`, `media`, `github`, `policy`,
`inventory`, `config`, `stage`.
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
  README.md  CHANGELOG.md  LICENSE  llms.txt  PROJECT.json
  docs\
    ARCHITECTURE.md                 modules, data flow, store format
    USAGE.md                        daily runbook
    SECURITY.md                     what is protected, how, honest limits, untested list
    WORKFLOW.md                     steps, time rules, checkpoints, prune
    AI.md                           optional AI providers, access request text, future MCP
    MANAGER-GUIDE.md                for management: what it does, rules, credentials, data, limits
    TROUBLESHOOTING.md              exit codes, common errors, recovery, where to look
    RELEASE.md                      readiness checklist, known limitations, release steps
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
    Test-Sanitized.ps1              leak check: files, -History for the whole git history
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
| Day logs | `%LOCALAPPDATA%\VmMaintenance\logs\vmm_<yyyyMMdd>.log` | Every line masked for secrets, then encrypted per line (store key); kept `Log.KeepDays` (30). `vmm log -Export` writes a plaintext copy to `Reports\Logs` |
| Store backups | `%LOCALAPPDATA%\VmMaintenance\data\backups\fleet_<time>.vmm` | Encrypted copies of the store, one a day at start, 14 kept |
| Error log | `%LOCALAPPDATA%\VmMaintenance\logs\errors.log` | Sanitized, 1 MB cap |
| Credentials | Process memory only, as `PSCredential` | Never written; cleared on quit. VPN credentials go only to the VPN client |

## Testing

```powershell
.\Tools\Invoke-SmokeTest.ps1                                       # offline, no Pester needed
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path .\tests -Output Detailed
.\Tools\Test-Sanitized.ps1                                         # before every commit/push
.\Tools\Test-Sanitized.ps1 -History                                # before a release: whole git history
```

Status (2.14.0, alpha): the offline smoke test (278 checks) and Pester (99 tests) pass on GitHub's Windows runners in
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
Exit codes, common errors and recovery: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Future: your work AI model with tools (MCP)

Planned, not built. An MCP server inside the module would expose a small, allow-listed set of
`vmm` functions (read fleet status, explain a host, draft a report, propose a config change) to an
AI model your organisation approves (Copilot Studio agent, Azure AI Foundry agent, or a local
model), signed in with your work account. Every change would come back as a diff that you approve
in the console; no credentials, and no write access outside the vmm config and reports folders.
Details and the access request text: [docs/AI.md](docs/AI.md).

_Last updated: 2026-11-15 22:00 UTC_
