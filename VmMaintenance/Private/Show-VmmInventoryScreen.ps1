function Show-VmmInventoryScreen {
    # One host's inventory: every column, its value and where it came from. Missing columns are red.
    # Enter = help window for the column, then type the value (Enter keeps it, '-' clears what you typed).
    # F = walk through every missing column. T = ask for a better help text (GitHub issue).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName)
    $sel = 0; $status = ''
    $ask = {
        param($f)
        Write-VmmLog "$($f.Header)" -Level Info
        foreach ($l in ($f.Help -split '(?<=\.)\s+(?=[A-Z])')) { Write-VmmLog "  $l" -Level Muted }
        $how = switch ($f.Source) {
            'Auto'    { 'Read automatically by Check (3 / C) or the host agent. Type a value only if the host cannot be read.' }
            'Derived' { 'Filled from the workflow. A typed value replaces it.' }
            default   { 'Typed by you. Same for many hosts? Set it once in Inventory.Defaults (setup wizard, page Inventory).' }
        }
        Write-VmmLog "  $how" -Level Muted
        Write-VmmLog "  Now: $(if ($f.Value) { "$($f.Value) [$($f.Origin)]" } else { '(empty)' })" -Level Info
        if ($f.Key -eq 'Hostname') { return 'skip' }
        $v = Read-VmmPrompt "New value (Enter = keep, '-' = clear what you typed, 'q' = stop)"
        if ($v -eq 'q') { return 'stop' }
        if ($v -eq '-') { Set-VmmInventoryValue -HostName $HostName -Field $f.Key -Clear }
        elseif ($v) { Set-VmmInventoryValue -HostName $HostName -Field $f.Key -Value $v }
        'ok'
    }
    while ($true) {
        $store = Read-VmmStore
        $rec = Get-VmmHostRecord -Store $store -Name $HostName
        $fields = @(Get-VmmInventoryRow -Record $rec)
        $miss = @($fields | Where-Object Missing).Count
        $rows = foreach ($f in $fields) {
            $from = if ($f.Missing) { 'MISSING' } elseif ($f.Origin) { $f.Origin } else { '-' }
            $col = if ($f.Missing) { 'Red' } elseif ($f.Origin -in 'manual', 'default') { 'Cyan' } elseif ($f.Value) { 'Green' } else { 'DarkGray' }
            @{ Text = ('{0,-24} {1,-14} {2}' -f $f.Header, $from, $f.Value); Color = $col }
        }
        if (-not $status) { $status = if ($miss) { "$miss column(s) missing: F walks you through them with help" } else { 'All required columns filled.' } }
        $r = Invoke-VmmListView -Title "Inventory - $HostName ($($fields.Count - $miss)/$($fields.Count) filled)" `
             -ColumnHeader ('   {0,-24} {1,-14} {2}' -f 'Column', 'From', 'Value') -Rows @($rows) -Selected $sel -Status $status `
             -Hotkeys @('F', 'T', 'C', 'E') -Help 'Enter help + edit | F fill missing | T suggest help text | C check host | E export CSV | Esc'
        $sel = $r.Index; $status = ''
        $f = $fields[$r.Index]
        switch ($r.Action) {
            'Esc'   { return }
            'Enter' { [void](Invoke-VmmTuiAction -Title "Inventory - $HostName" -Action { [void](& $ask $f) }) }
            'F'     { [void](Invoke-VmmTuiAction -Title "Fill missing columns - $HostName" -Action {
                          $todo = @($fields | Where-Object Missing)
                          if (-not $todo) { Write-VmmLog 'Nothing missing.' -Level Success; return }
                          foreach ($m in $todo) { Write-Host ''; if ((& $ask $m) -eq 'stop') { break } }
                      }) }
            'T'     { [void](Invoke-VmmTuiAction -Title "Help text - $($f.Header)" -Action { New-VmmHelpTextIssue -Field $f.Key }) }
            'C'     { [void](Invoke-VmmTuiAction -Title "Check $HostName" -Action { Invoke-VmmFleetCheck -Name $HostName }) }
            'E'     { [void](Invoke-VmmTuiAction -Title 'Inventory export' -Action { Get-VmmInventory -Export }) }
        }
    }
}
