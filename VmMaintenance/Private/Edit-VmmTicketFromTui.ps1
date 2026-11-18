function Edit-VmmTicketFromTui {
    # Edit dialogue of one ticket (run inside Invoke-VmmTuiAction): priority, assignee, notes, workflow.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName)
    $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $HostName
    $t = Initialize-VmmTicket -Record $rec
    $cat = Get-VmmWorkflowCatalog
    Write-VmmLog "Ticket $($rec.Name) - Enter keeps the value in [brackets]. No passwords or usernames of accounts here." -Level Info
    $p = @{ HostName = $rec.Name }
    $p.Priority = Read-VmmField -Prompt 'Priority' -Current $t.Priority -Allowed 'High', 'Normal', 'Low' -Required
    $p.Assignee = Read-VmmField -Prompt 'Assignee (who works on it)' -Current $t.Assignee
    $p.Notes = Read-VmmField -Prompt 'Notes (contacts, windows, app owner...)' -Current $t.Notes
    $cur = if ($t.Workflow) { ($cat.Workflows | Where-Object Id -eq $t.Workflow | Select-Object -First 1).Name } else { 'default' }
    $n = 0; Write-VmmLog 'Workflows: 0 = DEFAULT' -Level Muted
    foreach ($w in $cat.Workflows) { $n++; Write-VmmLog ("  {0}. {1}{2}" -f $n, $w.Name, $(if ($w.Id -eq $cat.Default) { ' (the default)' })) -Level Muted }
    $a = Read-VmmPrompt "Workflow number [$cur]"
    if ($a -match '^\d+$') {
        $i = [int]$a
        if ($i -eq 0) { $p.Workflow = 'default' } elseif ($i -le $cat.Workflows.Count) { $p.Workflow = $cat.Workflows[$i - 1].Id } else { Write-VmmLog 'No such number: workflow unchanged.' -Level Warn }
    }
    Set-VmmTicket @p | Select-Object Name, State, Priority, Assignee, Workflow, Progress, Next | Format-List
}
