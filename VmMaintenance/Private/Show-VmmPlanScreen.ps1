function Show-VmmPlanScreen {
    # Work queue: every host not done/on hold with its next step and whether that step is allowed now.
    # R runs the next AUTO step on every host where it is allowed now (e.g. Precheck + Stage in business hours).
    [CmdletBinding()]
    param()
    $sel = 0; $status = ''
    while ($true) {
        $w = Get-VmmTimeWindow
        $store = Read-VmmStore
        $queue = @(Get-VmmQueue -Store $store)
        $rows = foreach ($q in $queue) {
            $how = if ($q.Guided) { 'guided' } else { 'auto' }
            $when = if ($q.Allowed) { 'allowed now' } else { "after $($w.NextChangeAt.ToString('ddd HH:mm'))" }
            $col = if ($q.State -in 'Blocked', 'Failed') { 'Red' } elseif ($q.Allowed) { 'Green' } else { 'DarkGray' }
            @{ Text = ('{0,-18} {1}. {2,-12} {3,-8} {4,-7} {5,-13} {6}' -f $q.Host, $q.Step.Order, $q.Step.Name, $q.State, $how, $when, $q.Health); Color = $col }
        }
        $doneCount = @($store.Hosts | Where-Object { -not (Get-VmmNextStep -Record $_) }).Count
        $r = Invoke-VmmListView -Title "Plan: $($queue.Count) host(s) in the queue, $doneCount done" `
             -ColumnHeader ('{0,-18} {1,-15} {2,-8} {3,-7} {4,-13} {5}' -f 'Host', 'Next step', 'State', 'How', 'When', 'Health') `
             -Rows @($rows) -Selected $sel -Status $status -Hotkeys @('R', 'C') `
             -Help 'Enter open host | R run next AUTO step on all allowed hosts | C check fleet | Esc back'
        $sel = $r.Index; $status = ''
        switch ($r.Action) {
            'Esc' { return }
            'Enter' { if ($queue.Count) { Show-VmmHostScreen -HostName $queue[$r.Index].Host } }
            'C' { [void](Invoke-VmmTuiAction -Title 'Fleet check' -Action { Invoke-VmmFleetCheck }) }
            'R' {
                [void](Invoke-VmmTuiAction -Title 'Next auto step on all allowed hosts' -Action { Invoke-VmmNextStep -All -Contact Later })
            }
        }
    }
}
