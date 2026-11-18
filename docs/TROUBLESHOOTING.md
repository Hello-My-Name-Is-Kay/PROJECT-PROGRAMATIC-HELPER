<!-- SUMMARY: VmMaintenance troubleshooting: first steps, exit codes, common errors by id, encrypted file recovery, log locations. SECTIONS: First steps:7-18 | Exit codes vmm and the entry:19-52 | Common problems:53-91 | Encrypted files:92-102 | Where to look:103-112 -->
# Troubleshooting

Every error vmm raises has the same shape: what failed, on which target, the raw error, the likely cause and the
fix. Start with the fix it prints. This page is for when that is not enough.

## First steps

1. Read the last errors: `vmm log -Level Error` (or `F3` in the console).
2. Check vmm itself: `vmm maint -Action Diagnose` (modules, config, data folder, store, keys, lock).
3. Check the basics shown in the header: VPN (`V`), credentials (`6`), Azure sign-in (`vmm azure`), time window
   (`vmm time`).
4. Still stuck: `vmm log -Export` writes a plaintext copy of today's log to `Reports\Logs` for a ticket, and
   `vmm issue -FromErrorLog` drafts a GitHub issue from the error log (masked, shown before it is sent).
   Remove host names and IPs from anything you paste outside the company.

Run with `--debug-errors` to see the file and line of an unexpected (non-vmm) error.

## Exit codes (vmm and the entry scripts)

| Code | Meaning | What to do |
|---|---|---|
| 0 | Done | - |
| 1 | Error | Read the message; details in `errors.log` and the day log |
| 2 | Usage error (unknown command or option) | `vmm help` |
| 3 | Blocked by the time window | Run after hours, or `-Override -OverrideReason "who approved it and why"` where allowed |
| 4 | VPN down | `vmm connect`, or `Vpn.RequireForHostWork = $false` if the hosts do not need the VPN |
| 5 | Security check failed (store or result file damaged or modified) | See "Encrypted files" below |
| 6 | Another vmm is running | Close the other window; read-only commands still work |

The scripts in `Scripts\` return the same codes. 0 means everything asked was done. A command that works on
several items finishes all of them, then ends with the error below when any failed; the items that worked are
recorded. Ctrl+C is logged as `INTERRUPTED`; a change step stopped that way is recorded as `Failed`: check the
host before running it again.

| Error id | Exit | From | What to do |
|---|---|---|---|
| `VmmStepFailed`, `VmmStepBlocked` | 1 | `vmm step`, console step keys | The result is recorded on the host; retry, follow the guide, or send the blocker report |
| `VmmNextStepFailed` | 1 | `vmm next` | Every failed or blocked host is named and recorded; `vmm plan` shows them |
| `VmmSnapshotIncomplete` | 1 | `CreateSnapshots.ps1`, SnapStart, SnapPreSql, SnapPostSql, SnapFinal | A VM or disk has no snapshot (listed); run it again |
| `VmmExpandIncomplete` | 1 | `Expand-AzOsDisk.ps1`, ExpandDisk | `Results_<time>.csv`: ExtendCheck = extend C: by hand; power state differs = fix it in the Azure portal |
| `VmmMediaIncomplete` | 1 | `AzureMountISO.ps1`, `AzureUnmountISO.ps1` | The table names the VMs; run again for those |
| `VmmPruneIncomplete` | 1 | `vmm prune -Apply`, `Remove-ExpiredSnapshots.ps1` | Only expired snapshots are deleted; fix the cause (often ScopeLocked) and run again |
| `VmmRestoreDiskIncomplete` | 1 | `Snapshot2Disk.ps1` | Rows marked Failed: no snapshot found, or the disk could not be created |
| `VmmFetchIncomplete` | 1 | `vmm fetch` | The downloads or copies that failed are listed |
| `VmmInboxFailed` | 1 | `vmm inbox` | The file stays where it is; build a fresh extractor for that host. A file that failed its integrity check gives `VmmAgentResultRejected` (exit 5) |
| `VmmHandoffNotVerified` | 1 | `vmm handoff -VerifyOnly`, `-Report` | A file is missing or wrong on the host (named) |
| `VmmVpnDown` | 4 | `vmm connect`, any host work | Finish the sign-in in the VPN client, then `vmm vpn` |
| `VmmCleanIncomplete`, `VmmSourceNotRemoved` | 1 | `vmm maint -Action CleanTemp`, `vmm import -RemoveSource` | The files that could not be deleted are named; close what holds them |
| `VmmInstanceLockFile` | 1 | any command that changes something | The lock file cannot be opened (data folder missing or not writable): `vmm maint -Action Diagnose` |
| `VmmAiUnsafe` | 1 | `vmm ai`, `vmm issue` | Nothing was sent: the fleet store could not be read to mask host names. `vmm maint -Action CheckStore` |

## Common problems

| Symptom / error id | Likely cause | Fix |
|---|---|---|
| `VmmModuleMissing`, `VmmModuleLoad` | Az / dbatools module not installed, or two Az versions in one session | `Install-Module <name> -Scope CurrentUser`; open a fresh window |
| `VmmSettingMissing`, `VmmSettingPlaceholder` | A setting is empty or still `<placeholder>` from the example | `vmm setup` or `vmm set -Name <Key> -Value <value>` |
| `VmmConfigParse` | Hand-edited config has a syntax error | Compare with `config\config.example.psd1`; `Import-PowerShellDataFile <path>` shows the line |
| `VmmWorkflowUnknown` | `vmm ticket -Workflow` name not found or ambiguous | `vmm workflows` lists the names; `default` follows the DEFAULT workflow |
| `VmmLibraryLeak` | The library export still contains a fleet host name | Edit the known fix or action that names it (workflow manager `K`), then export again |
| `VmmLibraryInvalid`, `VmmLibraryMissing` | Not a vmm library file / share not reachable | Export it again; check the VPN and `Workflow.LibraryPath` |
| `VmmRunbookResult` | No `VMMW1` line in what was pasted | Copy the whole `VMMW_<HOST>_<time>.txt` from the host desktop, or `vmm runbook-import -Path <file>` |
| A failure you cannot fix (Azure role, VPN, firewall) | Access or a setting only IT can change | `T` after the failed action, or `vmm ticket-it -FromErrorLog`: advice + ticket text in `Reports\Tickets` and on the clipboard |
| `VmmCredCancelled` | The credential prompt was closed | Run again and enter the account, or `Credentials.WindowsMode = CurrentUser` |
| Access is denied / `0x80070005` / `VmmAdminShare` | Account is not local admin on the host, UAC remote restrictions, SMB 445 blocked | Use an admin credential; `Test-NetConnection <host> -Port 445`; else `B` blocker report |
| RPC server is unavailable / `0x800706BA` | Host down, wrong name, DCOM blocked | `vmm access` shows which route works; WinRM or hands-on is tried next |
| No such host is known | Name does not resolve from the laptop | Use the FQDN, check the VPN, or import the host with its IP |
| `VmmVpnDown`, `VmmVpnClient` | VPN not connected, or `vpncli.exe` not found | `vmm connect`; set `Vpn.ClientPath` or `Vpn.Provider = Probe` |
| `VmmWindowBlocked` | Changing step during Mon-Fri 08:00-17:00 | Wait for the time shown, or override with a reason (not possible for disk expansion) |
| `VmmStepOrder` | The previous step is not done | Run the step it names first |
| `VmmStepOrder` on SnapPostSql, Upgrade `Launched` | Run Command started the upgrade; vmm cannot tell when it ended | When the host is back and setup is done: `vmm step -HostName x -Step Upgrade -Confirmed` |
| `VmmGuided` on ManualCheck | The manual check needs your answer | Check the host, then `-Confirmed` (`Y`), or `-Bypass -BypassReason '..'` (`BYPASS`) |
| `VmmBypassReason`, `VmmStepUsage` | Bypass reason under 10 characters; `-Decline` / `-Bypass` on the wrong step | `-Decline` is for SnapStart only, `-Bypass` for ManualCheck only |
| `VmmSnapshotCheck` (warning) | vmm could not list the VM's recent snapshots | A full new set is taken instead; check the host's Azure mapping (`vmm azure`) |
| `VmmPolicy` | Client OS, Server 2008 non-R2 or physical machine | Client OS: `vmm order -HostName x -Reason ".."` only with an order. 2008 / physical: `vmm policy -Notice` for management |
| `VmmStagingGate`, `VmmShareUnreachable` | Files missing on the media share, or share not reachable | `vmm media` lists the exact file names and paths; open the share in Explorer to test access |
| `VmmHashMismatch`, handoff verify fails | File damaged in the copy, or a different file on the host | The damaged copy is deleted; run Stage (or the handoff) again; it names the file that is wrong |
| Warning `vmm could not write its log file` | Logs folder not writable, disk full, or the data key unreadable | The work goes on and the session stays in the on-screen log; `vmm maint -Action Diagnose` (row `Log writes`) |
| `VmmRemoteClientMissing` | RDM / RDCMan not found | `vmm rdp -List`; set `Handoff.RdmPath` / `Handoff.RdcManPath`, or pick RDP |
| `VmmAzLogin`, `VmmAzNoSubscription`, AADSTS errors | Wrong tenant, MFA not completed, no subscription chosen | `vmm azure` (or `-DeviceCode`), `-Save` to keep the subscription |
| AuthorizationFailed | Missing Azure role on the resource group | Virtual Machine Contributor + Disk Snapshot Contributor (or Contributor) on the RG |
| ScopeLocked | Azure resource lock | `Get-AzResourceLock -ResourceGroupName <rg>`; ask the lock owner |
| Resize errors | OS disk resizes only while deallocated, never smaller | vmm deallocates first; check `Get-AzVM -Status` if it was interrupted |
| Login failed for user / `VmmSqlConnect` | Lansweeper SQL login wrong or Windows-auth only | Test in SSMS; ask the DBA |
| `VmmInstanceLocked` | Another vmm window holds the lock | Close it; the lock is released automatically when a process ends |
| Extractor says "No laptop key in this file: nothing saved" | The file run on the host is the repository template (`VmMaintenance\Resources\VmmHostAgent.ps1`), which holds no key | Build the host copy on the laptop: `vmm extractor` (one file for every host, also on the clipboard; file in `%LOCALAPPDATA%\VmMaintenance\agents`). Copy that file to the host |
| Extractor (`-Extract`) exits 2 | The result file is saved, but some reads on the host failed | Normal on a restricted host: the failed reads are `Problem=` lines in the result and the rest is complete. Exit 1 = nothing was saved |
| `VmmAgentResult`, `VmmCollectorName` | Extractor result incomplete, from another laptop, or tampered | Run the Extractor again on the host and copy the whole file |
| Scripts blocked by policy | Downloaded files still marked, or Group Policy enforces AllSigned | `Get-ChildItem -Recurse . \| Unblock-File`; for AllSigned, sign the scripts with your code-signing certificate |

## Encrypted files

- `VmmStoreIntegrity` (exit 5): the fleet store or a backup failed its HMAC check. Restore the last backup:
  `vmm maint -Action ListBackups`, then `vmm maint -Action Restore -BackupFile <file>`. One backup a day is
  made automatically.
- `VmmDpapi`: the data key belongs to another Windows account or machine, or your DPAPI master key changed
  (password reset by an administrator). It cannot be recovered. Run `Uninstall.ps1 -RemoveData`, reinstall and
  re-import your host list; yesterday's daily report has the progress.
- `VmmAgentKey`: delete `agent.key`; a new one is made on the next Extractor build. Extractors built before must
  be built again.

## Where to look

| File | Content |
|---|---|
| `%LOCALAPPDATA%\VmMaintenance\logs\vmm_<yyyyMMdd>.log` | Day log, encrypted per line: read with `vmm log` |
| `%LOCALAPPDATA%\VmMaintenance\logs\errors.log` | Sanitized error details (1 MB cap) |
| `%APPDATA%\VmMaintenance\config.psd1` | Your settings (`vmm config`) |
| `%LOCALAPPDATA%\VmMaintenance\data\` | Encrypted store, keys, backups, `vmm.lock` |

_Last updated: 2026-11-18 00:02 UTC_
