<!-- SUMMARY: VmMaintenance daily runbook: install, morning (checks+staging), evening (changes), problems, end of day, tests. SECTIONS: Once:4-13 | Every morning business hours:14-25 | Evening / weekend all steps:26-32 | Problems:33-42 | End of day:43-47 | Updates and GitHub:48-52 | Tests:53-61 -->
# Usage - daily runbook

## Once

```powershell
Get-ChildItem -Recurse . | Unblock-File
powershell -ExecutionPolicy Bypass -File .\Install.ps1     # wizard: warnings, options, smoke test
```

Then in a new terminal: `vmm`. Import hosts with `0` (or `vmm import -Path list.txt -RemoveSource`;
the plaintext list is deleted after import, names then live only in the encrypted store).

## Every morning (business hours: checks + staging only)

1. `vmm` - header shows Lisbon time, the rule in force and today's progress.
2. `V` - VPN connected? (`vmm connect` signs in through the VPN client.)
3. `6` - enter the host admin credential for this session (or `Credentials.WindowsMode = CurrentUser`).
4. `3` - check the whole fleet in parallel (read-only).
5. `4` - staging gate. Missing files are listed with the exact share path to put them in and where to
   download them; nothing is staged until the share is complete.
6. `1` - Plan: run Stage for every host that passed Precheck (allowed in business hours).
7. Hosts that do not answer: open the host (`2`, Enter), press `X` to build the host agent, run it in
   RDP/RDM, export, then `P` on the laptop.

## Evening / weekend (all steps)

1. `1` Plan: PreSnapshot, ExpandDisk, Upgrade per host. Guided steps: `G` for the checklist or use the
   host agent, then `Y` to confirm.
2. After the reboots: Verify (fleet check, or agent menu 3 > Verify, then export).
3. Agent Finish on each host when its cycle is done.

## Problems

| Situation | Do |
|---|---|
| Access denied / no rights | `B` on the host: report is written and copied to the clipboard; answer Sent / Later / Bypass; queue moves on. `R` once access is granted |
| Change needed in business hours | Only with agreement: `OVERRIDE` + reason (logged, in the daily report) |
| Azure sign-in stuck on the tenant picker | `5` Azure (picker is turned off for the process); or `vmm azure -DeviceCode` |
| VPN up but hosts time out | `vmm vpn` shows Degraded when the probe host does not answer: DNS / split tunnel |
| Store cannot be decrypted | See SECURITY.md (DPAPI limits); restore `fleet.vmm.bak` or re-import |

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

_Last updated: 2026-11-14 03:48 UTC_
