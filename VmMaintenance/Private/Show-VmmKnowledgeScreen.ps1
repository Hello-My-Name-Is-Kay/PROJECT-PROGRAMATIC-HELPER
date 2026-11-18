function Show-VmmKnowledgeScreen {
    # Known fixes (all, or those for -ActionId plus the ones for any step): Enter opens one, N records a new one,
    # E edits, D deletes (after DELETE).
    [CmdletBinding()]
    param([string]$ActionId)
    $sel = 0; $status = ''
    while ($true) {
        $cat = Get-VmmWorkflowCatalog
        $list = @($cat.Kb | Where-Object { -not $ActionId -or $_.ActionId -eq $ActionId -or $_.ActionId -eq '*' } |
                  Sort-Object @{ e = { [int]$_.Helped - [int]$_.NotHelped }; Descending = $true }, Symptom)
        $aname = { param($id) if ($id -eq '*') { '(any step)' } else { $x = $cat.Actions | Where-Object Id -eq $id | Select-Object -First 1; if ($x) { $x.Name } else { $id } } }
        $rows = @($list | ForEach-Object { @{ Text = ('{0,-24} +{1,-3} -{2,-3} {3}' -f (& $aname $_.ActionId), [int]$_.Helped, [int]$_.NotHelped, $_.Symptom); Color = $(if ([int]$_.Helped -gt [int]$_.NotHelped) { 'Green' } else { 'Gray' }) } })
        if (-not $rows.Count) { $rows = @(@{ Text = '(no known fixes yet: N records one)'; Color = 'DarkGray' }) }
        $t = if ($ActionId) { "Known fixes for $(& $aname $ActionId)" } else { 'Known fixes (all actions)' }
        $r = Invoke-VmmListView -Title "${t}: $($list.Count)" -ColumnHeader ('  {0,-24} {1,-4} {2,-4} {3}' -f 'Action', 'Help', 'Not', 'What happened') -Rows $rows -Selected $sel -Status $status `
             -Hotkeys @('N', 'E', 'D') -Help 'Enter open | N new | E edit | D delete | Esc'
        $sel = $r.Index; $status = ''
        $e = if ($list.Count) { $list[[math]::Min($r.Index, $list.Count - 1)] } else { $null }
        switch ($r.Action) {
            'Esc'   { return }
            'Enter' { if ($e) { [void](Show-VmmKnowledgeEntry -EntryId $e.Id) } }
            'N'     { [void](Edit-VmmKnowledgeFromTui -ActionId $(if ($ActionId) { $ActionId } else { '*' })) }
            'E'     { if ($e) { [void](Edit-VmmKnowledgeFromTui -EntryId $e.Id) } }
            'D'     { if ($e -and $e.BuiltinItem) { $status = 'Built-in known fixes cannot be deleted' }
                      elseif ($e) { [void](Invoke-VmmTuiAction -Title 'Delete known fix' -Action {
                          Write-VmmLog $e.Symptom -Level Info
                          if ((Read-VmmPrompt 'Type DELETE to delete it') -cne 'DELETE') { Write-VmmLog 'Cancelled.' -Level Muted; return }
                          $ws = $cat.Store; $ws.Kb = @($ws.Kb | Where-Object Id -ne $e.Id); Save-VmmWorkflowStore -Store $ws; Write-VmmLog 'Deleted.' -Level Success }) } }
        }
    }
}
