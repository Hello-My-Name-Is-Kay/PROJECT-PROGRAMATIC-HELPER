<!-- SUMMARY: VmMaintenance architecture: two programs, module layout, state, file formats, step flow, extension points. SECTIONS: Two programs:4-20 | Module layout:21-33 | State:34-50 | Formats:51-62 | Flow of one step:63-73 | Code flags:74-78 | Extension points:79-86 -->
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
| `workflows.vmm` | disk | JSON `{ Version, Updated, Default, Actions[], Workflows[], Kb[], LibraryImported }`, encrypted like the fleet store; built-in items come from `Get-VmmBuiltinWorkflow` and are never stored (2.19.0) |

Host record: `Name, AddedAt, Source, Platform, IPv4, Azure{SubscriptionId, ResourceGroup, VMName, PowerState},
Check{...}, Baseline{OS, Build, Sql}, Health, Steps{<Step>: {Status, At, Note, Snapshot}}, Blockers[], History[200], Hold,
Ticket{Workflow, Steps, Priority, Assignee, Notes, Created, Updated}` (Ticket from 2.19.0, added on first use by `Initialize-VmmTicket`).
Step keys: the ten maintenance step names, and `W:<action id>` for other workflow actions (`Get-VmmStepKey`).
Workflow resolution per host: `Resolve-VmmHostWorkflow` (ticket workflow or DEFAULT, steps changed on the ticket, state,
allowed now and why); ticket state: `Get-VmmTicketState`; counters: `Get-VmmTicket -Summary`.

## Formats

| Format | Layout |
|---|---|
| Store file | `VMM1` \| IV(16) \| AES-256-CBC ciphertext \| HMAC-SHA256(32) over everything before it |
| Agent result | `VMM2\|` + base64( `VMM2` \| len(2, big endian) \| RSA-OAEP(64-byte key) \| IV(16) \| ciphertext \| HMAC(32) ) |
| Collector result | `VMM1\|` + base64(UTF-8 `key=value` lines), plain, from the paste-in collector or a generic agent |
| Agent plan | base64 `key=value` lines embedded at the `# VMM-CARD` marker of the agent |
| Host runbook | `Resources\VmmRunbook.ps1` with the block between `# VMM-RUNBOOK-DATA-BEGIN/END` replaced (steps, known fixes, time rules) |
| Runbook result | `VMMW1\|<HOST>\|b64(workflow)\|built\|written`, then `S\|key\|status\|time\|b64(note)`, `G\|key\|b64(gate)`, `O\|key\|b64(reason)`, `K\|action\|b64(symptom)\|b64(cause)\|b64(fix lines)`, `H\|kb id\|1/0` |
| Shared library | JSON `{ Format = VMMLIB1, Exported, Actions[], Workflows[], Kb[] }`, plain, sanitized; ids `a-`, `wf-`, `kb-` + 10 hex |

## Flow of one step

1. `Invoke-VmmWorkflowStep` loads the store and the host record.
2. `Assert-VmmWindow` applies the time rule for the step class (ReadOnly, Staging, Change).
3. `Assert-VmmVpn` (network steps) stops early when the VPN is down.
4. Auto steps run; Guided steps require `-Confirmed` after the RDP guide or the host agent.
5. Access errors produce a blocker report (`New-VmmBlockerReport`) and the step becomes `Blocked`.
6. Snapshot steps (SnapStart, SnapPreSql, SnapPostSql, SnapFinal) call `New-VmmSnapshot` for every disk; SnapStart and
   SnapPreSql first ask `Get-VmmRecentSnapshotSet` whether every disk has one from the last hour. Other steps take none.
7. `Set-VmmStepState` records status + history; `Save-VmmStore` writes atomically.

## Code flags

Comments mark code for reviewers: `[SEC]` = security-relevant decision, `TODO-FUTURE` = planned
extension point. Feature flags live in the config (`Features.*`), run flags on the command line.

## Extension points

- VPN providers: `Get-VmmVpnProvider` (add a branch + status/connect logic).
- AI providers: `Invoke-VmmAiChat` (OpenAI-compatible chat payload).
- Steps: `Get-VmmWorkflowDefinition` + a branch in `Invoke-VmmWorkflowStep` + agent `Get-Plan`.
- MCP (future): see [AI.md](AI.md).

_Last updated: 2026-11-18 00:02 UTC_
