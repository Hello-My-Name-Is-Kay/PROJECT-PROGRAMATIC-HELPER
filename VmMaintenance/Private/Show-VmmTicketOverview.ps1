function Show-VmmTicketOverview {
    # All ticket counters on one screen: per state, today (done, steps, failures, daily target), per workflow
    # (done/open/total), per next step, per priority.
    [CmdletBinding()]
    param()
    $s = Get-VmmTicket -Summary
    $rows = @()
    $bar = { param($n, $tot) if ($tot) { '#' * [math]::Round(30 * $n / $tot) } else { '' } }
    $rows += @{ Text = "TODAY ($($s.Window.ZoneTime.ToString('ddd yyyy-MM-dd HH:mm')) $($s.Window.ZoneLabel), changes $(if ($s.Window.ChangesAllowed) { 'ALLOWED' } else { 'NOT allowed: business hours' }))"; Header = $true }
    if ($s.Target) { $rows += @{ Text = ('Daily target           {0}/{1} machines, {2} expected by now: {3}' -f $s.Target.Done, $s.Target.Target, $s.Target.ExpectedByNow, $s.Target.Status); Color = $s.Target.Status } }
    $rows += @{ Text = ('Tickets done today     {0}' -f $s.DoneToday); Color = $(if ($s.DoneToday) { 'Green' } else { 'Gray' }) }
    $rows += @{ Text = ('Steps done today       {0}' -f $s.StepsToday) }
    $rows += @{ Text = ('Failures today         {0}' -f $s.FailedToday); Color = $(if ($s.FailedToday) { 'Red' } else { 'Gray' }) }
    $rows += @{ Text = ('Pending (new + open)   {0}     need help (failed + blocked) {1}' -f $s.Pending, $s.NeedsHelp); Color = $(if ($s.NeedsHelp) { 'Yellow' } else { 'Gray' }) }
    $rows += @{ Text = "BY STATE ($($s.Total) tickets)"; Header = $true }
    foreach ($k in $s.ByState.Keys) { $rows += @{ Text = ('{0,-12} {1,4}  {2}' -f $k, $s.ByState[$k], (& $bar $s.ByState[$k] $s.Total)); Color = $(switch ($k) { 'Failed' { 'Red' } 'Blocked' { 'Red' } 'Done' { 'Green' } default { 'Gray' } }) } }
    $rows += @{ Text = 'BY WORKFLOW (done / open / total)'; Header = $true }
    foreach ($k in $s.ByWorkflow.Keys) { $v = $s.ByWorkflow[$k]; $rows += @{ Text = ('{0,-30} {1,4} / {2,4} / {3,4}  {4}' -f $k, $v.Done, $v.Open, $v.Total, (& $bar $v.Done $v.Total)) } }
    $rows += @{ Text = 'BY NEXT STEP (where the tickets wait)'; Header = $true }
    foreach ($k in $s.ByNextStep.Keys) { $rows += @{ Text = ('{0,-30} {1,4}' -f $(if ($k) { $k } else { '(finished)' }), $s.ByNextStep[$k]) } }
    $rows += @{ Text = 'BY PRIORITY'; Header = $true }
    foreach ($k in $s.ByPriority.Keys) { $rows += @{ Text = ('{0,-30} {1,4}' -f $k, $s.ByPriority[$k]) } }
    [void](Invoke-VmmListView -Title 'Ticket overview' -Rows $rows -Help 'Esc back')
}
