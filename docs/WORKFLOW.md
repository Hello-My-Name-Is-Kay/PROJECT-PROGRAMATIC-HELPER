<!-- SUMMARY: VmMaintenance workflow: steps, Lisbon time rules, checkpoint snapshots and prune, blockers, daily target, Extractor steps. SECTIONS: OS policy:7-13 | Steps:14-32 | Time rules EuropeLisbon:33-53 | Snapshot after every success:54-82 | Blockers:83-95 | Daily target:96-101 | Inside the host the Extracto:102-122 -->
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
| 2 | Stage | Staging | Auto | Copies from the media repository (`Staging.SourceShare`) to `C:\Temp` on the host (folder created if missing): the Windows Server image for `Staging.OsMediaVersion` in the host's install language, every file in `<share>\<HOST>\`, and any `Staging.Packages`; SHA256 verified when a hash is known. If the copy fails, vmm offers the hands-on copy over RDP / RDM / RDCMan (`vmm handoff`) and records Stage only when the files are verified on the host |
| 3 | PreSnapshot | Change | Hybrid | Azure: snapshot of all disks. Other platforms: you confirm a backup/snapshot was taken in their console |
| 4 | ExpandDisk | Change | Hybrid | Azure: grow OS disk to the next tier and extend C: when free space is under `Lansweeper.OkGB`. Otherwise guided. `NotNeeded` when space is fine |
| 5 | Upgrade | Change | Guided | You run setup in RDP/RDM with the checklist. `Upgrade.Mode = RunCommand` launches it remotely on Azure VMs |
| 6 | Verify | ReadOnly | Auto | Host back, OS caption matches `Upgrade.ExpectedOs`, SQL still answers |

- **Auto**: the tool does it.
- **Guided**: `vmm guide -HostName x -Step y` prints numbered steps; you do them in RDP/RDM,
  confirm each, then record the result with `-Confirmed` (keys `G` then `Y` in the console).
- **Hybrid**: Auto on Azure VMs, Guided elsewhere.

Each step records `Success`, `NotNeeded`, `Launched`, `Failed` or `Blocked`, a note, and any
snapshot names, in the encrypted fleet store (last 200 history entries per host).

## Time rules (Europe/Lisbon)

Time zone: `Schedule.TimeZoneId = 'GMT Standard Time'` (the Windows id for Lisbon, WET/WEST,
daylight saving handled by Windows).

| When | ReadOnly | Staging | Change |
|---|---|---|---|
| Mon-Fri 08:00-16:59 | Yes | Yes, into `C:\Temp` only | Override only |
| Mon-Fri before 08:00 / from 17:00 | Yes | Yes | Yes (`Schedule.AllowChangesOffHoursWeekdays`, default on) |
| Saturday, Sunday, `Schedule.Holidays` | Yes | Yes | Yes |

**Disk expansion** is never overridable in business hours (`Policy.ExpandDiskOverride = $false`): the
Azure VM is shut down (deallocated), the OS disk resized and the VM started again.

**Override**: `-Override -OverrideReason "<who approved, why>"` on the CLI, or type `OVERRIDE`
and a reason in the console. The reason must be 10+ characters. Every override is written to
the fleet store and listed in the daily report, so your manager sees it.

Functions that enforce the rule: `Invoke-VmmWorkflowStep`, `Expand-VmmOsDisk -Apply`,
`Mount-VmmUpgradeMedia`, `Dismount-VmmUpgradeMedia`, `Invoke-VmmPrune -Apply`.

## Snapshot after every successful step, prune at the end

Question asked: "Do we have a snapshot after every successful step, and prune after we are done?"

**Before v2: no.** Snapshots were taken only before a disk resize (inside `Expand-AzOsDisk`) and
by running `CreateSnapshots.ps1` by hand. Pruning was a separate manual script.

**Now: yes, with one deliberate default.**

| Setting `Workflow.SnapshotAfter` | Checkpoint after |
|---|---|
| `ChangingSteps` (default) | ExpandDisk and Upgrade succeed (PreSnapshot is itself the snapshot) |
| `EveryStep` | every successful step, including Precheck, Stage and Verify |
| `Off` | never (PreSnapshot still runs) |

- Checkpoints are named `<VM>_cp-<Step>_OsDisk_snap` (and per data disk), tagged
  `Checkpoint=<Step>`, `RetentionDays=<Workflow.CheckpointRetentionDays>` plus your `Snapshots.Tags`.
- **Azure VMs only.** On VMware, Hyper-V or physical hosts the tool cannot snapshot; the step note
  says "no automatic checkpoint" and PreSnapshot asks you to confirm a backup instead.
- A failed checkpoint does not undo the step. The note says `CHECKPOINT FAILED` and the daily
  report shows it.
- Why `ChangingSteps` is the default: a snapshot after a read-only step (Precheck, Verify) or after
  copying files to `C:\Temp` costs storage and adds no rollback point the previous snapshot does not
  already give. Switch to `EveryStep` in Settings if you want it anyway.

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

## Daily target

`Target.MachinesPerDay` (default 10) in `Target.WorkdayHours` (default 9). A host counts once per
day when one of `Target.CountedSteps` (default Stage, Verify) succeeded that day. Status:
`TargetMet`, `OnTrack` (at or above the expected count for the time of day) or `AtRisk`.

## Inside the host: the Extractor

Off by default: the Extractor is snapshot-only unless `Extractor.AllowSteps` is true, and then only the per-host
Extractor (`X`) carries steps. With steps on, it first saves `VMM_<HOST>_<time>.vmm` on the desktop, then shows the same six steps for its host with: status (from the laptop at export time, then
from its own log), whether the step is available **now**, and **why**. It evaluates locally: Lisbon
time rule, admin rights, rollback snapshot done, staged files present and hash-verified, C: free space
against `Lansweeper.OkGB` / `CriticalGB`, pending reboot, and whether the plan is for this host.

| Step | In the agent |
|---|---|
| Precheck / Verify | Collects facts; Verify compares the OS with `Upgrade.ExpectedOs` |
| Stage | Checks `C:\Temp`; copies from the share if the host can reach it, else tells you what to paste |
| PreSnapshot | Azure: done from the laptop. Other platforms: confirm (`DONE`) after the console snapshot |
| ExpandDisk | Extends C: into unallocated space (diskpart); grow the virtual disk first |
| Upgrade | Starts `Upgrade.CommandLine` after you type the host name; logs `Launched` |

Change steps need the window or an override (typed `OVERRIDE` + reason), and the host name typed as
confirmation. The export carries every logged event; the laptop adds them to the host history and
records host-side overrides in the daily report.

_Last updated: 2026-11-15 22:00 UTC_
