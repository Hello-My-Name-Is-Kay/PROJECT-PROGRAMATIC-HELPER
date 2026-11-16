<!-- SUMMARY: VmMaintenance release readiness: status, checklist, known limitations, first real run, release steps (Kay go only). SECTIONS: Status:7-15 | Readiness checklist (2.15.1):16-36 | Known limitations:37-51 | First run on real hosts (recommended before ending alpha):52-64 | Release steps (only after Kay says go):65-76 -->
# Release readiness

What has to be true before VmMaintenance leaves **alpha**, what was checked for 2.15.1, what is still open, and
the exact steps to make the release. Nothing here is done automatically: the release is made only on Kay's go.

## Status

| | |
|---|---|
| Version | 2.15.1 |
| Stage | **alpha** (`PrivateData.PSData.Prerelease = 'alpha'` in the manifest, "alpha" in the README header) |
| Automated tests | GitHub checks on Windows PowerShell 5.1 and PowerShell 7: leak scan (files and full history), offline smoke test, Pester, script analyzer (errors) |
| Real environment | **Not run yet** on a real host, Azure subscription, VPN, Lansweeper database or interactive console |

## Readiness checklist (2.15.1)

| Area | Check | State |
|---|---|---|
| Sensitive data | No host names, IPs, tenant/subscription IDs, e-mail addresses, tokens, keys or passwords in the files | Done: `Tools\Test-Sanitized.ps1` (extended in 2.14.0) clean |
| Sensitive data | Same check over the full git history, every branch, and every commit message | Done: `Test-Sanitized.ps1 -History` clean; it now runs in CI on every pull request |
| Sensitive data | Your real config and server lists checked against the repository | **Open: run `.\Tools\Test-Sanitized.ps1 -History` on your laptop** (only your laptop has the local values) |
| Sensitive data | Commit authors carry no personal e-mail | Done: every commit is authored by the bot address |
| Credentials | None stored, logged or exported; asked per session | Done: code review + existing tests (`Set-VmmSetting` refuses credential keys, log masking tests) |
| Tests | Smoke + Pester green on PS 5.1 and 7 | Done in CI for this branch (counts in the README) |
| Exits | Every command and entry script ends with the right exit code; failed and blocked steps are recorded and raised; Ctrl+C is logged; credentials are cleared; a disk expansion that stops half way puts the VMs back | Done in 2.15.0 (`tests\Exits.Tests.ps1`, smoke section 9) |
| Tests | First read-only run on a few real hosts | **Open** (see "First run on real hosts") |
| Docs | README, CHANGELOG, USAGE, WORKFLOW, ARCHITECTURE, SECURITY, AI | Done, reviewed for 2.15.1 |
| Docs | Manager guide, troubleshooting, this release page | Done (2.15.0: exit codes per command in TROUBLESHOOTING) |
| Versions | Manifest, Extractor, README, PROJECT.json and CHANGELOG agree | Done (a Pester test enforces it) |
| Repository | `.gitignore` covers configs, lists, data, keys, logs, reports, agents, `.rdp`/`.rdg`, certificates | Done |
| Repository | No dead files | Done: every private function is used, every public function exported |
| Repository | Licence | MIT (`LICENSE`), proposed so the repository can be public. **Open: Kay** confirms the employer agrees, and runs `Tools\Test-Sanitized.ps1 -History` on the laptop before switching to public |
| Delivery | `VmMaintenance.zip` and folder in the project files match the release commit | **Open**: rebuild from the merge commit (`git archive`) after the merge |
| Merge | PR #3 (2.15.0: exits, error handling, logging) merged 2026-11-16; PR for 2.15.1 (Extractor fixes) reviewed and merged | **Open: Kay** |

## Known limitations

- Untested against real systems (listed in [SECURITY.md](SECURITY.md#untested)): network checks on real hosts,
  Azure (snapshot, deallocate, resize, Run Command), the VPN client, the Lansweeper database, the interactive
  console with mouse in Windows Terminal, RDP / RDM / RDCMan launch with company policy, the Extractor and the
  handoff script on PowerShell 2.0 (Server 2008 R2).
- Single operator: the encrypted store opens only for the Windows account that created it on that laptop.
  A profile rebuild or an administrator password reset makes it unreadable (the daily reports remain).
- Extractor results and the `VMMSTAGE1` handoff report are encrypted or hashed, but not signed by the host:
  only import files you produced yourself.
- PowerShell copies a password to plain memory for a moment when handing it to CIM, SMB or SQL (platform limit).
- Group Policy with `AllSigned` needs the scripts signed with a company code-signing certificate (not included).
- The Windows Server ISO is a manual download; vmm only checks that it is on the share.
- The override in business hours is a typed confirmation plus a reason, not an approval workflow.

## First run on real hosts (recommended before ending alpha)

During business hours, read-only, two or three hosts the team knows well:

1. `.\Tools\Invoke-SmokeTest.ps1` on the laptop (Windows PowerShell 5.1 and pwsh).
2. `vmm setup`, then `vmm import -Path <csv> -Preview`, then without `-Preview`.
3. `vmm snapshot -Name <a>,<b>`, `vmm access`, `vmm stage`, `vmm media`, `vmm plan`, `vmm policy`.
4. `vmm report` and `vmm log -Export`: check that the report and the log hold nothing that should not be sent.
5. One Stage (copy into `C:\Temp`) on one host; one handoff over RDP on one host where the admin share is closed.
6. After hours, on one non-critical Azure VM with a snapshot: PreSnapshot, ExpandDisk, then Verify.

Record the results in the CHANGELOG under the release that ends alpha.

## Release steps (only after Kay says go)

1. Merge the open pull request on `main` (2.15.1).
2. On a branch: remove `Prerelease = 'alpha'` from `VmMaintenance\VmMaintenance.psd1`, drop "(alpha)" from the
   README header and from the Status table above, add the CHANGELOG entry; open a pull request; wait for green
   checks; merge.
3. Tag the merge commit: `git tag -a v<version> -m "VmMaintenance <version>"` and `git push origin v<version>`.
4. GitHub release from the tag, with the CHANGELOG entry as notes. Attach the zip built from the tag
   (`git archive --format=zip -o VmMaintenance.zip v<version>`).
5. Send the manager the [manager guide](MANAGER-GUIDE.md) and the release link.

_Last updated: 2026-11-16 04:59 UTC_
