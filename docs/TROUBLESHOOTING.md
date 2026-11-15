<!-- SUMMARY: VmMaintenance troubleshooting: first steps, exit codes, common errors by id, encrypted file recovery, log locations. SECTIONS: First steps:7-18 | Exit codes (CLI):19-30 | Common problems:31-57 | Encrypted files:58-68 | Where to look:69-78 -->
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

## Exit codes (CLI)

| Code | Meaning | What to do |
|---|---|---|
| 0 | Done | - |
| 1 | Error | Read the message; details in `errors.log` and the day log |
| 2 | Usage error (unknown command or option) | `vmm help` |
| 3 | Blocked by the time window | Run after hours, or `-Override -OverrideReason "who approved it and why"` where allowed |
| 4 | VPN down | `vmm connect`, or `Vpn.RequireForHostWork = $false` if the hosts do not need the VPN |
| 5 | Security check failed (store or result file damaged or modified) | See "Encrypted files" below |
| 6 | Another vmm is running | Close the other window; read-only commands still work |

## Common problems

| Symptom / error id | Likely cause | Fix |
|---|---|---|
| `VmmModuleMissing`, `VmmModuleLoad` | Az / dbatools module not installed, or two Az versions in one session | `Install-Module <name> -Scope CurrentUser`; open a fresh window |
| `VmmSettingMissing`, `VmmSettingPlaceholder` | A setting is empty or still `<placeholder>` from the example | `vmm setup` or `vmm set -Name <Key> -Value <value>` |
| `VmmConfigParse` | Hand-edited config has a syntax error | Compare with `config\config.example.psd1`; `Import-PowerShellDataFile <path>` shows the line |
| `VmmCredCancelled` | The credential prompt was closed | Run again and enter the account, or `Credentials.WindowsMode = CurrentUser` |
| Access is denied / `0x80070005` / `VmmAdminShare` | Account is not local admin on the host, UAC remote restrictions, SMB 445 blocked | Use an admin credential; `Test-NetConnection <host> -Port 445`; else `B` blocker report |
| RPC server is unavailable / `0x800706BA` | Host down, wrong name, DCOM blocked | `vmm access` shows which route works; WinRM or hands-on is tried next |
| No such host is known | Name does not resolve from the laptop | Use the FQDN, check the VPN, or import the host with its IP |
| `VmmVpnDown`, `VmmVpnClient` | VPN not connected, or `vpncli.exe` not found | `vmm connect`; set `Vpn.ClientPath` or `Vpn.Provider = Probe` |
| `VmmWindowBlocked` | Changing step during Mon-Fri 08:00-17:00 | Wait for the time shown, or override with a reason (not possible for disk expansion) |
| `VmmStepOrder` | The previous step is not done | Run the step it names first |
| `VmmPolicy` | Client OS, Server 2008 non-R2 or physical machine | Client OS: `vmm order -HostName x -Reason ".."` only with an order. 2008 / physical: `vmm policy -Notice` for management |
| `VmmStagingGate`, `VmmShareUnreachable` | Files missing on the media share, or share not reachable | `vmm media` lists the exact file names and paths; open the share in Explorer to test access |
| `VmmHashMismatch`, handoff verify fails | File damaged in the copy, or a different file on the host | Run the handoff again; it names the file that is wrong |
| `VmmRemoteClientMissing` | RDM / RDCMan not found | `vmm rdp -List`; set `Handoff.RdmPath` / `Handoff.RdcManPath`, or pick RDP |
| `VmmAzLogin`, `VmmAzNoSubscription`, AADSTS errors | Wrong tenant, MFA not completed, no subscription chosen | `vmm azure` (or `-DeviceCode`), `-Save` to keep the subscription |
| AuthorizationFailed | Missing Azure role on the resource group | Virtual Machine Contributor + Disk Snapshot Contributor (or Contributor) on the RG |
| ScopeLocked | Azure resource lock | `Get-AzResourceLock -ResourceGroupName <rg>`; ask the lock owner |
| Resize errors | OS disk resizes only while deallocated, never smaller | vmm deallocates first; check `Get-AzVM -Status` if it was interrupted |
| Login failed for user / `VmmSqlConnect` | Lansweeper SQL login wrong or Windows-auth only | Test in SSMS; ask the DBA |
| `VmmInstanceLocked` | Another vmm window holds the lock | Close it; the lock is released automatically when a process ends |
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

_Last updated: 2026-11-15 22:30 UTC_
