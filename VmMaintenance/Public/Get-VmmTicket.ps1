function Get-VmmTicket {
    <#
    .SYNOPSIS
        Hosts as tickets: state, workflow, progress, next step, priority, assignee - or the counters (-Summary).
    .DESCRIPTION
        Every host in the fleet is a ticket. Its workflow is the one chosen on the ticket, else the DEFAULT
        workflow (workflow manager). State: New, InProgress, Blocked, Failed, OnHold, Excluded (client OS without
        orders), NotNeeded (already on the target OS), Done.
        -Summary returns the counters shown on the ticket board: per state, per workflow, per next step, per
        priority, done today, steps done and failed today, pending, and the daily target (Get-VmmDailyProgress).
    .EXAMPLE
        Get-VmmTicket | Where-Object State -eq 'Failed'
    .EXAMPLE
        Get-VmmTicket -Summary
    #>
    [CmdletBinding()]
    param([string]$Filter = '*', [string]$State, [switch]$Summary, $Store, $Catalog)
    if (-not $Store) { $Store = Read-VmmStore }
    if (-not $Catalog) { $Catalog = Get-VmmWorkflowCatalog }
    $w = Get-VmmTimeWindow
    $tz = try { [TimeZoneInfo]::FindSystemTimeZoneById($w.ZoneId) } catch { [TimeZoneInfo]::Utc }
    $today = $w.ZoneTime.Date
    $isToday = { param($at) $at -and ([TimeZoneInfo]::ConvertTimeFromUtc((ConvertTo-VmmUtcDate $at), $tz).Date -eq $today) }
    $prio = @{ High = 0; Normal = 1; Low = 2 }
    $rows = foreach ($h in @($Store.Hosts | Where-Object { $_.Name -like $Filter })) {
        $res = Resolve-VmmHostWorkflow -Record $h -Catalog $Catalog -Window $w
        $st = Get-VmmTicketState -Record $h -Resolved $res
        $keys = @($res.Steps | ForEach-Object { $_.Key })
        $hist = @($h.History | Where-Object { $keys -contains $_.Step })
        $last = $res.Steps | Where-Object Finished | Select-Object -Last 1
        [pscustomobject]@{
            Name = $h.Name; State = $st; Priority = $res.Ticket.Priority; Assignee = $res.Ticket.Assignee
            Workflow = $res.Workflow.Name; WorkflowId = $res.Workflow.Id; IsDefault = $res.IsDefault; Custom = $res.Custom
            Done = $res.Done; Total = $res.Total; Progress = "$($res.Done)/$($res.Total)"
            Next = $(if ($res.Next) { $res.Next.Action.Name }); NextCategory = $(if ($res.Next) { $res.Next.Action.Category })
            NextAllowed = $(if ($res.Next) { $res.Next.Allowed }); Notes = $res.Ticket.Notes
            DoneToday = ($st -eq 'Done' -and $last -and (& $isToday $last.At))
            StepsToday = @($hist | Where-Object { $_.Result -in 'Success', 'NotNeeded' -and (& $isToday $_.At) }).Count
            FailedToday = @($hist | Where-Object { $_.Result -in 'Failed', 'Blocked' -and (& $isToday $_.At) }).Count
            Platform = $h.Platform; Updated = $res.Ticket.Updated
        }
    }
    $rows = @($rows | Sort-Object @{ e = { if ($prio.ContainsKey("$($_.Priority)")) { $prio["$($_.Priority)"] } else { 1 } } }, Name)
    if ($State) { $rows = @($rows | Where-Object { $_.State -like $State }) }
    if (-not $Summary) { return $rows }
    $count = { param($prop) $o = [ordered]@{}; foreach ($g in ($rows | Group-Object $prop | Sort-Object Name)) { $o["$($g.Name)"] = $g.Count }; $o }
    $byState = [ordered]@{}
    foreach ($s in 'New', 'InProgress', 'Blocked', 'Failed', 'OnHold', 'Excluded', 'NotNeeded', 'Done') { $byState[$s] = @($rows | Where-Object State -eq $s).Count }
    $byWf = [ordered]@{}
    foreach ($g in ($rows | Group-Object Workflow | Sort-Object Name)) {
        $byWf["$($g.Name)"] = [pscustomobject]@{ Total = $g.Count; Done = @($g.Group | Where-Object State -eq 'Done').Count; Open = @($g.Group | Where-Object { $_.State -in 'New', 'InProgress', 'Blocked', 'Failed' }).Count }
    }
    $prog = try { Get-VmmDailyProgress -Store $Store } catch { $null }
    [pscustomobject]@{
        Total = $rows.Count; ByState = $byState
        Pending = $byState.New + $byState.InProgress; NeedsHelp = $byState.Blocked + $byState.Failed
        DoneToday = @($rows | Where-Object DoneToday).Count
        StepsToday = [int](($rows | Measure-Object StepsToday -Sum).Sum); FailedToday = [int](($rows | Measure-Object FailedToday -Sum).Sum)
        ByWorkflow = $byWf; ByNextStep = (& $count 'Next'); ByPriority = (& $count 'Priority')
        Target = $prog; Window = $w
    }
}
