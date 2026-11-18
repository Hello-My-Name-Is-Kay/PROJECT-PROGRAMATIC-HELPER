<!-- SUMMARY: VmMaintenance guide for management: purpose, enforced rules, credentials, data protection, logging, RDP fallback, status/limits. SECTIONS: What it is:7-34 | Rules built into the tool:35-48 | Credentials:49-65 | Where the data is and how it:66-81 | Logging and accountability:82-90 | When the network route fails:91-101 | Status and known limitations:102-116 | Who to ask:117-122 -->
# VmMaintenance - guide for management

A two-page overview of what this tool is, what it is allowed to do, and how it protects company data.
Technical detail is in the [README](../README.md) and the other files in `docs\`.

## What it is

`vmm` is a PowerShell tool that one engineer runs on their own Windows laptop to prepare a fleet of Windows
servers and Azure VMs for an in-place upgrade to **Windows Server 2019**. It does not replace any company
system; it organises the work, checks every server the same way, and keeps a record of what was done.

It has two parts:

| Part | Runs on | What it does |
|---|---|---|
| **Manager** (`vmm`) | The engineer's laptop | Checks servers over the network (read-only), checks the install files on the share, copies them to `C:\Temp` on each server, runs the Azure steps (snapshot, disk size), tracks every server's progress, writes the daily report |
| **Extractor** (a `.ps1` file) | One server, inside a remote desktop session | Only for servers the laptop cannot reach over the network: reads the same facts on the server and leaves one encrypted file to bring back. Removes itself at the end |

Per server, the steps are always the same and always in this order:
**Precheck > SnapStart > Stage > SnapPreSql > ExpandDisk > Upgrade > SnapPostSql > Verify > ManualCheck > SnapFinal**.
A step cannot run before the one before it has succeeded. On an Azure VM, a copy of every disk (a snapshot) is
taken at four points: when work starts (unless one was taken in the last hour), just before the steps that stop
or change SQL Server, just after them, and as the very last step after the engineer has checked the server by
hand. Any of these copies can be used to roll the server back.

Since 2.19.0 every server is also a **ticket** with a state (new, in progress, failed, blocked, on hold,
excluded, done), a workflow, a priority and an assignee, with counters per state and per workflow and how many were
finished today. When a step fails, the engineer sees the fixes colleagues recorded for the same error; when the fix
needs someone else (an Azure role, VPN, firewall, share access), the tool writes a ready-to-send ticket for that
person with the exact error, the access requested and the impact. The engineer sends it; the tool never sends
e-mail. Workflows other than the standard ten steps (for example a read-only check round) can be defined and
shared between engineers, without any server names in the shared file.

## Rules built into the tool

These are enforced by the code, not left to the operator's memory.

| Rule | How it is enforced |
|---|---|
| Target is Windows Server 2019 | Every server is classified by its OS; the plan only leads towards 2019 |
| Client operating systems (Windows 10/11) are not touched | Refused unless an explicit order is recorded for that machine (`vmm order`, with a written reason of at least 10 characters, logged) |
| Windows Server 2008 (not R2) and physical machines | Not worked on silently: the tool produces a note for management (`vmm policy -Notice`). 2008 R2 is supported |
| Business hours, Mon-Fri 08:00-17:00 Lisbon time | Only read-only checks and copying files into `C:\Temp` are allowed. Any changing step is blocked. An override needs the word `OVERRIDE` typed plus a written reason; it is logged |
| Disk expansion | After hours only, with no override: the VM is shut down, the disk is resized in Azure, the VM is started again |
| Snapshots before changes | A rollback snapshot of every disk is taken before the changing steps; expired snapshots are removed later, after a preview |
| Access problems are escalated, not worked around | When access is denied, the tool writes a ready-to-send report for management and asks whether it was sent. It never sends e-mail itself; the engineer sends it |

## Credentials

- **No user name or password is ever stored** by the tool: not on disk, not in the logs, not in reports,
  not in the source code. They are asked for again in every session and kept only in memory until the tool
  closes.
- Two ways to sign in to servers (setting `Credentials.WindowsMode`):
  - `Prompt` (default): the engineer types an administrator account once per session. It is used for that
    session only and is used instead of the engineer's own Windows login.
  - `CurrentUser`: the tool uses the engineer's own logged-on Windows account and asks for nothing.
- The Lansweeper database login is asked separately, also per session.
- VPN credentials are typed into the VPN client itself (Cisco Secure Client or Windows); the tool never
  sees them.
- Azure uses Microsoft's own sign-in (Az PowerShell, with multi-factor authentication); the tool keeps no
  tokens.
- When a remote desktop session is needed (RDP, Devolutions RDM or RDCMan), the tool opens the client but
  passes no account or password to it.

## Where the data is, and how it is protected

Nothing about the company environment (server names, IP addresses, Azure tenant or subscription IDs,
company names) is part of the program or its source code. It lives only on the engineer's laptop:

| Data | Protection |
|---|---|
| Server list and every server's status | Encrypted file (AES-256 + HMAC-SHA256), key locked to the engineer's Windows account on that laptop (DPAPI) |
| Day log of everything the tool did | Every line is masked for secrets, then encrypted. Kept 30 days |
| Results from the Extractor | Encrypted on the server to a key only the engineer's laptop holds (RSA-3072 + AES-256) |
| Daily report for management | Plain text (CSV, HTML), on purpose, so it can be sent. Contains no credentials |
| Settings | Plain text, no secrets (the tool refuses to save anything that looks like a credential) |

Uninstalling (`Uninstall.ps1`) removes the program; it asks separately before deleting the settings, the
encrypted data and the reports.

## Logging and accountability

- Every command, every step, every answer the engineer gives, every override and its reason, and every error
  is written to the encrypted day log, with time and result.
- Readable copy on request: `vmm log -Export` (for a ticket or an audit).
- Daily report: `vmm report` writes CSV + HTML + JSON with today's progress against the target (10 servers a
  day), what is blocked and why. The engineer e-mails it; the tool does not send e-mail.
- Only one copy of the tool can change data at a time, so two windows cannot overwrite each other's work.

## When the network route fails: remote desktop fallback

1. The tool first tries to read and stage every server from the laptop over the network (DCOM, then WinRM,
   then WinRM over SSL). This is read-only.
2. If no route works, it does not guess. For reading, it builds the Extractor; for staging files, it offers a
   guided hands-on session over RDP, Devolutions RDM or RDCMan. It puts a short copy-and-check script on the
   clipboard and lists every file with its size and SHA256 hash.
3. Back on the laptop, the files on the server are **verified** (hash read on the server, or size as a last
   resort if allowed). The Stage step is only marked done when every file is correct; the record says it was
   done by hand and how it was checked.

## Status and known limitations

- **Version 2.19.0, alpha.** The tool has passed its automated tests (about 350 offline checks and 140 unit
  tests) on Windows PowerShell 5.1 and PowerShell 7 on GitHub's Windows machines. 2.15.0 checked how every
  command ends: an unfinished or failed job is reported as failed, and a disk expansion that stops half way puts
  the servers back in their power state.
- **It has not yet been run against a real server, a real Azure subscription, the company VPN or the
  Lansweeper database.** The first runs should be read-only (`vmm snapshot`, `vmm stage`, `vmm plan`) on a
  few servers, during business hours, before any changing step is used.
- Remote desktop clients, company Group Policy (for example a signed-scripts-only policy) and PowerShell 2.0
  on Windows Server 2008 R2 are also untested. The full list is in [SECURITY.md](SECURITY.md#untested) and
  [RELEASE.md](RELEASE.md#known-limitations).
- The tool is operated by one engineer on one laptop. The encrypted data cannot be opened from another
  account or machine; the daily reports are the shared record.

## Who to ask

The tool's author and operator: Kay. Problems are logged and can be reported as an issue in the project's
GitHub repository (public, so anyone can read the issue) with `vmm issue -FromErrorLog` (the text is masked and shown for approval before it is sent).

_Last updated: 2026-11-18 00:02 UTC_
