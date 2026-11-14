<!-- SUMMARY: VmMaintenance security: rules, protections per data type, honest limits, untested list. SECTIONS: Rules:6-13 | How:14-42 | Honest limits:43-62 | Untested:63-72 -->
# Security

Rules this project follows, how each is implemented, and the honest limits.

## Rules

1. No usernames or passwords are stored. Each session asks again.
2. Credentials are typed by you only and are never readable while in use.
3. Sensitive data is encrypted on disk and protected in memory.
4. No environment data (hosts, IPs, tenant/subscription IDs, company names) in the repository.
5. Information extracted from hosts travels over the company VPN and is treated as business data.

## How

| Data | Where | Protection |
|---|---|---|
| Host credentials, SQL login | Process memory | `PSCredential` (SecureString), asked once per session, disposed on quit. Never logged, exported or written. `Set-VmmSetting` refuses credential-like keys |
| VPN credentials | VPN client only | Typed into Cisco Secure Client / Windows dialog; never pass through vmm |
| GitHub sign-in | GitHub CLI (Windows Credential Manager) | vmm never reads the token (`gh auth token` is never called); issue/PR text is masked and previewed; PRs only after the leak scan |
| Azure sign-in | Az.Accounts token cache | Microsoft's own cache; vmm stores no tokens. AI tokens are fetched per request and dropped |
| Fleet store `fleet.vmm` | `%LOCALAPPDATA%\VmMaintenance\data` | AES-256-CBC + HMAC-SHA256 (encrypt-then-MAC, constant-time check), atomic write + `.bak` |
| Store key `store.key` | same | 64 random bytes, DPAPI CurrentUser + entropy |
| Agent key `agent.key` | same | RSA-3072 private key XML, DPAPI CurrentUser; never in the Windows key container |
| Agent results `VMM2\|...` | clipboard, in transit | RSA-OAEP wraps a random 64-byte key; AES-256-CBC + HMAC-SHA256 |
| Host agent log | `C:\Temp\VmmAgent` on the host | Sanitized lines only; folder ACL: Administrators, SYSTEM, you (by SID); removed by Finish |
| Reports | `%LOCALAPPDATA%\VmMaintenance\Reports` | Plaintext on purpose (for your manager); no credentials |
| Inventory | Fleet store (encrypted); export `Reports\Inventory\*.csv` plaintext | Typed values are control-char stripped, length-capped and masked; host-side columns accepted only for known automatic keys, IP must be IPv4 |
| Error log | `%LOCALAPPDATA%\VmMaintenance\logs\errors.log` | Messages pass `Protect-VmmLogText`; 1 MB cap |

Input from hosts is untrusted: result lines are size-limited, MAC-checked, field-validated,
length-capped and accepted only for hosts already in your fleet.

Errors: every function throws a structured error (what, target, cause, fix). The CLI catches
everything at the top, prints only the sanitized message, writes the sanitized log line and returns a
specific exit code. The console catches per action and returns to the menu. The host agent never shows
stack traces.

Repository: `.gitignore` excludes configs, lists, data, keys, reports and agents;
`Tools\Test-Sanitized.ps1` fails the commit/push if a GUID, IPv4 or any value from your local config
or server lists appears in a tracked file.

## Honest limits

- **SecureString** protects the password buffer, but PowerShell and .NET copy it to plain memory briefly
  when it is handed to CIM, SMB (`New-PSDrive`) or SQL. A memory dump of the running process during that
  moment could reveal it. This is a platform limit.
- **DPAPI** binds data to your Windows account on this laptop. An administrator password reset or a
  rebuilt profile makes `fleet.vmm` and `agent.key` unreadable; daily exports are your backup.
  Anyone running code as you, while you are logged on, can also decrypt them.
- **Agent results** are confidential (only your laptop can read them) and tamper-evident, but not
  authenticated: anyone holding a copy of an agent (which contains the public key) could forge a
  result. The laptop validates every field; still, only import lines you produced yourself.
- **Built agent files** contain one host's plan in plaintext (share path, upgrade command, step notes,
  never credentials). Finish removes the copy on the host; the laptop copy is replaced on the next export.
- **Clipboard**: result lines and agents pass through the RDP clipboard. Finish clears the host clipboard;
  Windows clipboard history (Win+V) on the laptop may keep a copy if you have it turned on.
- **ExecutionPolicy Bypass** is used by the `vmm` launcher and to start the agent on hosts (process scope
  only). If Group Policy enforces AllSigned, sign the scripts with your code-signing certificate.
- **Reports** are plaintext by design.
- **Override** is a typed confirmation plus a reason, logged; it is not an approval workflow.

## Untested

Verified by GitHub checks (Windows PowerShell 5.1 and PowerShell 7): syntax of every script, module
import and exports, C# console helper compile, time rules, OS policy, PSD1 round trip, DPAPI + AES/HMAC
store, tamper detection, host agent encryption to the laptop key, Pester tests.
Not verified: mouse input in Windows Terminal and the interactive UI; `Update-AzConfig -LoginExperienceV2`; `Invoke-AzVMRunCommand -ScriptString`;
`Set-Clipboard -Path`; `vpncli.exe` output parsing on your Cisco Secure Client version; Foundry Local's
port and model names; the host agent on PowerShell 2.0 (Server 2008 R2) and the `icacls` ACL; Pester 5 tests.

_Last updated: 2026-11-14 04:30 UTC_
