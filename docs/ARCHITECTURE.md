<!-- SUMMARY: VmMaintenance architecture: two programs, module layout, state, file formats, step flow, extension points. SECTIONS: Two programs:4-20 | Module layout:21-33 | State:34-45 | Formats:46-54 | Flow of one step:55-64 | Code flags:65-69 | Extension points:70-77 -->
# Architecture

## Two programs

```
 LAPTOP  (vmm, module VmMaintenance)                        REMOTE HOST (inside RDP/RDM)
 +-------------------------------------------+              +-------------------------------+
 | TUI (keyboard+mouse)    CLI (vmm <cmd>)   |              | VmmHostAgent.ps1 (PS 2.0-5.1) |
 |            \               /              |   agent .ps1 |  status / steps + why / run   |
 |        Public functions (one per file)    | -----------> |  sanitized log C:\Temp\VmmAgent|
 |   time window | workflow | VPN | AI | ... |   (RDP copy) |  Finish = remove all traces   |
 |        Private helpers (one per file)     |              +-------------------------------+
 |  encrypted store | DPAPI keys | RSA key   | <-----------  VMM2|<RSA+AES+HMAC> result line
 +-------------------------------------------+   clipboard
      |  CIM/DCOM, SMB C$  (over VPN)   |  Az PowerShell (Azure)   |  SQL (Lansweeper)
      v                                 v                          v
   fleet hosts                     Azure VMs, disks, snapshots   inventory
```

## Module layout

| Folder | Content |
|---|---|
| `VmMaintenance.psm1` | Loader: dot-sources `Private\*.ps1` then `Public\*.ps1`, exports Public by file name |
| `VmMaintenance.psd1` | Manifest; `FunctionsToExport` matches `Public\` (checked by smoke test and Pester) |
| `Public\` | One exported function per file: user-facing commands |
| `Private\` | Helpers and TUI screens (`Show-Vmm*Screen`), one per file |
| `Resources\` | `VmmHostAgent.ps1` (program 2), `VmmConsoleInput.cs` (mouse), `LansweeperDiskSpace.sql` |

Naming: every function uses the `Vmm` noun prefix. Errors are built with `New-VmmErrorRecord`
(Activity, Target, Error, Cause, Fix) and carry `ErrorId` values starting with `Vmm`.

## State

| State | Scope | Notes |
|---|---|---|
| `$script:VmmConfig` | module | Loaded from the local PSD1 (`$env:VMM_CONFIG`, `%APPDATA%`, `config\config.local.psd1`) |
| `$script:VmmCredentials` | module | Session-only PSCredentials, keyed Windows / Sql |
| `$script:VmmFlags` | module | Run flags from `vmm.ps1` (`--no-mouse`, `--no-color`, ...) |
| `fleet.vmm` | disk | JSON `{ Version, Updated, Hosts[], Overrides[] }`, encrypted |

Host record: `Name, AddedAt, Source, Platform, IPv4, Azure{SubscriptionId, ResourceGroup, VMName, PowerState},
Check{...}, Baseline{OS, Build, Sql}, Health, Steps{<Step>: {Status, At, Note, Snapshot}}, Blockers[], History[200], Hold`.

## Formats

| Format | Layout |
|---|---|
| Store file | `VMM1` \| IV(16) \| AES-256-CBC ciphertext \| HMAC-SHA256(32) over everything before it |
| Agent result | `VMM2\|` + base64( `VMM2` \| len(2, big endian) \| RSA-OAEP(64-byte key) \| IV(16) \| ciphertext \| HMAC(32) ) |
| Collector result | `VMM1\|` + base64(UTF-8 `key=value` lines), plain, from the paste-in collector or a generic agent |
| Agent plan | base64 `key=value` lines embedded at the `# VMM-CARD` marker of the agent |

## Flow of one step

1. `Invoke-VmmWorkflowStep` loads the store and the host record.
2. `Assert-VmmWindow` applies the time rule for the step class (ReadOnly, Staging, Change).
3. `Assert-VmmVpn` (network steps) stops early when the VPN is down.
4. Auto steps run; Guided steps require `-Confirmed` after the RDP guide or the host agent.
5. Access errors produce a blocker report (`New-VmmBlockerReport`) and the step becomes `Blocked`.
6. On success, an Azure checkpoint snapshot is taken per `Workflow.SnapshotAfter`.
7. `Set-VmmStepState` records status + history; `Save-VmmStore` writes atomically.

## Code flags

Comments mark code for reviewers: `[SEC]` = security-relevant decision, `TODO-FUTURE` = planned
extension point. Feature flags live in the config (`Features.*`), run flags on the command line.

## Extension points

- VPN providers: `Get-VmmVpnProvider` (add a branch + status/connect logic).
- AI providers: `Invoke-VmmAiChat` (OpenAI-compatible chat payload).
- Steps: `Get-VmmWorkflowDefinition` + a branch in `Invoke-VmmWorkflowStep` + agent `Get-Plan`.
- MCP (future): see [AI.md](AI.md).

_Last updated: 2026-11-14 03:34 UTC_
