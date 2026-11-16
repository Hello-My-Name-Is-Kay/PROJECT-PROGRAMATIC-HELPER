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
        ''
        'CLI: every action exists as a command - run: vmm help'
    )
    [void](Invoke-VmmListView -Title 'Help' -Rows @($lines | ForEach-Object { @{ Text = $_ } }) -Help 'Esc back')
}
