<!-- SUMMARY: VmMaintenance release history. SECTIONS: 210 - 2026-11-14:4-17 | 200 - 2026-11-14:18-23 | 100 - 2026-11-14:24-28 -->
# Changelog

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
- Security: SQL login no longer pre-filled from config (no usernames stored); prune respects the time window;
  stricter result import validation.

## 2.0.0 - 2026-11-14

- Fleet console: TUI (keyboard + mouse) and CLI, encrypted fleet store, Lisbon time rules with override,
  parallel checks, staging gate, blocker reports, RDP guides, checkpoint snapshots and prune,
  daily CSV/HTML/JSON, installer/uninstaller, smoke test, Pester tests.

## 1.0.0 - 2026-11-14

- Original ten scripts refactored into the VmMaintenance module, all environment values moved to local config.

_Last updated: 2026-11-14 03:30 UTC_
