<!-- SUMMARY: VmMaintenance 2.19.0: hosts as tickets (board, counters, create/edit/delete), workflow manager (DEFAULT workflow, read-only workflow, actions, steps), guided RDP step dialogue with gates, known fixes when a step fails, tickets for IT, host runbook (.ps1/.cmd), shared library, design choices. SECTIONS: The ticket board:11-55 | Counters overview:56-92 | Working on a ticket:93-133 | The step dialogue:134-167 | When a step fails:168-199 | Tickets for IT:200-237 | Host runbook RDP only:238-258 | Workflow manager:259-360 | Design choices 2.19.0:361-374 | Limits alpha:375-384 -->
# Tickets, workflows and known fixes

Since 2.19.0 every host in the fleet is a **ticket**: it has a state, a workflow, a priority, an assignee and notes,
and vmm guides you through its workflow one step at a time. It is built for hosts you can only reach with **RDP**
(copy and paste of text and files, nothing else): every step tells you what to do, gives you the command to paste,
and when a step fails it shows what other technicians did when they saw the same error.

All screens below are text captures of the real screens with made-up host names (colours removed).

## The ticket board

Main menu `T`. Tickets are grouped by state, the ones that need help first. The title row counts them, plus done
today and the daily target. `*` after the workflow = it follows the DEFAULT workflow, `+` = steps changed on this ticket.

```
 Tickets 7 | new 1 | in progress 2 | failed 1 | blocked 0 | hold 1 | done 1 (today 1) | target 1/10 AtRisk
   Prio   Host               Workflow (*default)     Steps Next step                    Assignee       Notes
 FAILED - needs a fix (known fixes on Enter) (1)
  Normal SQL-SRV-02         Full maintenance*        2/10 Stage
 IN PROGRESS (2)
  High   APP-SRV-01         Full maintenance*        3/10 SnapPreSql                   Kay
  Normal FILE-SRV-03        Read-only snapshot        3/9 Server roles
 NEW (1)
  Normal WEB-SRV-04         Full maintenance*        0/10 Precheck
 ON HOLD (H) (1)
  Normal DB-SRV-07          Full maintenance*        0/10 Precheck
 EXCLUDED - client OS, no orders (1)
  Normal PC-REC-05          Full maintenance*        0/10 Precheck (later)
 DONE (1)
  Normal OLD-SRV-06         Read-only snapshot        9/9 -
 Enter work on it | N new | E edit | W workflow | D delete | H hold | F filter | O overview | K workflow manager | Esc | F2 show log | F3 ~

```

| Key | Does |
|---|---|
| Enter | Work on the ticket (its workflow, step by step) |
| N | New ticket: adds the host to the fleet, then the edit dialogue |
| E | Edit: priority (High / Normal / Low), assignee, notes, workflow |
| W | Choose the workflow: DEFAULT (follows whatever is the default) or any workflow |
| D | Delete: removes the host from the fleet with its history; you type the host name to confirm |
| H | Hold / unhold (left out of the queue) |
| F | Filter host names (wildcards) |
| O | Overview: every counter |
| K | Workflow manager |

States: **New** (nothing recorded), **InProgress**, **Failed** (a step failed), **Blocked** (open blocker or a step
blocked, e.g. waiting for IT), **OnHold**, **Excluded** (client OS without orders: nothing is done), **NotNeeded**
(already on or above the target OS and the workflow changes things), **Done** (every step finished: Success,
NotNeeded or Skipped with a reason).

The same actions exist on the fleet screen (`2`): `N` new, `E` edit, `W` ticket view, `D` delete (now asks for the
host name). On a host screen `W` opens its ticket.

## Counters (overview)

`O` on the board, or `vmm tickets -Summary`.

```
 Ticket overview
 TODAY (Tue 2026-11-17 23:54 Lisbon, changes ALLOWED)
  Daily target           1/10 machines, 10 expected by now: AtRisk
  Tickets done today     1
  Steps done today       17
  Failures today         1
  Pending (new + open)   3     need help (failed + blocked) 1
 BY STATE (7 tickets)
  New             1  ####
  InProgress      2  #########
  Blocked         0
  Failed          1  ####
  OnHold          1  ####
  Excluded        1  ####
  NotNeeded       0
  Done            1  ####
 BY WORKFLOW (done / open / total)
  Full maintenance                  0 /    3 /    5
  Read-only snapshot                1 /    1 /    2  ###############
 BY NEXT STEP (where the tickets wait)
  (finished)                        1
  Precheck                          3
  Server roles                      1
  SnapPreSql                        1
  Stage                             1
 BY PRIORITY
  High                              1
   [2/27]
 Esc back | F2 show log | F3 full log

```

## Working on a ticket

Enter on a ticket. Each line is one step of the ticket's workflow: category, status, whether it is allowed now
(and why not), how many known fixes exist (`k1`), and the last note.

```
 SQL-SRV-02 | Failed | Full maintenance (default) | 2/10 | VMware | prio Normal
     Step                       Category  Status     When   Fix Note
   1. Precheck                   ReadOnly  Success    now        Pre-check: reachability, OS/SP, SQL, C: space, pending reboot
   2. SnapStart                  Staging   NotNeeded  now        Snapshot point 1: all disks, unless every disk has a snapshot from the la~
   3. Stage                      Staging   Failed     now    k1  There is not enough space on the disk
   4. SnapPreSql                 Change    todo       later      Finish the earlier steps first (a change step runs in order).
   5. ExpandDisk                 Change    todo       later      Finish the earlier steps first (a change step runs in order).
   6. Upgrade                    Change    todo       later      Finish the earlier steps first (a change step runs in order).
   7. SnapPostSql                Change    todo       later      Finish the earlier steps first (a change step runs in order).
   8. Verify                     ReadOnly  todo       now        Post-check: host back, OS/SQL as expected, services up
   9. ManualCheck                ReadOnly  todo       now        Your own check of the host and its applications (confirm, or bypass with ~
  10. SnapFinal                  Change    todo       later      Finish the earlier steps first (a change step runs in order).
 Next: Stage - Enter opens it
 Enter open step | W workflow | A add step | X remove | U/J move | R reset steps | B runbook | I import | L RDP | K fixes | E edit | V hos~

```

| Key | Does |
|---|---|
| Enter | Open the step dialogue |
| W | Choose the workflow |
| A / X | Add an action after the selected step / remove the selected step - **for this ticket only** (the workflow is not changed). A change step that already ran cannot be removed |
| U / J | Move the selected step up / down (this ticket only) |
| R | Reset the steps to the workflow's list |
| B | Build the host runbook (see below) |
| I | Import what the host runbook wrote (clipboard, or the file) |
| L | Remote desktop (RDP / RDM / RDCMan) |
| K | Known fixes of the selected step |
| E | Edit the ticket |
| V | The host's maintenance screen (facts, snapshot, extractor, inventory...) |

Rules on this screen (same as the rest of vmm): a client OS without orders gets nothing; a host already on or over
the target OS gets no change step; a **Change** step only when every earlier step is finished, and outside business
hours (Mon-Fri 08:00-17:00 Lisbon) unless you type `OVERRIDE` with a reason (recorded, in the daily report).

## The step dialogue

Enter on a step. This is the "manual guidance": numbered lines to tick, the command to copy into the RDP session,
what success looks like, and the known fixes.

```
 FILE-SRV-03 / step 2: Disk space - Size and free space of every fixed drive
 ReadOnly | Guided | status: Success
 DO THIS (Enter ticks a line)
  [ ] 1. Paste the command in PowerShell on the host.
  [ ] 2. C: needs the free space your Lansweeper.OkGB setting asks for (ExpandDisk otherwise).
  [ ] 3. Paste on the host (PowerShell):   >> Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" | Select-Object DeviceID, @{n='SizeGB'~
 SUCCESS LOOKS LIKE
  One line per drive with SizeGB and FreeGB.
 KNOWN FIXES: 2 (K) - F shows the ones that match your error
 Enter tick | C copy | D done | F failed | S skip | K fixes | L RDP | T IT ticket | Esc | F2 show log | F3 full log

```

| Key | Does |
|---|---|
| Enter | Tick / untick the selected line |
| C | Copy the selected command (or all commands) to the clipboard: paste it in the RDP session |
| G | Gate, for a step that is not read-only: Staging = reminder that only `C:\Temp` may be written in business hours + y/N; Change = time window (or `OVERRIDE` + reason), `MANAGEMENT INFORMED` when warnings apply (Server 2008 non-R2, physical), the rollback point (`SNAPSHOT TAKEN` on Azure, `BACKUP CONFIRMED` elsewhere), then `YES`. Commands of such a step are copied only after the gate |
| D | Done: asks what you saw (Enter = as expected); recorded with the gate answers |
| F | Failed: the failure dialogue (next section) |
| S | Skip, with a reason of 10+ characters (recorded) |
| K | Known fixes for this step |
| L | Remote desktop |
| T | Ticket for the IT person who can fix the failure |

The ten maintenance steps (Precheck ... SnapFinal) keep their own logic: `R` runs the step through vmm (its own
time rules, snapshot points and gates), `D` confirms a guided one, `G` opens its RDP guide. vmm records their results.

## When a step fails

1. `F`, then paste the exact error (or describe what you saw). The step is recorded as **Failed** with that text.
2. vmm lists the **known fixes** for this step that share words with your error, best first (this step's own fixes
   first, then fixes for any step; more "it helped" votes rank higher). Each opens as a dialogue:

```
 Suggested resolution (known fix)
 WHAT HAPPENED
  not enough space on the disk while staging to C:\Temp
 WHY
  C: is too full for the installation files.
 FIX (Enter ticks a step)
  [ ] 1. Check the free space (Disk space action).
  [ ] 2. Remove old files from C:\Temp that are not part of this staging.
  [ ] 3. If still short: the ExpandDisk step grows C: after hours (Azure), or ask the platform owner for more space.
 COMMANDS (C copies)
  >> Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'" | Select-Object @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,1)}}
 Helped 0 time(s), did not help 0 time(s)
 Enter tick | C copy | Y it fixed it | N did not help | Esc back | F2 show log | F3 full log

```

   `Y` = it fixed it (the step goes back to **Pending**: do it again, then `D`), `N` = it did not help (the next one).
3. Nothing helped: vmm prints the likely cause and fix from the error text, says when it is an access problem you
   cannot fix yourself, and offers:
   - `R` you fixed it: record **what happened, why, and the fix steps** for the next technician (host names, FQDNs,
     IPs, ids and secrets are replaced with `<HOST>`, `<IP>`, `<ID>`, `***` automatically);
   - `T` a **ticket for the IT person** who can fix it (below); the step stays Failed;
   - `B` blocked: that ticket, and the step marked **Blocked**, so you move on to the next host;
   - Enter: leave it Failed.

## Tickets for IT

When a call fails for a reason you cannot fix (Azure permission, VPN, RDP, share access, SQL login, firewall),
vmm writes a ready-to-send ticket text addressed to the person who can fix it. After **any** failed action in the
console the pause line offers `T`; also `T` in the step dialogue, the failure dialogue, and `vmm ticket-it`.

- Saved under `%LOCALAPPDATA%\VmMaintenance\Reports\Tickets\<time>_<kind>.txt` and copied to the clipboard.
  **You** paste it into the ticket system or an e-mail; vmm never sends anything.
- Sections: Subject (`[High|Normal|Low] <kind> needed - <what>`), Summary, What was attempted (step, target, time),
  Exact error (and error id), Likely cause, **Requested action** (for Azure: the role and its scope, e.g. Virtual
  Machine Contributor + Disk Snapshot Contributor on the VM's resource group), Impact, Urgency (High when it blocks
  a change step or Azure / VPN / sign-in for everything; the next change window is named), Already tried (matching
  known fixes), Environment (vmm and PowerShell version, a reference id).
- Sanitized by default: `<HOST>` marks where the host or resource group goes; you fill it in when you send it.
  `-IncludeTarget` writes the real names instead (the file then stays on your laptop, like blocker reports).
- What to do now is printed above it: the fix hint, matching known fixes, and "mark Blocked and move on".

Example (`vmm ticket-it -Message '<AuthorizationFailed ...>' -HostName x -Step SnapStart`):

```
Subject: [High] Azure role needed - Snapshot point 1: all disks, unless every disk has a snapshot from the last hour

Summary
  Access is needed: Azure RBAC on the VM's resource group: Virtual Machine Contributor (start/stop/run command) and Disk Snapshot Contributor (snapshots).
What was attempted
  Snapshot point 1 ... (maintenance workflow step 'SnapStart') on <HOST> (name given when the ticket is sent)
Exact error
  AuthorizationFailed: The client does not have authorization to perform action 'Microsoft.Compute/snapshots/write' over scope '/subscriptions/<ID>/...'
Likely cause
  Your account lacks the Azure role needed for this action on this scope.
Requested action
  Azure RBAC on the VM's resource group: ... Scope: the resource group that holds the VM (name given when the ticket is sent).
Impact
  Maintenance of <HOST> ... cannot continue at step 'SnapStart'. The upgrade programme to *Server 2019* is delayed for this machine.
Urgency
  High - it blocks maintenance planned for the next change window (...).
```

## Host runbook (RDP only)

`B` on a ticket (or `vmm runbook -HostName x`) writes `VmmRunbook_<HOST>_<time>.ps1` and a `.cmd` launcher into the
outbox and puts both on the clipboard as files. Paste them on the RDP desktop and double-click the `.cmd` (it runs
the `.ps1` once with `-ExecutionPolicy Bypass`; nothing is changed on the host's policy).

- Windows PowerShell 2.0 or later (Server 2008 R2 onwards); refuses to run on another computer unless you type
  the host name; refuses a client OS without orders.
- Shows each step, its instructions and commands. Read-only actions marked "may run on the host" run their
  commands when you type `R`; nothing else runs by itself.
- A step that is not read-only shows its commands only after the gate: the host's own clock converted to the
  business-hours zone (or `OVERRIDE` + reason), `MANAGEMENT INFORMED` when warnings apply, `SNAPSHOT TAKEN` /
  `BACKUP CONFIRMED`, `YES`.
- On a failure it shows the known fixes for that step, asks whether one helped, and lets you write the fix.
- It writes **one** file, `VMMW_<HOST>_<time>.txt` on the desktop, and copies it to the clipboard. Back on the
  laptop: `I` on the ticket (reads the clipboard, or the file you drag in) or `vmm runbook-import`.
- Import rules: only steps of the ticket's current workflow; the ten maintenance steps are never set from a host
  file (they go to the history as a note: vmm records those itself); a Change step reported done without its gate
  line becomes **Pending** (confirm it with `D`); overrides go to the daily report; new known fixes are made
  shareable and added to your library.

## Workflow manager

Main menu `K`.

```
 Workflow manager
 WORKFLOWS (Enter = steps, N new, C copy, E rename, D delete, S make default)
  Full maintenance               10 steps  changes hosts           5 host(s)  DEFAULT, built-in
  Read-only snapshot              9 steps  read-only               2 host(s)  built-in
 LIBRARY
  Action library      19 action(s): 12 read-only, 2 staging, 5 change
  Known fixes         3 entr(ies) - what failed and how it was fixed, shown when a step fails
  Shared library      X export / I import: path asked (set Workflow.LibraryPath)
 Enter open | N new | C copy | E rename | D delete | S default | A actions | K known fixes | X export | I import | Esc | F2 show log | F3 ~

```

- **Full maintenance** (built-in, 10 steps) is the **DEFAULT**: every ticket without its own choice follows it.
  `S` makes another workflow the default.
- **Read-only snapshot** (built-in, 9 steps) groups the non-invasive checks: OS and uptime, disk space, pending
  reboot, server roles (domain controller, cluster), SQL instances, stopped automatic services, recent errors, last
  updates, the `C:\Temp` staging folder. Every command is PowerShell 2.0 and only reads.
- `N` new, `C` copy (built-ins are read-only: copy them to change them), `E` rename, `D` delete (type `DELETE`;
  tickets on it go back to the DEFAULT, their results stay).
- Enter on a workflow edits its steps:

```
 Workflow: Read-only snapshot - Non-invasive checks only. Every step can be pasted or run on the host over RDP (host runbook).
     Action                     Category  Mode    Group        What it does
   1. OS and uptime              ReadOnly  guided  OS           Windows version, build, service pack, last boot
   2. Disk space                 ReadOnly  guided  Disk         Size and free space of every fixed drive
   3. Pending reboot             ReadOnly  guided  OS           Is a reboot pending (servicing, Windows Update, file renames)?
   4. Server roles               ReadOnly  guided  OS           Domain controller? Cluster? (management must be warned)
   5. SQL Server instances       ReadOnly  guided  SQL          SQL Server instances and their services
   6. Stopped automatic services ReadOnly  guided  Services     Automatic services that are not running
   7. Recent errors              ReadOnly  guided  Events       System and Application errors in the last 24 hours
   8. Last updates               ReadOnly  guided  Updates      The ten most recent installed updates
   9. Staging folder             ReadOnly  guided  Staging      What is already in C:\Temp (staged files)
 Built-in workflow: read-only. C in the workflow manager makes an editable copy.
 Enter open action | A add from library | N new action | X remove step | U up | J down | K known fixes | Esc | F2 show log | F3 full log

```

  `A` adds an action from the library after the selected step, `N` creates a new action and adds it, `X` removes a
  step (the action stays in the library), `U` / `J` move it, Enter opens the action, `K` its known fixes.

### Actions

`A` in the manager: the action library, grouped by category.

```
 Action library: 19 action(s)
   Action                     Group        Mode    Kind  Used  Fixes    What it does
 READONLY - reads only, any time
  Disk space                 Disk         guided  b-in  wf:1  fixes:0  Size and free space of every fixed drive
  Recent errors              Events       guided  b-in  wf:1  fixes:0  System and Application errors in the last 24 hours
  ManualCheck                Maintenance  guided  b-in  wf:1  fixes:0  Your own check of the host and its applications (confirm, or bypass~
  Precheck                   Maintenance  auto    b-in  wf:1  fixes:0  Pre-check: reachability, OS/SP, SQL, C: space, pending reboot
  Verify                     Maintenance  auto    b-in  wf:1  fixes:0  Post-check: host back, OS/SQL as expected, services up
  OS and uptime              OS           guided  b-in  wf:1  fixes:0  Windows version, build, service pack, last boot
  Pending reboot             OS           guided  b-in  wf:1  fixes:0  Is a reboot pending (servicing, Windows Update, file renames)?
  Server roles               OS           guided  b-in  wf:1  fixes:0  Domain controller? Cluster? (management must be warned)
  Stopped automatic services Services     guided  b-in  wf:1  fixes:0  Automatic services that are not running
  SQL Server instances       SQL          guided  b-in  wf:1  fixes:0  SQL Server instances and their services
  Staging folder             Staging      guided  b-in  wf:1  fixes:0  What is already in C:\Temp (staged files)
  Last updates               Updates      guided  b-in  wf:1  fixes:0  The ten most recent installed updates
 STAGING - writes into C:\Temp only, allowed in business hours
  SnapStart                  Maintenance  auto    b-in  wf:1  fixes:0  Snapshot point 1: all disks, unless every disk has a snapshot from ~
  Stage                      Maintenance  auto    b-in  wf:1  fixes:1  Stage install files from the network share to C:\Temp (hash verifie~
 CHANGE - changes the host: after hours, rollback point + YES
  ExpandDisk                 Maintenance  hybrid  b-in  wf:1  fixes:0  Grow OS disk + extend C: when free space is under Lansweeper.OkGB (~
  SnapFinal                  Maintenance  auto    b-in  wf:1  fixes:0  Snapshot point 4: all disks, the last step, after your manual check
  SnapPostSql                Maintenance  auto    b-in  wf:1  fixes:0  Snapshot point 3: all disks after the last SQL-invasive step
  SnapPreSql                 Maintenance  hybrid  b-in  wf:1  fixes:0  Snapshot point 2: all disks before the first SQL-invasive step (oth~
  Upgrade                    Maintenance  guided  b-in  wf:1  fixes:0  Run the upgrade/update from C:\Temp (OS in-place upgrade or SQL SP/~
 Enter view | N new | E edit | C copy | D delete | K known fixes | Esc | F2 show log | F3 full log

```

An action has: name, one-line title, **category** (`ReadOnly` reads only, any time; `Staging` writes into
`C:\Temp` only, allowed in business hours; `Change` changes the host: after hours, rollback point + `YES`), group
(free text: OS, Disk, SQL, Services, Agents...), instruction lines, commands to paste, what success looks like, and
for read-only ones whether the host runbook may run the commands. `N` new, `E` edit (field by field, Enter keeps a
value), `C` copy, `D` delete (type `DELETE`; it is removed from the workflows that use it, its known fixes go with
it), `K` known fixes. The ten maintenance steps are built-in actions: they can be added to any workflow, not edited.

### Known fixes

`K` in the manager, on an action, or on a step. `N` records one, `E` edits, `D` deletes (type `DELETE`). Each fix
shows how often it helped and did not. Three generic built-in ones exist (execution policy, not running as
Administrator, not enough space while staging).

### Shared library

Your workflows, actions and known fixes are encrypted in `workflows.vmm` (same key as the fleet store), so other
technicians cannot read them. To share: `X` exports them to a **plain JSON library** (`Workflow.LibraryPath`, e.g. on
the network share; empty = asked), `I` imports one. The export is sanitized (host names, FQDNs, IPs, ids, secrets
replaced) and refused when a fleet host name would still be in it; an existing library is merged, not overwritten.
On import the newer copy of an item wins and fix counters keep the higher value; library actions with an unknown
category become `Change` (strictest gates) and built-ins cannot be replaced. CLI: `vmm library-export`,
`vmm library-import`.

## Design choices (2.19.0)

| Choice | Default picked | Why |
|---|---|---|
| Where tickets live | On the host record in the encrypted fleet store (`Ticket`: Workflow, Steps, Priority, Assignee, Notes) | A host already is the unit of work; one store, one backup, one lock |
| Where workflows / actions / known fixes live | `workflows.vmm`, encrypted, per user; built-ins in code | Same protection as the fleet store; built-ins cannot be lost or edited by accident |
| Sharing between technicians | Export / import of a sanitized JSON library on the share | The store key is DPAPI-bound to one Windows account; a shared plain file is the only way, so it must hold no environment values |
| Step state | `record.Steps`: the step name for the ten maintenance steps, `W:<action id>` for the rest | Fleet stage, plan, reports and the ticket view agree on the maintenance steps |
| Steps changed on one ticket | Copy-on-edit list on the ticket (`R` resets) | Changing a workflow for one odd host must not change it for everybody |
| Who did it | Not recorded (no usernames are stored); the ticket has a free-text Assignee | Project rule: no usernames or passwords |
| Change order | A Change step needs every earlier step finished; read-only steps in any order | Same rule as the maintenance workflow; checks can be done whenever |
| Tickets for IT | Plain text in `Reports\Tickets`, sanitized unless `-IncludeTarget` | The IT person needs readable text; the default never puts a host name in a file |
| Host runbook result | Plain `VMMW1` lines, base64 fields; never sets the ten maintenance steps | It is typed by a person on the host; vmm records its own steps itself, like the Extractor rule |

## Limits (alpha)

- Tested offline only (smoke test section 12 with mocked stores); the screens were rendered in a terminal emulator,
  not yet on a real Windows console, RDP session or real host.
- Counters "done today" use the time of the last finished step; a host finished before 2.19.0 counts by its history.
- Built-in known fixes count helped / not helped only in this session (they are not stored).
- The Plan screen (`1`) and `vmm next` still follow the ten maintenance steps; tickets on other workflows are worked
  from the ticket board.

_Last updated: 2026-11-18 00:02 UTC_
