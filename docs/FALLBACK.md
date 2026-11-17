<!-- SUMMARY: VmmFallback.ps1, the standalone last fallback on a host (no vmm, no laptop key, no network): files, how to run, steps with run/guidance-only/stage, rules, exit codes, result file, companion .psd1, tests. SECTIONS: Run it:17-38 | Steps:39-65 | Rules same as vmm:66-81 | Exit codes:82-99 | Result file:100-110 | Companion file:111-122 | Tests:123-130 -->
# Last fallback: VmmFallback.ps1 on a host

`VmmFallback.ps1` is the **last fallback**. Use it on a host when nothing else works: vmm cannot reach the host, and
there is no Extractor for it. It needs no vmm, no laptop key and no network. It reads everything useful about the
host and walks you through patching and upgrading Windows and SQL Server, one step at a time, with advice at each step.

Files, in `VmMaintenance\Resources\Fallback\`:

| File | What it is |
|---|---|
| `VmmFallback.ps1` | The script. Windows PowerShell 2.0 to 5.1 and PowerShell 7. |
| `VmmFallback.psd1` | The companion file: settings, OS upgrade path, SQL support matrix, steps, advice and manual instructions. Data only, nothing in it runs. |

Copy both files to the same folder on the host (for example `C:\Temp\VmmFallbackKit`, never inside the work folder).

## Run it

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VmmFallback.ps1
```

`Bypass` applies to this one process only. Right-click PowerShell > **Run as administrator** first: without it
some reads fail and every change is refused (exit 10).

| Command | What it does |
|---|---|
| *(no switch)* | Guide menu in a console; a snapshot when there is no console |
| `-Snapshot` | Read-only snapshot, one result file, exit |
| `-Check` | Only validate the companion file (0 valid, 2 invalid with the bad keys named) |
| `-Step <Id> -Action Guide` | One step, manual instructions only (nothing changes) |
| `-Step <Id> -Action Run` | One step, automated (console needed: you type YES) |
| `-Step <Id> -Action Stage` | Copy that step's media into the work folder (allowed in business hours) |
| `-Instance <name>` | SQL instance for SqlPatch / SqlUpgrade (`MSSQLSERVER` = default instance) |
| `-DataFile`, `-WorkDir`, `-MediaDir` | Companion file, work folder (must be under `C:\Temp`), media folder |
| `-Order "<reason>"` | Allows patching a client OS (Windows 10/11); at least 10 characters, logged. Never allows an OS upgrade of a client |
| `-NoColor`, `-Help` | Plain output; usage |

## Steps

The guide reads the host first, then lists the steps with a hint each (for example "NEEDED: 1 instance(s) not
supported on the target"). Every step shows its advice, then offers **R** run (automated), **G** guidance only
(the manual instructions from the companion file plus the exact commands for this host; nothing changes),
**T** stage media, **B** back.

| Step | Reads / does | Automated part (R) | Blocks it when |
|---|---|---|---|
| Snapshot | OS, build, edition, disks, pending reboot, patches, Windows Update, roles, DC, cluster, IIS, Exchange, SQL (64 and 32-bit, level, CU, HADR, backups), software, agents, legacy TLS, licence, .NET, event log errors | Read-only, any time | never |
| Precheck | Reboot pending, free space, Windows Update service, SQL backup age, warnings | Read-only | (reports exit 5 when something blocks changes) |
| WindowsPatch | `.msu` / `.cab` in `Media\Windows` in name order (`01-`, `02-`) | wusa / DISM, no reboot | hours, policy, admin, pending reboot, no media |
| SqlPatch | SP/CU `.exe` in `Media\Sql` that matches the instance's major version (newest wins) | `/quiet /Action=Patch /InstanceName=` | hours, policy, admin, cluster / Always On, a database without a fresh full backup, pending reboot, low space, already at that level |
| SqlUpgrade | `Media\SqlUpgrade\<any>\setup.exe` of an allowed target version | `/q /ACTION=Upgrade`; product key asked, used once, never stored or logged | as SqlPatch, plus: no in-place path, source below the minimum level |
| OsUpgrade | Next hop from `OsPath`, setup in `Media\Os` or a mounted ISO with the right build | Compatibility scan (C), then `/auto upgrade /imageindex <n> /noreboot`; image index picked by edition and Core/Desktop | hours, policy (client OS, target or newer, DC, cluster, Exchange), admin, pending reboot, low space, SQL not supported on the target, wrong media build, setup older than 2016 (no unattended switch: guidance only) |
| Disk | C: size and free space, next Azure tier | Extend C: into free space after it (Resize-Partition or diskpart) | hours, policy, admin, no free space after C:. The disk itself is grown in Azure (snapshot, deallocate, resize, start) |
| Postcheck | Second snapshot, changes since the first, automatic services not running | Read-only | (exit 9 when a reboot is still pending) |
| Finish | | Delete staged media (R) or the whole work folder (A) | the script is inside the work folder |

Before **every** change (WindowsPatch, SqlPatch, SqlUpgrade, OsUpgrade, Disk) the script asks for a rollback point:
type `SNAPSHOT TAKEN` on Azure (every disk, in the portal) or `BACKUP CONFIRMED` elsewhere; when management warnings
apply (Server 2008 non-R2, physical, DC, cluster, Exchange) also `MANAGEMENT INFORMED`. Then `YES`. After `YES` the
time window is read again: a prompt left open past 08:00 runs nothing (exit 3).

The script **never reboots** the host. Steps that need a reboot end with exit code 9 and tell you to reboot in the
maintenance window.

## Rules (same as vmm)

- Goal OS: Windows Server 2019. Already there: patch only. Newer (2022, 2025): never downgraded, patch only.
- Client OS (Windows 10/11): not touched without `-Order`. Even then: no OS upgrade.
- Warnings for Server 2008 (not R2), physical machines, domain controllers, clusters and Exchange.
- Mon-Fri 08:00-17:00 Lisbon (`Settings.TimeZoneId`, `BusinessDays`, `BusinessStart`, `BusinessEnd`, `Holidays`):
  reads, guidance and staging into `C:\Temp` only. An unknown time zone counts as business hours.
- Media come from a local folder only (`Settings.MediaDir`, or a mounted ISO). Nothing is downloaded (the
  Windows Update / WSUS option was removed in 2.17.1: it could also install SQL updates past the backup check).
- Client OS without `-Order`: staging (T) is refused too, because it copies files onto the machine.
- The work folder (`Settings.WorkDir`, default `C:\Temp\VmmFallback`) holds the result files, the log
  (`fallback_<date>.log`, sanitized), the lock and staged media. Only Administrators, SYSTEM and you can read it.
- No credentials are stored. The product key for a SQL upgrade is typed without echo, used once and dropped.
- Started by right-click > Run with PowerShell, the window waits for Enter when the exit code is not 0, so the
  last message stays readable.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | done |
| 1 | unexpected error, or a step failed (the message says where) |
| 2 | usage error, or the companion file is missing or invalid |
| 3 | blocked by the time window |
| 5 | refused by policy or a safety check |
| 6 | another copy is running on this host |
| 7 | snapshot saved, but some reads failed (`Problem=` lines) |
| 8 | cancelled (YES not typed) |
| 9 | done, a reboot is needed |
| 10 | needs administrator rights |

A guide session ends with 1 if any step failed, else 9 if a reboot is needed, else 7 if reads failed, else 0.
Ctrl+C is logged as `Interrupted`, and the lock is released.

## Result file

`VMMF_<HOST>_<kind>_<yyyyMMdd_HHmmss>.txt` in the work folder, `Key=Value` lines, first line `Format=VMMF1`.
The keys the Extractor also writes are the same (`Name`, `OS`, `Build`, `Platform`, `CTotalGB`, `CFreeGB`,
`PendingReboot`, `Sql`, `Inv.*`, `Problem`), so vmm can import it later (not built yet). Extra keys:
`SqlInstance`, `SqlStaleBackup` (`<instance>|db<n>|<age>`: database names stay on screen, out of the file), `Disk`,
`Patch`, `Feature`, `Software`, `Policy.*`.

The file is **not encrypted** (there is no laptop key on the host). Keep it on the host or carry it only to the
vmm laptop.

## Companion file

`VmmFallback.psd1` is read with `Import-LocalizedData` (restricted language: data only). Edit it freely, then
run `-Check`. Sections: `Settings`, `OsPath` (first match wins: keep R2 lines above plain ones), `SqlVersions`
(lowest level supported on the target OS), `SqlUpgrade` (in-place paths), `Agents` (service wildcards), `Steps`
(Id, Title, Advice, Manual). Advice and Manual lines can use `{WorkDir} {MediaDir} {TargetOs} {Os} {NextOs}
{Instance} {SqlMedia} {OsMedia} {MinFreeGB} {FreeGB}`. Every step must keep at least one Manual line, so
guidance only is always possible.

Sources for the shipped data (checked 2026-11-16): Microsoft Learn "Plan your Windows Server upgrade path" and
"SQL Server in Windows operating system". Check them again before a new hop.

## Tests

`tests\Fallback.Tests.ps1` (Pester 5): companion validation, the work-folder rule, the time window, the OS policy
matrix, the SQL rules, image index choice, native exit codes, the change gate (5, 3, 10), the result file keys,
sanitizing, PowerShell 2.0 syntax, a single `exit`, no reboot command, ASCII only, and process exit codes
(on Windows also a real read-only snapshot, guidance-only steps and the lock).

_Last updated: 2026-11-17 17:20 UTC_
