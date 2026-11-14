function Show-VmmFleetScreen {
    # Whole fleet table with filter. Enter opens the host workflow screen.
    [CmdletBinding()]
    param()
    $sel = 0; $filter = '*'; $status = ''
    while ($true) {
        $list = @(Get-VmmFleet -Filter $filter)
        $rows = foreach ($h in $list) {
            $col = switch ($h.Health) { 'OK' { 'Green' } 'Warn' { 'Yellow' } 'Critical' { 'Red' } 'Unreachable' { 'Red' } default { 'Gray' } }
            if ($h.Hold) { $col = 'DarkGray' }
            $os = "$($h.OS)" -replace 'Microsoft Windows ', 'Win ' -replace 'Server ', 'Srv '
            @{ Text = ('{0,-18} {1,-9} {2,-11} {3,-20} {4,-24} {5,6} {6,-22} {7}' -f $h.Name, $h.Platform, $h.Health, $h.Stage, $os, $h.CFreeGB, ("$($h.Sql)" -replace '^(.{0,22}).*', '$1'), $(if ($h.Blockers) { "blk:$($h.Blockers)" })); Color = $col }
        }
        $r = Invoke-VmmListView -Title "Fleet: $($list.Count) host(s) (filter: $filter)" `
             -ColumnHeader ('{0,-18} {1,-9} {2,-11} {3,-20} {4,-24} {5,6} {6,-22} {7}' -f 'Host', 'Platform', 'Health', 'Stage', 'OS', 'C:GB', 'SQL', 'Blockers') `
             -Rows @($rows) -Selected $sel -Status $status -Hotkeys @('C', 'A', 'F', 'D') `
             -Help 'Enter open | C check selected | A check all | F filter | D remove host | Esc back'
        $sel = $r.Index; $status = ''
        switch ($r.Action) {
            'Esc'   { return }
            'Enter' { if ($list.Count) { Show-VmmHostScreen -HostName $list[$r.Index].Name } }
            'C'     { if ($list.Count) { $n = $list[$r.Index].Name; [void](Invoke-VmmTuiAction -Title "Check $n" -Action { Invoke-VmmFleetCheck -Name $n }) } }
            'A'     { [void](Invoke-VmmTuiAction -Title 'Check all' -Action { Invoke-VmmFleetCheck }) }
            'F'     { $f = Read-VmmPrompt 'Filter (wildcards, empty = all)'; $filter = if ($f) { $f } else { '*' }; $sel = 0; Clear-Host }
            'D'     { if ($list.Count) { $n = $list[$r.Index].Name; [void](Invoke-VmmTuiAction -Title "Remove $n" -Action { Remove-VmmFleetHost -Name $n }) } }
        }
    }
}
