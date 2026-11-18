<!-- SUMMARY: VmMaintenance daily runbook: install, morning (checks+staging), evening (changes), problems, end of day, tests. SECTIONS: Once:4-13 | New machines:14-18 | SQL Server updates:19-24 | Every morning business hours:25-42 | Evening weekend all steps:43-51 | Problems:52-64 | End of day:65-69 | Updates and GitHub:70-74 | Tests:75-83 -->
# Usage - daily runbook

## Once

```powershell
Get-ChildItem -Recurse . | Unblock-File
powershell -ExecutionPolicy Bypass -File .\Install.ps1     # wizard: warnings, options, smoke test
```

Then in a new terminal: `vmm`. Import hosts with `0` (or `vmm import -Path list.txt -RemoveSource`;
the plaintext list is deleted after import, names then live only in the encrypted store).

## New machines

You get a CSV with hostname or FQDN, domain, IP: `0` in the menu, drag the file in (or Enter to browse),
check the preview, confirm, let it delete the plaintext file. Then `3` Check fleet.

## SQL Server updates

`vmm fetch -Preview` lists what each SQL instance needs and what is already cached. `vmm fetch` downloads the
missing KBs once into `<share>\_Downloads`, then copies them into the host folders. Re-run it any time: nothing is
downloaded twice. One-time setup: `Install-Module dbatools -Scope CurrentUser`.

## What is next on a server (SQL or Windows)

`vmm path` (or `N` on a host) shows, from the last snapshot or Extractor result, the current Windows and SQL
Server, the workflow position and the next step with the exact file and language: SQL service pack first when the
next Windows needs it, then the in-place upgrade ISO in the OS install language, then the latest SQL CU.
`vmm path-report` (or `U` in Reports) writes the TXT + CSV for the manager e-mail.

## Every morning (business hours: checks + staging only)

1. `vmm` - header shows Lisbon time, the rule in force and today's progress.
2. `V` - VPN connected? (`vmm connect` signs in through the VPN client.)
3. `6` - enter the host admin credential for this session (or `Credentials.WindowsMode = CurrentUser`).
4. `3` - snapshot the whole fleet from the terminal, in parallel (read-only). It tries DCOM, then WinRM,
   then WinRM-SSL per host and ends with the list of hosts that need hands-on, if any.
5. `4` - staging gate (`M` = media report). Each host needs the Windows Server 2019 image in its install
   language plus its own folder on the media repository. Missing files are listed with the exact name and
   path to save them under and the hosts that need them; nothing is staged until the share is complete.
6. `1` - Plan: run Stage for every host that passed Precheck (allowed in business hours).
   Inventory: the check already filled the automatic columns; `N` shows what is missing, `I` on a host
   fills the rest with a help window per column.
7. Only the hosts the snapshot lists as hands-on: the Extractor (the snapshot already built it and put it
   on the clipboard; `E` > `B` builds it again). In RDP/RDM paste it on the host's desktop, right-click >
   Run with PowerShell, copy the `VMM_<HOST>_<time>.vmm` it leaves on the desktop to your laptop's Desktop
   or Downloads. vmm imports it by itself (`E` to do it now). `F` in the Extractor removes it from the host.

## Evening / weekend (all steps)

1. `1` Plan: SnapPreSql, ExpandDisk, Upgrade, SnapPostSql per host (SnapStart already ran in the day). Guided steps: `G` for the checklist, then `Y` to
   confirm. (Steps from inside the host are off by default: `Extractor.AllowSteps`.)
2. After the reboots: Verify (fleet check, or run the Extractor again and copy its file back: a result after
   the upgrade counts as Verify by itself).
   Then ManualCheck (`Y` after your own check, or `BYPASS` with a reason) and SnapFinal, the last step.
3. Extractor `F` (Finish) on each host where you used it.

## Problems

| Situation | Do |
|---|---|
| Access denied / no rights | `B` on the host: report is written and copied to the clipboard; answer Sent / Later / Bypass; queue moves on. `R` once access is granted |
| Stage cannot copy to a host (admin share closed, access denied) | Answer `y` when Stage offers the hands-on copy, or `T` on the host / `vmm handoff -HostName x`: pick RDP, RDM or RDCMan, paste the script on the host, back in vmm press `V`. Stage is recorded only when size and SHA256 are verified on the host |
| Change needed in business hours | Only with agreement: `OVERRIDE` + reason (logged, in the daily report) |
| Azure sign-in stuck on the tenant picker | `5` Azure (picker is turned off for the process); or `vmm azure -DeviceCode` |
| VPN up but hosts time out | `vmm vpn` shows Degraded when the probe host does not answer: DNS / split tunnel |
| Store cannot be decrypted | See SECURITY.md (DPAPI limits); `M` > `R` restores a daily backup (or `fleet.vmm.bak`), else re-import |
| Looks stuck | Watch the live log (bottom of the screen, `F2` if hidden): it names the host and step it is waiting on every 5 s. `vmm log -Follow` in a second window shows the same |
| vmm itself misbehaves | `M` > `D` diagnose; `vmm log -Level Error`; `vmm issue -FromErrorLog` sends the errors as a ticket |

## End of day

`7` Reports: `Fleet_<date>.csv/.html/.json` for your manager (also via the scheduled task).
`8` Prune: preview expired snapshots; type `DELETE` to remove them (off-hours, or override).

## Updates and GitHub

`U` in the console: `S` status, `U` update (smoke test before install), `I` report an issue from the
error log, `P` pull request from a branch of your clone (leak scan first). CLI: `vmm update`, `vmm issue`, `vmm pr`.

## Tests

```powershell
.\Tools\Invoke-SmokeTest.ps1
Invoke-Pester -Path .\tests -Output Detailed
.\Tools\Test-Sanitized.ps1      # before any commit or push
```

_Last updated: 2026-11-16 12:30 UTC_
