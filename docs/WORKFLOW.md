<!-- SUMMARY: VmMaintenance workflow: steps, Lisbon time rules, the four snapshot points and prune, blockers, daily target, Extractor steps. SECTIONS: OS policy:7-13 | Steps:14-42 | Time rules EuropeLisbon:43-63 | The four snapshot points pru:64-101 | Blockers:102-121 | Other workflows 2.19.0:122-128 | Daily target:129-134 | Inside the host the Extracto:135-155 -->
# Workflow

How one host moves from "imported" to "done", what the time rules allow, where snapshots
are taken and when they are pruned.

## OS policy

Goal: Windows Server 2019 on every machine. Client OS (Windows 10/11...) is skipped unless an order
is recorded (`vmm order`). Hosts already on 2019 or newer are left out. Management is warned about
Windows Server 2008 (not R2) and physical machines (`vmm policy -Notice`). Read-only steps run on every
host; Stage and change steps only on hosts in scope.

## Steps

| # | Step | Class | Mode | What happens |
|---|---|---|---|---|
| 1 | Precheck | ReadOnly | Auto | Ping, ports, CIM: OS/SP, SQL version, C: free, pending reboot, watched software. Baseline saved on first success |
| 2 | SnapStart | Staging* | Auto | **Snapshot point 1.** Azure: snapshot of every disk, unless every disk already has a snapshot from the last `Workflow.StartSnapshotMaxAgeMinutes` (60). You may decline it (`-Decline`, or `n` in the console): recorded as Skipped. Other platforms: reminder only |
| 3 | Stage | Staging | Auto | Copies from the media repository (`Staging.SourceShare`) to `C:\Temp` on the host (folder created if missing): the Windows Server image for `Staging.OsMediaVersion` in the host's install language, every file in `<share>\<HOST>\`, and any `Staging.Packages`; SHA256 verified when a hash is known. If the copy fails, vmm offers the hands-on copy over RDP / RDM / RDCMan (`vmm handoff`) and records Stage only when the files are verified on the host |
| 4 | SnapPreSql | Change | Hybrid | **Snapshot point 2**, before the first SQL-invasive step. Azure: every disk; NotNeeded when a full set from the last 60 min exists (SnapStart or the portal; only Stage ran since). Other platforms: you confirm a backup/snapshot taken in their console |
| 5 | ExpandDisk | Change | Hybrid | SQL-invasive (the VM is deallocated, SQL stops). Azure: grow OS disk to the next tier and extend C: when free space is under `Lansweeper.OkGB`. Otherwise guided. `NotNeeded` when space is fine |
| 6 | Upgrade | Change | Guided | SQL-invasive: OS in-place upgrade or SQL SP/CU. You run setup in RDP/RDM with the checklist. `Upgrade.Mode = RunCommand` launches it remotely on Azure VMs (`Launched`); confirm it with `-Confirmed` once it has finished |
| 7 | SnapPostSql | Change | Auto | **Snapshot point 3**, after the last SQL-invasive step. Azure: every disk, always taken. Other platforms: reminder only |
| 8 | Verify | ReadOnly | Auto | Host back, OS caption matches `Upgrade.ExpectedOs`, SQL still answers |
| 9 | ManualCheck | ReadOnly | Guided | Your own check of the host and its applications. `-Confirmed` (console `Y`) records it; `-Bypass -BypassReason '...'` (console `BYPASS`, 10+ characters) records it as Skipped with the reason |
| 10 | SnapFinal | Change | Auto | **Snapshot point 4**, always the last step, after ManualCheck. Azure: every disk, always taken. Other platforms: reminder only |

\* SnapStart is `Change` when `Policy.SnapStartInBusinessHours = $false`.

- **Auto**: the tool does it.
- **Guided**: `vmm guide -HostName x -Step y` prints numbered steps; you do them in RDP/RDM,
  confirm each, then record the result with `-Confirmed` (keys `G` then `Y` in the console).
- **Hybrid**: Auto on Azure VMs, Guided elsewhere.

Each step records `Success`, `NotNeeded`, `Launched`, `Failed` or `Blocked`, a note, and any
snapshot names, in the encrypted fleet store (last 200 history entries per host).
A failed or blocked step is recorded first, then the command ends with an error (`VmmStepFailed` /
`VmmStepBlocked`, exit code 1; VPN down keeps exit code 4). `vmm next` runs every queued host, then fails naming
the ones that did not succeed. A change step stopped with Ctrl+C is recorded as `Failed` (INTERRUPTED): check the
host before running it again. Every result is logged with its duration.

## Time rules (Europe/Lisbon)

Time zone: `Schedule.TimeZoneId = 'GMT Standard Time'` (the Windows id for Lisbon, WET/WEST,
daylight saving handled by Windows).

| When | ReadOnly | Staging | Change |
|---|---|---|---|
| Mon-Fri 08:00-16:59 | Yes | Yes, into `C:\Temp` only, and the Azure start snapshot (SnapStart) | Override only |
| Mon-Fri before 08:00 / from 17:00 | Yes | Yes | Yes (`Schedule.AllowChangesOffHoursWeekdays`, default on) |
| Saturday, Sunday, `Schedule.Holidays` | Yes | Yes | Yes |

**Disk expansion** is never overridable in business hours (`Policy.ExpandDiskOverride = $false`): the
Azure VM is shut down (deallocated), the OS disk resized and the VM started again.

**Override**: `-Override -OverrideReason "<who approved, why>"` on the CLI, or type `OVERRIDE`
and a reason in the console. The reason must be 10+ characters. Every override is written to
the fleet store and listed in the daily report, so your manager sees it.

Functions that enforce the rule: `Invoke-VmmWorkflowStep`, `Expand-VmmOsDisk -Apply`,
`Mount-VmmUpgradeMedia`, `Dismount-VmmUpgradeMedia`, `Invoke-VmmPrune -Apply`.

## The four snapshot points, prune at the end

Kay's rule (2026-11-16): exactly four Azure snapshot points per host, each a snapshot of **every disk** of the
VM (OS and data disks). They replace the per-step checkpoints of 2.4.0-2.15.x (`Workflow.SnapshotAfter` and
`cp-<Step>` snapshots are gone).

| Point | Step | When | Skipped when |
|---|---|---|---|
| 1 | SnapStart | At the start of the work, after Precheck and before Stage writes to `C:\Temp` | Every disk has a snapshot from the last `Workflow.StartSnapshotMaxAgeMinutes` (60), or you decline it |
| 2 | SnapPreSql | Before the first SQL-invasive step (ExpandDisk, or Upgrade when ExpandDisk is NotNeeded) | Every disk has a snapshot from the last 60 min (in practice: SnapStart was taken less than an hour ago) |
| 3 | SnapPostSql | After the last SQL-invasive step (Upgrade done or confirmed) | Never |
| 4 | SnapFinal | The true last step, after your manual check or its bypass | Never |

- **SQL-invasive** = ExpandDisk (the VM is deallocated, so SQL stops, and C: changes) and Upgrade (the OS
  in-place upgrade and SQL SP/CU). There are no separate OS points.
- **"From the last hour"** counts every snapshot whose source is one of the VM's disks, whoever made it: vmm,
  `CreateSnapshots.ps1`, or by hand in the Azure portal. It only counts when **every** managed disk has one;
  otherwise a full new set is taken. The note names the snapshots it relied on.
- **Names and tags**: `<VM>_snap-Start_OsDisk_snap`, `<VM>_snap-PreSql_DataDisk_0_snap`, ... (an existing name
  gets the run stamp appended), tagged `SnapPoint=<step>`, `RetentionDays=<Workflow.SnapshotRetentionDays>`
  (default 7) plus your `Snapshots.Tags`, so prune finds them.
- **Time rules**: SnapStart may run in business hours while `Policy.SnapStartInBusinessHours` is on (default):
  it does not touch the guest and causes no downtime. The other three are Change steps: after hours, or an
  override with a reason.
- **Other platforms** (VMware, Hyper-V, physical): vmm cannot snapshot them. SnapPreSql asks you to confirm a
  backup/snapshot taken in the platform console; the other three record NotNeeded with a reminder.
- **Disk expansion** still takes its own OS-disk copy while the VM is deallocated (inside `Expand-VmmOsDisk`);
  that is part of the resize safety net, not a workflow point.
- A snapshot point that fails is recorded as **Failed** and the host stops there: run it again (existing
  snapshots are never overwritten).
- Hosts recorded before 2.17.0: `PreSnapshot` is read as SnapPreSql, and a SnapStart or SnapPostSql that the host
  already passed is marked Skipped ("not in the workflow when this host passed this point"). ManualCheck and
  SnapFinal are still to do.

**Prune**: `vmm prune` (console key `8`) previews every snapshot past its `RetentionDays` in all
subscriptions the fleet uses, filtered by `Snapshots.CleanupTagName/Value`. Deleting needs
`-Apply` (console: type `DELETE`) and respects the time rules. Nothing is deleted without the preview.

## Blockers

When a step fails with an access problem (access denied, logon failure, RPC unavailable, Azure
authorization):

1. The step is marked `Blocked`.
2. A manager report is written to `Reports\Blockers\` and copied to the clipboard: host, step,
   exact error, what access is needed and from whom.
3. You must answer "Have you contacted your manager?" - **Sent**, **Later** or **Bypass** (with
   reason). The answer is recorded. The tool never sends email.
4. The queue moves on to the next host ("report and move on").
5. When access is granted: `vmm resolve -HostName x`.

### Known fixes and tickets for IT (2.19.0)

From the ticket view, a failed step opens the failure dialogue: you paste what happened, vmm shows the known fixes
other technicians recorded for that step, and when none helps you record your own fix, write a ticket for the IT
person who can fix it (`Reports\Tickets`, clipboard; you send it), or mark the step Blocked and move on.
See [TICKETS.md](TICKETS.md).

## Other workflows (2.19.0)

The ten steps above are the built-in **Full maintenance** workflow, the DEFAULT for every ticket. The workflow
manager (`K`) adds **Read-only snapshot** (non-invasive checks) and your own workflows built from actions
(ReadOnly / Staging / Change). The same rules apply: Change only after every earlier step and outside business
hours (or OVERRIDE), a rollback point (`SNAPSHOT TAKEN` / `BACKUP CONFIRMED`) and `YES` before a guided Change step.

## Daily target

`Target.MachinesPerDay` (default 10) in `Target.WorkdayHours` (default 9). A host counts once per
day when one of `Target.CountedSteps` (default Stage, Verify) succeeded that day. Status:
`TargetMet`, `OnTrack` (at or above the expected count for the time of day) or `AtRisk`.

## Inside the host: the Extractor

Off by default: the Extractor is snapshot-only unless `Extractor.AllowSteps` is true, and then only the per-host
Extractor (`X`) carries steps. With steps on, it first saves `VMM_<HOST>_<time>.vmm` on the desktop, then shows the host-side steps (Precheck, Stage, SnapPreSql, ExpandDisk, Upgrade, Verify; the other snapshot points and ManualCheck are done from the laptop) with: status (from the laptop at export time, then
from its own log), whether the step is available **now**, and **why**. It evaluates locally: Lisbon
time rule, admin rights, rollback snapshot done, staged files present and hash-verified, C: free space
against `Lansweeper.OkGB` / `CriticalGB`, pending reboot, and whether the plan is for this host.

| Step | In the agent |
|---|---|
| Precheck / Verify | Collects facts; Verify compares the OS with `Upgrade.ExpectedOs` |
| Stage | Checks `C:\Temp`; copies from the share if the host can reach it, else tells you what to paste |
| SnapPreSql | Azure: done from the laptop. Other platforms: confirm (`DONE`) after the console snapshot |
| ExpandDisk | Extends C: into unallocated space (diskpart); grow the virtual disk first |
| Upgrade | Starts `Upgrade.CommandLine` after you type the host name; logs `Launched` |

Change steps need the window or an override (typed `OVERRIDE` + reason), and the host name typed as
confirmation. The export carries every logged event; the laptop adds them to the host history and
records host-side overrides in the daily report.

_Last updated: 2026-11-18 00:02 UTC_
