function Show-VmmTicketRunScreen {
    # Work on one ticket: the steps of its workflow with their state, and the step dialogue on Enter.
    # Step list for this host only: A adds an action after the selected step, X removes one, U/J move, R resets to
    # the workflow's list. W picks the workflow (DEFAULT or another), E edits the ticket, B builds the host
    # runbook (.ps1 + .cmd to paste over RDP), I imports what the runbook wrote, L opens remote desktop,
    # K known fixes of the selected step, V the host's maintenance screen.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName)
    $sel = 0; $status = ''
    while ($true) {
        $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $HostName
        $cat = Get-VmmWorkflowCatalog
        $res = Resolve-VmmHostWorkflow -Record $rec -Catalog $cat
        $state = Get-VmmTicketState -Record $rec -Resolved $res
        $steps = @($res.Steps)
        $rows = @(foreach ($s in $steps) {
            $col = switch -Regex ($s.Status) { '^(Success|NotNeeded)$' { 'Green' } '^(Failed|Blocked)$' { 'Red' } '^(Skipped|Pending|Running|Launched)$' { 'Yellow' } default { if ($s.Allowed) { 'Gray' } else { 'DarkGray' } } }
            $kb = @($cat.Kb | Where-Object ActionId -eq $s.Action.Id).Count
            $info = if ($s.Note) { $s.Note } elseif (-not $s.Allowed) { $s.Why } else { $s.Action.Title }
            @{ Text = ('{0,2}. {1,-26} {2,-9} {3,-10} {4,-6} {5,-3} {6}' -f $s.Index, $s.Action.Name, $s.Action.Category, $(if ($s.Status) { $s.Status } else { 'todo' }), $(if ($s.Allowed) { 'now' } else { 'later' }), $(if ($kb) { "k$kb" }), $info); Color = $col }
        })
        if (-not $rows.Count) { $rows = @(@{ Text = '(this workflow has no steps: A adds one for this host, W picks another workflow)'; Color = 'DarkGray' }) }
        if (-not $status) {
            if ($res.Missing) { $status = "WARN: $($res.Missing.Count) step(s) of this workflow point to deleted actions (skipped)." }
            elseif ($state -eq 'Excluded') { $status = "POLICY: $($res.Policy.Why)" }
            elseif ($res.Next) { $status = "Next: $($res.Next.Action.Name) - Enter opens it$(if (-not $res.Next.Allowed) { ". $($res.Next.Why)" })" }
            else { $status = 'All steps finished: ticket Done.' }
        }
        $wfn = "$($res.Workflow.Name)$(if ($res.IsDefault) { ' (default)' })$(if ($res.Custom) { ' + changed on this ticket' })"
        $r = Invoke-VmmListView -Title "$($rec.Name) | $state | $wfn | $($res.Done)/$($res.Total) | $(if ($rec.Platform) { $rec.Platform } else { 'platform ?' }) | prio $($res.Ticket.Priority)" `
             -ColumnHeader ('    {0,-26} {1,-9} {2,-10} {3,-6} {4,-3} {5}' -f 'Step', 'Category', 'Status', 'When', 'Fix', 'Note') `
             -Rows $rows -Selected $sel -Status $status -Hotkeys @('W', 'E', 'A', 'X', 'U', 'J', 'R', 'B', 'I', 'L', 'K', 'V') `
             -Help 'Enter open step | W workflow | A add step | X remove | U/J move | R reset steps | B runbook | I import | L RDP | K fixes | E edit | V host | Esc'
        $sel = $r.Index; $status = ''
        $cur = if ($steps.Count) { $steps[[math]::Min($r.Index, $steps.Count - 1)] } else { $null }
        $hostSteps = {
            param($sb)
            $st2 = Read-VmmStore; $rc = Get-VmmHostRecord -Store $st2 -Name $HostName; $t = Initialize-VmmTicket -Record $rc
            if ($null -eq $t.Steps) { $t.Steps = @($res.Steps | ForEach-Object { $_.Action.Id }) }
            $l = [Collections.ArrayList]@($t.Steps); & $sb $l; $t.Steps = @($l)
            $t.Updated = (Get-Date).ToUniversalTime().ToString('o'); Save-VmmStore -Store $st2
        }
        switch ($r.Action) {
            'Esc'   { return }
            'Enter' { if ($cur) { Show-VmmStepDialog -HostName $rec.Name -ActionId $cur.Action.Id } }
            'W'     { $status = Select-VmmTicketWorkflow -HostName $rec.Name }
            'E'     { [void](Invoke-VmmTuiAction -Title "Edit ticket $($rec.Name)" -Action { Edit-VmmTicketFromTui -HostName $HostName }) }
            'A'     { $pick = Select-VmmFromList -Title "Add a step for $($rec.Name) only (after step $($sel + 1))" -Items @($cat.Actions | Sort-Object Category, Group, Name) `
                              -Label { param($x) '{0,-26} {1,-12} {2}' -f $x.Name, $x.Group, $x.Title } -Group { param($x) $x.Category } -Status 'The workflow itself is not changed (workflow manager K for that).'
                      if ($pick) {
                          if (@($steps | Where-Object { $_.Action.Id -eq $pick.Id }).Count) { $status = "'$($pick.Name)' is already a step here" }
                          else { $pos = if ($steps.Count) { $sel + 1 } else { 0 }; & $hostSteps { param($l) $l.Insert([math]::Min($pos, $l.Count), $pick.Id) }; $sel = $pos; $status = "Added '$($pick.Name)' for this host" } } }
            'X'     { if ($cur) {
                          if ($cur.Status -and $cur.Action.Category -eq 'Change') { $status = 'A change step that already ran cannot be removed from the ticket (its record stays)' }
                          elseif ((Read-VmmPrompt "Remove '$($cur.Action.Name)' from this ticket only? (y/N)") -match '^[yY]') { $id = $cur.Action.Id; & $hostSteps { param($l) $l.Remove($id) }; $status = 'Step removed from this ticket' }
                          Clear-Host } }
            'U'     { if ($cur -and $sel -gt 0) { $i = $sel; & $hostSteps { param($l) $t = $l[$i - 1]; $l[$i - 1] = $l[$i]; $l[$i] = $t }; $sel-- } }
            'J'     { if ($cur -and $sel -lt $steps.Count - 1) { $i = $sel; & $hostSteps { param($l) $t = $l[$i + 1]; $l[$i + 1] = $l[$i]; $l[$i] = $t }; $sel++ } }
            'R'     { $null = Set-VmmTicket -HostName $rec.Name -ResetSteps 6>$null; $status = "Steps reset to the workflow '$($res.Workflow.Name)'" }
            'B'     { [void](Invoke-VmmTuiAction -Title "Host runbook for $($rec.Name)" -Action { Export-VmmWorkflowRunbook -HostName $HostName | Out-Null }) }
            'I'     { [void](Invoke-VmmTuiAction -Title "Import runbook result for $($rec.Name)" -Action {
                          $clip = try { (Get-Clipboard) -join "`n" } catch { '' }
                          if ($clip -match 'VMMW1\|') { Import-VmmRunbookResult -Text $clip; return }
                          $p = Read-VmmPrompt 'Path of the VMMW_*.txt file the runbook wrote (drag it here), or paste its first line'
                          if ($p -and (Test-Path -LiteralPath $p.Trim('"') -PathType Leaf)) { Import-VmmRunbookResult -Path $p.Trim('"') } elseif ($p) { Import-VmmRunbookResult -Text $p } }) }
            'L'     { [void](Invoke-VmmTuiAction -Title "Remote desktop - $($rec.Name)" -Action { Start-VmmRemoteSession -HostName $HostName -Client Ask }) }
            'K'     { if ($cur) { Show-VmmKnowledgeScreen -ActionId $cur.Action.Id } }
            'V'     { $script:VmmInTicketRun = $true; try { Show-VmmHostScreen -HostName $rec.Name } finally { $script:VmmInTicketRun = $false } }
        }
    }
}
