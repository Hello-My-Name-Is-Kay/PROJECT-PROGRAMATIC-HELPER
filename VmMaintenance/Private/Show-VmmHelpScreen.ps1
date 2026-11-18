function Show-VmmHelpScreen {
    # Keys, rules and file locations.
    [CmdletBinding()]
    param()
    $lines = @(
        'KEYS: arrows/PgUp/PgDn/Home/End move, Enter or click opens, double-click opens, wheel scrolls, Esc goes back.'
        'Letters shown in the bottom bar run actions on the selected row.'
        'F2 on any screen shows/hides the live log pane (also the progress lines of long operations). F3 = full log.'
        'Everything is also written to an encrypted day log: vmm log (-Follow for live in a 2nd window). M = maintenance.'
        ''
        'TIME RULES (Settings > Schedule):'
        '  Mon-Fri business hours: checks + staging to C:\Temp only. Changes need OVERRIDE + reason (recorded, reported).'
        '  Weekends/holidays (and weekday off-hours if enabled): everything allowed.'
        ''
        'WORKFLOW per host: 1 Precheck > 2 SnapStart > 3 Stage > 4 SnapPreSql > 5 ExpandDisk > 6 Upgrade > 7 SnapPostSql'
        '  > 8 Verify > 9 ManualCheck > 10 SnapFinal; prune at the end.'
        '  Four Azure snapshot points, every disk: start (unless one from the last hour; you may decline), before and'
        '  after the SQL-invasive steps (ExpandDisk, Upgrade), and the final one after your manual check (or its bypass).'
        '  Can''t reach a host? G opens the RDP/RDM guide; P pastes the collector result back.'
        '  Terminal copy failed? T (or: vmm handoff) opens RDP / RDM / RDCMan, lists the files, then verifies size + SHA256 on the host.'
        '  Missing access? B writes a report for your manager (you send it from Outlook) and you move on.'
        ''
        'TICKETS (T in the main menu): every host is a ticket. N new, E edit (priority, assignee, notes, workflow),'
        '  D delete (type the host name), W workflow, H hold, O overview (counters per state, workflow, next step, today).'
        '  Enter works on it: the workflow steps one by one. On a step: Enter ticks a line, C copies the command for the'
        '  RDP session, G = gate for steps that are not read-only (time window / OVERRIDE, SNAPSHOT TAKEN or BACKUP'
        '  CONFIRMED, YES), D done, F failed, S skip with a reason, K known fixes, T ticket for IT.'
        '  A / X / U / J on the ticket add, remove and move steps for that host only; R resets to the workflow.'
        '  B builds the host runbook (.ps1 + .cmd to paste over RDP); I imports the VMMW_*.txt it writes.'
        'FAILED STEP: paste what happened; vmm shows the known fixes other technicians recorded, best first.'
        '  None helped: R record your fix for the next person, T ticket for the IT person who can fix it, B blocked.'
        '  After ANY failed action, T writes advice + a ticket text (Reports\Tickets, clipboard; you send it).'
        'WORKFLOW MANAGER (K): workflows (Full maintenance = DEFAULT, Read-only snapshot, your own), S sets the'
        '  default, N/C/E/D create/copy/rename/delete; Enter edits the steps; A action library (ReadOnly / Staging /'
        '  Change, groups); K known fixes; X/I export/import the shared library (Workflow.LibraryPath, sanitized).'
        ''
        'TARGET: Target.MachinesPerDay (default 10). Counted when Stage or Verify succeeds that day.'
        ''
        'SECURITY: usernames/passwords are asked each session, kept only in memory, cleared on Quit.'
        '  Fleet data is AES-256 + HMAC encrypted; the key is DPAPI-bound to your Windows account.'
        '  Daily/blocker reports are plaintext (your manager must read them).'
        ''
        "FILES: config $script:VmmConfigPath"
        "       data   $(Get-VmmPath -Name Data)"
        "       reports $(Get-VmmPath -Name Reports)"
        "       logs   $(Get-VmmPath -Name Logs)"
        "       tickets for IT $(Get-VmmPath -Name Tickets)"
        ''
        'CLI: every action exists as a command - run: vmm help'
    )
    [void](Invoke-VmmListView -Title 'Help' -Rows @($lines | ForEach-Object { @{ Text = $_ } }) -Help 'Esc back')
}
