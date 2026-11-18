function Show-VmmTicketScreen {
    # Ticket board (main menu T): every host is a ticket, grouped by state (needs help first). Counters on top.
    # Enter = work on it (guided workflow), N new ticket (adds the host), E edit, W workflow, D delete (type the
    # host name), H hold, F filter, O overview (all counters), K workflow manager.
    [CmdletBinding()]
    param()
    $sel = 1; $status = ''; $filter = '*'
    $order = 'Failed', 'Blocked', 'InProgress', 'New', 'OnHold', 'NotNeeded', 'Excluded', 'Done'
    $label = @{ Failed = 'FAILED - needs a fix (known fixes on Enter)'; Blocked = 'BLOCKED - waiting for access or a person'; InProgress = 'IN PROGRESS'; New = 'NEW'
                OnHold = 'ON HOLD (H)'; NotNeeded = 'NOT NEEDED - already on the target OS'; Excluded = 'EXCLUDED - client OS, no orders'; Done = 'DONE' }
    while ($true) {
        $store = Read-VmmStore; $cat = Get-VmmWorkflowCatalog
        $all = @(Get-VmmTicket -Store $store -Catalog $cat)
        $list = @($all | Where-Object { $_.Name -like $filter })
        $s = $all | Group-Object State -AsHashTable -AsString
        $cnt = { param($k) if ($s -and $s.ContainsKey($k)) { @($s[$k]).Count } else { 0 } }
        $prog = try { Get-VmmDailyProgress -Store $store } catch { $null }
        $head = "Tickets $($all.Count) | new $(& $cnt 'New') | in progress $(& $cnt 'InProgress') | failed $(& $cnt 'Failed') | blocked $(& $cnt 'Blocked') | hold $(& $cnt 'OnHold') | done $(& $cnt 'Done') (today $(@($all | Where-Object DoneToday).Count))"
        if ($prog) { $head += " | target $($prog.Done)/$($prog.Target) $($prog.Status)" }
        $rows = @(); $map = @()
        foreach ($st in $order) {
            $g = @($list | Where-Object State -eq $st)
            if (-not $g.Count) { continue }
            $rows += @{ Text = "$($label[$st]) ($($g.Count))"; Header = $true }; $map += $null
            foreach ($t in $g) {
                $col = switch ($st) { 'Failed' { 'Red' } 'Blocked' { 'Red' } 'InProgress' { 'Yellow' } 'Done' { 'Green' } 'NotNeeded' { 'Green' } 'OnHold' { 'DarkGray' } 'Excluded' { 'DarkGray' } default { 'Gray' } }
                $wfn = "$($t.Workflow)$(if ($t.IsDefault) { '*' })$(if ($t.Custom) { '+' })"
                $nx = if ($t.Next) { "$($t.Next)$(if ($t.NextAllowed -eq $false) { ' (later)' })" } else { '-' }
                $rows += @{ Text = ('{0,-6} {1,-18} {2,-22} {3,6} {4,-28} {5,-14} {6}' -f $t.Priority, $t.Name, $wfn, $t.Progress, $nx, "$($t.Assignee)", ("$($t.Notes)" -replace '^(.{0,40}).*', '$1')); Color = $col }
                $map += , $t
            }
        }
        if (-not $rows.Count) { $rows = @(@{ Text = '(no tickets: N creates one, or import hosts with 0 in the main menu)'; Color = 'DarkGray' }); $map = @($null) }
        $r = Invoke-VmmListView -Title "$head$(if ($filter -ne '*') { " | filter $filter" })" `
             -ColumnHeader ('  {0,-6} {1,-18} {2,-22} {3,6} {4,-28} {5,-14} {6}' -f 'Prio', 'Host', 'Workflow (*default)', 'Steps', 'Next step', 'Assignee', 'Notes') `
             -Rows $rows -Selected $sel -Status $status -Hotkeys @('N', 'E', 'W', 'D', 'H', 'F', 'O', 'K') `
             -Help 'Enter work on it | N new | E edit | W workflow | D delete | H hold | F filter | O overview | K workflow manager | Esc'
        $sel = $r.Index; $status = ''
        $t = $map[$r.Index]
        switch ($r.Action) {
            'Esc'   { return }
            'Enter' { if ($t) { Show-VmmTicketRunScreen -HostName $t.Name } }
            'N'     { [void](Invoke-VmmTuiAction -Title 'New ticket (adds the host to the fleet)' -Action {
                          $n = Read-VmmField -Prompt 'Host name or FQDN' -Required
                          [void](Set-VmmTicket -HostName $n -New)
                          Edit-VmmTicketFromTui -HostName $n }) }
            'E'     { if ($t) { [void](Invoke-VmmTuiAction -Title "Edit ticket $($t.Name)" -Action { Edit-VmmTicketFromTui -HostName $t.Name }) } }
            'W'     { if ($t) { $status = Select-VmmTicketWorkflow -HostName $t.Name } }
            'D'     { if ($t) { [void](Invoke-VmmTuiAction -Title "Delete ticket $($t.Name)" -Action {
                          $rec = Get-VmmHostRecord -Store $store -Name $t.Name
                          Write-VmmLog "Deleting the ticket removes $($t.Name) from the fleet: its history ($(@($rec.History).Count) entries), blockers and inventory go with it." -Level Warn
                          Write-VmmLog 'Reports already written stay in the Reports folder. Nothing on the host changes.' -Level Muted
                          if ((Read-VmmPrompt "Type the host name ($($t.Name)) to delete it") -ne $t.Name) { Write-VmmLog 'Cancelled - nothing deleted.' -Level Muted; return }
                          Remove-VmmFleetHost -Name $t.Name -Confirm:$false }) } }
            'H'     { if ($t) { $rec = Get-VmmHostRecord -Store $store -Name $t.Name; $rec.Hold = -not $rec.Hold; Save-VmmStore -Store $store; $status = "$($t.Name): hold = $($rec.Hold)" } }
            'F'     { $f = Read-VmmPrompt 'Filter host names (wildcards, empty = all)'; $filter = if ($f) { $f } else { '*' }; $sel = 1; Clear-Host }
            'O'     { Show-VmmTicketOverview }
            'K'     { Show-VmmWorkflowManagerScreen }
        }
    }
}
