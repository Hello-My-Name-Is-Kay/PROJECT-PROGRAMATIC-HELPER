function Show-VmmWorkflowEditScreen {
    # Steps of one workflow: add an action from the library (A), create a new action and add it (N), remove a step
    # (X), move steps (U up, J down), open/edit an action (Enter). Built-in workflows are shown read-only.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkflowId)
    $sel = 0; $status = ''
    while ($true) {
        $cat = Get-VmmWorkflowCatalog
        $wf = $cat.Workflows | Where-Object Id -eq $WorkflowId | Select-Object -First 1
        if (-not $wf) { return }
        $ro = [bool]$wf.BuiltinItem
        $steps = @($wf.Steps)
        $rows = @(for ($i = 0; $i -lt $steps.Count; $i++) {
            $a = $cat.Actions | Where-Object Id -eq $steps[$i] | Select-Object -First 1
            if ($a) { @{ Text = ('{0,2}. {1,-26} {2,-9} {3,-7} {4,-12} {5}' -f ($i + 1), $a.Name, $a.Category, $a.Mode.ToLower(), $a.Group, $a.Title); Color = $(if ($a.Category -eq 'Change') { 'Yellow' } else { 'Gray' }) } }
            else { @{ Text = ('{0,2}. (action {1} was deleted - X removes this step)' -f ($i + 1), $steps[$i]); Color = 'Red' } }
        })
        if (-not $rows.Count) { $rows = @(@{ Text = '(no steps yet: A adds an action from the library, N creates a new one)'; Color = 'DarkGray' }) }
        if (-not $status -and $ro) { $status = 'Built-in workflow: read-only. C in the workflow manager makes an editable copy.' }
        $r = Invoke-VmmListView -Title "Workflow: $($wf.Name)$(if ($wf.Id -eq $cat.Default) { ' [DEFAULT]' }) - $($wf.Description)" `
             -ColumnHeader ('    {0,-26} {1,-9} {2,-7} {3,-12} {4}' -f 'Action', 'Category', 'Mode', 'Group', 'What it does') `
             -Rows $rows -Selected $sel -Status $status -Hotkeys @('A', 'N', 'X', 'U', 'J', 'K') `
             -Help 'Enter open action | A add from library | N new action | X remove step | U up | J down | K known fixes | Esc'
        $sel = $r.Index; $status = ''
        $cur = if ($steps.Count) { $steps[[math]::Min($r.Index, $steps.Count - 1)] } else { $null }
        $edit = { param($sb) if ($ro) { $script:VmmWfStatus = 'Built-in workflow: copy it first (C in the workflow manager)'; return }
                  $ws = $cat.Store; $o = $ws.Workflows | Where-Object Id -eq $WorkflowId; & $sb $o; $o.Updated = (Get-Date).ToUniversalTime().ToString('o'); Save-VmmWorkflowStore -Store $ws }
        $script:VmmWfStatus = ''
        switch ($r.Action) {
            'Esc'   { return }
            'Enter' { if ($cur) { $a = $cat.Actions | Where-Object Id -eq $cur | Select-Object -First 1; if ($a) { Show-VmmActionScreen -ActionId $a.Id } } }
            'K'     { if ($cur) { Show-VmmKnowledgeScreen -ActionId $cur } }
            'A'     { if ($ro) { $status = 'Built-in workflow: copy it first (C in the workflow manager)' } else {
                          $pick = Select-VmmFromList -Title "Add a step to '$($wf.Name)' (after step $($sel + 1))" -Items @($cat.Actions | Sort-Object Category, Group, Name) `
                                  -Label { param($x) '{0,-26} {1,-12} {2}' -f $x.Name, $x.Group, $x.Title } -Group { param($x) $x.Category }
                          if ($pick) {
                              if ($steps -contains $pick.Id) { $status = "'$($pick.Name)' is already a step of this workflow" }
                              else { $pos = if ($steps.Count) { $sel + 1 } else { 0 }; & $edit { param($o) $l = [Collections.ArrayList]@($o.Steps); $l.Insert([math]::Min($pos, $l.Count), $pick.Id); $o.Steps = @($l) }; $sel = $pos; $status = "Added '$($pick.Name)'" }
                          } } }
            'N'     { if ($ro) { $status = 'Built-in workflow: copy it first (C in the workflow manager)' } else {
                          $new = Edit-VmmActionFromTui
                          if ($new) { $pos = if ($steps.Count) { $sel + 1 } else { 0 }; & $edit { param($o) $l = [Collections.ArrayList]@($o.Steps); $l.Insert([math]::Min($pos, $l.Count), $new.Id); $o.Steps = @($l) }; $sel = $pos; $status = "Created and added '$($new.Name)'" } } }
            'X'     { if ($cur -and -not $ro) {
                          if ((Read-VmmPrompt "Remove step $($sel + 1) from '$($wf.Name)'? The action stays in the library (y/N)") -match '^[yY]') { $i = $sel; & $edit { param($o) $l = [Collections.ArrayList]@($o.Steps); $l.RemoveAt($i); $o.Steps = @($l) }; $status = 'Step removed' }
                          Clear-Host } elseif ($ro) { $status = 'Built-in workflow: copy it first' } }
            'U'     { if ($cur -and $sel -gt 0 -and -not $ro) { $i = $sel; & $edit { param($o) $l = @($o.Steps); $t = $l[$i - 1]; $l[$i - 1] = $l[$i]; $l[$i] = $t; $o.Steps = $l }; $sel-- } }
            'J'     { if ($cur -and $sel -lt $steps.Count - 1 -and -not $ro) { $i = $sel; & $edit { param($o) $l = @($o.Steps); $t = $l[$i + 1]; $l[$i + 1] = $l[$i]; $l[$i] = $t; $o.Steps = $l }; $sel++ } }
        }
        if ($script:VmmWfStatus) { $status = $script:VmmWfStatus }
    }
}
