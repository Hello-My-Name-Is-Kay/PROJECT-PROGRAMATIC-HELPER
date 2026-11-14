<!-- SUMMARY: VmMaintenance release history. SECTIONS: 221 - 2026-11-14:4-10 | 220 - 2026-11-14:11-18 | 210 - 2026-11-14:19-36 | 200 - 2026-11-14:37-42 | 100 - 2026-11-14:43-47 -->
# Changelog

## 2.2.1 - 2026-11-14

- Setup wizard: time zone accepts cities, countries and IANA ids (Lisbon, London, Portugal, Europe/Lisbon),
  case-insensitive, with a numbered pick list when ambiguous; every question says what it accepts on a wrong
  answer, `?` shows help, choices ignore case, times like 8:00 are accepted, and after 3 wrong answers the
  current value is kept instead of looping. Set-VmmSetting and the time window accept the same names.

## 2.2.0 - 2026-11-14

- GitHub integration through the GitHub CLI (no token stored): `vmm github`, `vmm update` (checks + smoke test
  before install, rollback of the clone on failure), `vmm clone`, `vmm issue` (sanitized), `vmm pr` (leak scan first).
- Console: `U` GitHub / updates menu; update notice at start (`GitHub.CheckOnStart`).
- Installer: GitHub page in the setup wizard (sign-in offer, clone folder defaults to the install source), `-Update` mode.
- GitHub Actions: leak scan, smoke test, Pester on Windows PowerShell 5.1 and PowerShell 7; script analyzer report.

## 2.1.0 - 2026-11-14

- Host agent (`VmmHostAgent.ps1`): second program run inside RDP/RDM; status, steps with reasons,
  local runs with the same time rules, sanitized log in `C:\Temp\VmmAgent`, encrypted `VMM2` export,
  Finish removes all traces. Laptop: `vmm agent`, `X` on a host, `vmm collect` reads `VMM2`.
- VPN: Cisco Secure Client (vpncli), Windows VPN, generic probe; host work stops when the VPN is down.
- Optional AI assistant: Foundry Local / Ollama (loopback only) or Azure OpenAI with Entra ID; sanitized,
  confirm-before-send, advisory only. Future MCP design in docs/AI.md.
- Setup wizard (`vmm setup`, first run, installer): warnings, validated options per page.
- Global flags (`--no-mouse`, `--no-color`, `--config`, `--debug-errors`, `--version`), feature flags,
  exit codes, sanitized error log.
- OS policy: target Windows Server 2019; client OS (Windows 10/11) skipped unless ordered (`vmm order`);
  management warnings for Windows Server 2008 (not R2) and physical machines (`vmm policy -Notice`);
  disk expansion after hours only (no override). Policy columns in the daily report and the host agent.
- README: creator, version, date and TL;DR at the top.
- Security: SQL login no longer pre-filled from config (no usernames stored); prune respects the time window;
  stricter result import validation.

## 2.0.0 - 2026-11-14

- Fleet console: TUI (keyboard + mouse) and CLI, encrypted fleet store, Lisbon time rules with override,
  parallel checks, staging gate, blocker reports, RDP guides, checkpoint snapshots and prune,
  daily CSV/HTML/JSON, installer/uninstaller, smoke test, Pester tests.

## 1.0.0 - 2026-11-14

- Original ten scripts refactored into the VmMaintenance module, all environment values moved to local config.

_Last updated: 2026-11-14 04:02 UTC_
