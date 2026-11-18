function Show-VmmActionLibraryScreen {
    # The action library, grouped by category (ReadOnly, Staging, Change) and group. N new, Enter/E edit,
    # C copy, D delete (also removes it from the workflows that use it, after DELETE), K known fixes.
    [CmdletBinding()]
    param()
    $sel = 1; $status = ''
    while ($true) {
        $cat = Get-VmmWorkflowCatalog
        $list = @($cat.Actions | Sort-Object @{ e = { @{ ReadOnly = 0; Staging = 1; Change = 2 }["$($_.Category)"] } }, Group, Name)
        $rows = @(); $map = @(); $last = ''
        foreach ($a in $list) {
            if ($a.Category -ne $last) { $rows += @{ Text = "$($a.Category.ToUpper())$(switch ($a.Category) { 'ReadOnly' { ' - reads only, any time' } 'Staging' { ' - writes into C:\Temp only, allowed in business hours' } 'Change' { ' - changes the host: after hours, rollback point + YES' } })"; Header = $true }; $map += $null; $last = $a.Category }
            $used = @($cat.Workflows | Where-Object { @($_.Steps) -contains $a.Id }).Count
            $kb = @($cat.Kb | Where-Object ActionId -eq $a.Id).Count
            $rows += @{ Text = ('{0,-26} {1,-12} {2,-7} {3,-5} wf:{4,-2} fixes:{5,-2} {6}' -f $a.Name, $a.Group, $a.Mode.ToLower(), $(if ($a.BuiltinItem) { 'b-in' } else { 'own' }), $used, $kb, $a.Title)
                        Color = $(if ($a.Category -eq 'Change') { 'Yellow' } else { 'Gray' }) }
            $map += , $a
        }
        $r = Invoke-VmmListView -Title "Action library: $($list.Count) action(s)" -ColumnHeader ('  {0,-26} {1,-12} {2,-7} {3,-5} {4,-5} {5,-8} {6}' -f 'Action', 'Group', 'Mode', 'Kind', 'Used', 'Fixes', 'What it does') `
             -Rows $rows -Selected $sel -Status $status -Hotkeys @('N', 'E', 'C', 'D', 'K') -Help 'Enter view | N new | E edit | C copy | D delete | K known fixes | Esc'
        $sel = $r.Index; $status = ''
        $a = $map[$r.Index]
        switch ($r.Action) {
            'Esc'   { return }
            'Enter' { if ($a) { Show-VmmActionScreen -ActionId $a.Id } }
            'N'     { $n = Edit-VmmActionFromTui; if ($n) { $status = "Created '$($n.Name)': add it to a workflow (workflow manager > Enter > A)" } }
            'E'     { if ($a -and $a.Builtin) { $status = 'A maintenance step: vmm runs it with its own checks (not editable)' } elseif ($a) { [void](Edit-VmmActionFromTui -ActionId $a.Id) } }
            'C'     { if ($a -and $a.Builtin) { $status = 'A maintenance step cannot be copied: create a guided action (N)' } elseif ($a) { [void](Edit-VmmActionFromTui -ActionId $a.Id -Copy) } }
            'K'     { if ($a) { Show-VmmKnowledgeScreen -ActionId $a.Id } }
            'D'     { if ($a -and $a.BuiltinItem) { $status = 'Built-in actions cannot be deleted' }
                      elseif ($a) { [void](Invoke-VmmTuiAction -Title "Delete action '$($a.Name)'" -Action {
                          $wfs = @($cat.Workflows | Where-Object { @($_.Steps) -contains $a.Id })
                          if ($wfs) { Write-VmmLog "Used by: $(@($wfs | ForEach-Object { $_.Name }) -join ', '). It is removed from them too." -Level Warn }
                          Write-VmmLog 'Recorded results on hosts stay in their history. Its known fixes are deleted with it.' -Level Muted
                          if ((Read-VmmPrompt "Type DELETE to delete '$($a.Name)'") -cne 'DELETE') { Write-VmmLog 'Cancelled - nothing deleted.' -Level Muted; return }
                          $ws = $cat.Store
                          $ws.Actions = @($ws.Actions | Where-Object Id -ne $a.Id)
                          $ws.Kb = @($ws.Kb | Where-Object ActionId -ne $a.Id)
                          foreach ($w in $ws.Workflows) { if (@($w.Steps) -contains $a.Id) { $w.Steps = @($w.Steps | Where-Object { $_ -ne $a.Id }); $w.Updated = (Get-Date).ToUniversalTime().ToString('o') } }
                          Save-VmmWorkflowStore -Store $ws
                          Write-VmmLog "Deleted '$($a.Name)'." -Level Success }) } }
        }
    }
}
