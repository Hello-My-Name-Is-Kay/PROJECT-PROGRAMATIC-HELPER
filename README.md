<!-- SUMMARY: VmMaintenance: Windows PowerShell fleet console (vmm) + remote host agent for pre-upgrade server maintenance; encrypted store, no stored credentials, environment-agnostic. SECTIONS: At a glance:18-34 | Quick start:35-53 | Host agent the program on th:54-72 | Console UI:73-102 | CLI:103-138 | Workflow per host:139-152 | Directory tree:153-182 | Where your data lives never :183-196 | Testing:197-209 | Errors:210-223 | Future your work AI model wi:224-233 -->
# VmMaintenance

Terminal fleet console for Windows server maintenance ahead of in-place OS upgrades.
Two PowerShell programs:

| Program | Runs on | Role |
|---|---|---|
| `vmm` (module VmMaintenance) | your laptop | The "big planet": all hosts, encrypted store, keyboard-and-mouse text UI + CLI, parallel checks, staging, Azure disk/snapshot work, VPN, reports for your manager |
| `VmmHostAgent.ps1` | one remote host, inside RDP/RDM | Copied to the host's desktop: extracts that host's info, shows current and future steps and *why* each is or is not available, runs the steps that must happen inside the host, keeps a sanitized log, exports an encrypted result back to the laptop, removes itself at the end |

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
| Missing install files | Staging gate lists exactly which file is missing, where it must go on the share, and where to download it |
| Access denied / blocked | Ready-to-send manager report (copied to clipboard). You must answer "contacted manager?" - Sent / Later / Bypass. The tool never sends email |
| No remote access | RDP/RDM guide: numbered steps, confirm each, paste the collector line back |
| Azure sign-in stuck on "Select a tenant and subscription" | Picker turned off for the process, tenant + subscription passed explicitly; device-code sign-in available |
| Rollback | Checkpoint snapshot after each successful changing step (Azure VMs); prune expired ones at the end, preview first |
| Work inside a host | Host agent: status, steps with reasons, run, history, encrypted export, Finish removes every trace |
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

To remove: `.\Uninstall.ps1` (asks separately before deleting config, encrypted data and reports).

## Host agent (the program on the remote host)

1. On the laptop: open the host (Fleet, Enter) and press `X`, or run `vmm agent -HostName srv01`.
   The file `VmmAgent_SRV01_<time>.ps1` is written and, in Windows PowerShell 5.1, put on the clipboard as a file.
2. In RDP/RDM: paste it on the host's desktop, open PowerShell (as administrator for change steps) and run:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\VmmAgent_SRV01_<time>.ps1"
   ```
   `-ExecutionPolicy Bypass` applies to that one process; nothing on the host is reconfigured.
3. Menu: `1` Status, `2` Steps (current / future / why), `3` Run a step, `4` History, `5` Export, `6` Finish.
4. Export copies a `VMM2|...` line. On the laptop press `P` on the host, or `vmm collect` (reads the clipboard).
5. End of the cycle: `6` Finish removes `C:\Temp\VmmAgent`, the agent file and the clipboard content.
   Staged install files in `C:\Temp` are not touched.

The agent works on Windows PowerShell 2.0 to 5.1, refuses change steps for a plan made for another host,
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
| 4 | Staging gate: are all install files on the network share? |
| 5 | Azure: sign in, pick tenant + subscription |
| 6 | Credentials: set or clear this session's Windows / SQL credentials |
| 7 | Reports: daily CSV + HTML, blocker reports |
| 8 | Snapshots: preview and prune expired |
| 9 | Settings: every option, saved to your local config |
| 0 | Import hosts |
| V | VPN status, connect, disconnect |
| A | Assistant (optional AI) |
| W | Setup wizard |
| H / Q | Help / Quit (clears session credentials) |

On a host screen: Enter run step, `G` RDP guide, `X` host agent, `P` paste result, `Y` confirm a
guided step, `B` blocker report and move on, `R` resolve, `L` mstsc, `H` hold, `C` check.

Arrows, PgUp/PgDn, Home/End move; Enter opens; Esc goes back; letters run the actions shown
in the footer. Mouse: click selects, double-click opens, wheel scrolls (classic console and
Windows Terminal; QuickEdit is turned off while the UI runs and restored on exit).

## CLI

Every UI action has a command. `vmm help` prints this list.

| Command | Does |
|---|---|
| `vmm status [-Filter srv*]` | Fleet table |
| `vmm check [-Name a,b] [-Azure]` | Parallel read-only check |
| `vmm import -Path list.txt [-RemoveSource]` | Add hosts (names only) |
| `vmm remove -Name a,b` | Remove hosts |
| `vmm plan` | Work queue: next step per host and whether it is allowed now |
| `vmm next [-HostName x] [-All]` | Run the next automatic step |
| `vmm step -HostName x -Step Upgrade` | Run one step (`-Override -OverrideReason ".."` in business hours) |
| `vmm guide -HostName x -Step Upgrade` | RDP/RDM checklist |
| `vmm collect -Line "VMM1..."` | Record the collector result from inside RDP |
| `vmm stage` | Staging gate: share reachable, files present, hashes |
| `vmm blocker -HostName x -Step y -Message ".."` | Manager report for an access problem |
| `vmm resolve -HostName x` | Access granted, unblock |
| `vmm report [-Open]` | Daily CSV + HTML + JSON |
| `vmm progress` / `vmm time` | Today vs target / clock and window |
| `vmm prune [-Apply]` | Expired snapshots, preview unless `-Apply` |
| `vmm azure [-Save] [-DeviceCode]` | Sign in and pick the subscription |
| `vmm set -Name Key -Value v` | Change a setting |
| `vmm config` | Show / reload the config |
| `vmm agent -HostName x` / `vmm agent -Generic` | Build the host agent |
| `vmm vpn` / `vmm connect` / `vmm disconnect` | VPN |
| `vmm ai -Prompt ".." [-IncludeFleet]` | Optional assistant |
| `vmm setup [-Page Vpn]` | Setup wizard |

Global flags: `--no-mouse`, `--no-color`, `--config <file>`, `--debug-errors`, `--version`.
Exit codes: 0 ok, 1 error, 2 usage, 3 blocked by the time window, 4 VPN down, 5 security check failed.
Feature flags in the config (`Features.HostAgent`, `Features.Vpn`, `Features.Ai`) switch whole areas on or off.

The classic one-task scripts (`Scripts\Expand-AzOsDisk.ps1`, `CreateSnapshots.ps1`, ...) still
work and honour the same time window. See [docs/USAGE.md](docs/USAGE.md).

## Workflow per host

| # | Step | Class | Business hours | Off-hours / weekend | Checkpoint after |
|---|---|---|---|---|---|
| 1 | Precheck | Read-only | Yes | Yes | No |
| 2 | Stage | Staging | Yes (into `C:\Temp`) | Yes | No |
| 3 | PreSnapshot | Change | Override only | Yes | Is the snapshot |
| 4 | ExpandDisk | Change | Override only | Yes | Yes (Azure) |
| 5 | Upgrade | Change | Override only | Yes | Yes (Azure) |
| 6 | Verify | Read-only | Yes | Yes | No |
| - | Prune | Change | Override only | Yes | - |

Details and the snapshot-after-each-step answer: [docs/WORKFLOW.md](docs/WORKFLOW.md).

## Directory tree

```
VmMaintenance\
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

Status: written and statically checked (bracket balance, ASCII, leak scan). It has not yet been
run in a real PowerShell session; run the smoke test first. Known untested areas are listed in
[docs/SECURITY.md](docs/SECURITY.md).

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

_Last updated: 2026-11-14 03:30 UTC_
