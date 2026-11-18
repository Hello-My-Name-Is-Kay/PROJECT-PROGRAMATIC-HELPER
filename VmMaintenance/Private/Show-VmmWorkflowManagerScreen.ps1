function Show-VmmWorkflowManagerScreen {
    # Workflow manager (main menu K): workflows (create, copy, rename, delete, set the DEFAULT), the action
    # library, the known fixes, and the shared library (export/import). Built-ins are read-only: copy them.
    [CmdletBinding()]
    param()
    $sel = 1; $status = ''
    while ($true) {
        $cat = Get-VmmWorkflowCatalog
        $fleet = try { Read-VmmStore } catch { $null }
        $use = @{}
        if ($fleet) { foreach ($h in $fleet.Hosts) { $t = Initialize-VmmTicket -Record $h; $id = if ($t.Workflow) { $t.Workflow } else { $cat.Default }; $use[$id] = 1 + [int]$use[$id] } }
        $rows = @(@{ Text = 'WORKFLOWS (Enter = steps, N new, C copy, E rename, D delete, S make default)'; Header = $true }); $map = @($null)
        foreach ($wf in $cat.Workflows) {
            $cats = @($wf.Steps | ForEach-Object { $id = $_; ($cat.Actions | Where-Object Id -eq $id | Select-Object -First 1).Category } | Where-Object { $_ } | Select-Object -Unique)
            $kind = if ($cats -contains 'Change') { 'changes hosts' } elseif ($cats -contains 'Staging') { 'read-only + staging' } else { 'read-only' }
            $tags = @(); if ($wf.Id -eq $cat.Default) { $tags += 'DEFAULT' }; if ($wf.BuiltinItem) { $tags += 'built-in' }
            $rows += @{ Text = ('{0,-30} {1,2} steps  {2,-20} {3,4} host(s)  {4}' -f $wf.Name, @($wf.Steps).Count, $kind, [int]$use[$wf.Id], ($tags -join ', ')); Color = $(if ($wf.Id -eq $cat.Default) { 'Green' } else { 'Gray' }) }
            $map += , @{ Kind = 'wf'; Item = $wf }
        }
        $lib = Get-VmmSetting 'Workflow.LibraryPath' -Default ''
        $rows += @{ Text = 'LIBRARY'; Header = $true }; $map += $null
        $rows += @{ Text = ('Action library      {0} action(s): {1} read-only, {2} staging, {3} change' -f $cat.Actions.Count, @($cat.Actions | Where-Object Category -eq 'ReadOnly').Count, @($cat.Actions | Where-Object Category -eq 'Staging').Count, @($cat.Actions | Where-Object Category -eq 'Change').Count) }; $map += , @{ Kind = 'actions' }
        $rows += @{ Text = ('Known fixes         {0} entr(ies) - what failed and how it was fixed, shown when a step fails' -f $cat.Kb.Count) }; $map += , @{ Kind = 'kb' }
        $rows += @{ Text = ('Shared library      X export / I import: {0}' -f $(if ($lib) { $lib } else { 'path asked (set Workflow.LibraryPath)' })) }; $map += , @{ Kind = 'share' }
        $r = Invoke-VmmListView -Title 'Workflow manager' -Rows $rows -Selected $sel -Status $status -Hotkeys @('N', 'C', 'E', 'D', 'S', 'A', 'K', 'X', 'I') `
             -Help 'Enter open | N new | C copy | E rename | D delete | S default | A actions | K known fixes | X export | I import | Esc'
        $sel = $r.Index; $status = ''
        $m = $map[$r.Index]
        $wf = if ($m -and $m.Kind -eq 'wf') { $m.Item } else { $null }
        switch ($r.Action) {
            'Esc'   { return }
            'Enter' {
                if ($wf) { Show-VmmWorkflowEditScreen -WorkflowId $wf.Id }
                elseif ($m.Kind -eq 'actions') { Show-VmmActionLibraryScreen }
                elseif ($m.Kind -eq 'kb') { Show-VmmKnowledgeScreen }
                elseif ($m.Kind -eq 'share') { $status = 'X exports your workflows/actions/known fixes, I imports the shared file' }
            }
            'A' { Show-VmmActionLibraryScreen }
            'K' { Show-VmmKnowledgeScreen }
            'N' { [void](Invoke-VmmTuiAction -Title 'New workflow' -Action {
                      $n = Read-VmmField -Prompt 'Name' -Required
                      if ($cat.Workflows | Where-Object Name -eq $n) { throw (New-VmmErrorRecord -Activity "A workflow named '$n' exists." -Fix 'Pick another name.' -Category ResourceExists -ErrorId 'VmmWorkflowExists') }
                      $d = Read-VmmField -Prompt 'Description (one line)'
                      $at = (Get-Date).ToUniversalTime().ToString('o')
                      $ws = $cat.Store
                      $new = [pscustomobject]@{ Id = (New-VmmId -Prefix wf); Name = (Protect-VmmLogText $n); Description = (Protect-VmmLogText $d); Steps = @(); Created = $at; Updated = $at }
                      $ws.Workflows = @($ws.Workflows) + $new
                      Save-VmmWorkflowStore -Store $ws
                      Write-VmmLog "Workflow '$n' created. Add its steps: Enter on it, then A." -Level Success }) }
            'C' { if ($wf) { [void](Invoke-VmmTuiAction -Title "Copy workflow '$($wf.Name)'" -Action {
                      $n = Read-VmmField -Prompt 'Name of the copy' -Current "$($wf.Name) (copy)" -Required
                      $at = (Get-Date).ToUniversalTime().ToString('o'); $ws = $cat.Store
                      $ws.Workflows = @($ws.Workflows) + [pscustomobject]@{ Id = (New-VmmId -Prefix wf); Name = (Protect-VmmLogText $n); Description = $wf.Description; Steps = @($wf.Steps); Created = $at; Updated = $at }
                      Save-VmmWorkflowStore -Store $ws
                      Write-VmmLog "Copied to '$n' (editable)." -Level Success }) } }
            'E' { if ($wf -and $wf.BuiltinItem) { $status = 'Built-in workflows cannot be renamed: C makes an editable copy' }
                  elseif ($wf) { [void](Invoke-VmmTuiAction -Title "Rename workflow '$($wf.Name)'" -Action {
                      $ws = $cat.Store; $o = $ws.Workflows | Where-Object Id -eq $wf.Id
                      $o.Name = Protect-VmmLogText (Read-VmmField -Prompt 'Name' -Current $o.Name -Required)
                      $o.Description = Protect-VmmLogText (Read-VmmField -Prompt 'Description' -Current $o.Description)
                      $o.Updated = (Get-Date).ToUniversalTime().ToString('o')
                      Save-VmmWorkflowStore -Store $ws; Write-VmmLog 'Saved.' -Level Success }) } }
            'D' { if ($wf -and $wf.BuiltinItem) { $status = 'Built-in workflows cannot be deleted' }
                  elseif ($wf) { [void](Invoke-VmmTuiAction -Title "Delete workflow '$($wf.Name)'" -Action {
                      $n = [int]$use[$wf.Id]
                      Write-VmmLog "$n host(s) follow this workflow; they go back to the DEFAULT workflow. Recorded step results stay on the hosts." -Level Warn
                      if ((Read-VmmPrompt "Type DELETE to delete '$($wf.Name)'") -cne 'DELETE') { Write-VmmLog 'Cancelled - nothing deleted.' -Level Muted; return }
                      $ws = $cat.Store
                      $ws.Workflows = @($ws.Workflows | Where-Object Id -ne $wf.Id)
                      if ($ws.Default -eq $wf.Id) { $ws.Default = 'wf-default'; Write-VmmLog 'It was the default: the default is Full maintenance again.' -Level Warn }
                      Save-VmmWorkflowStore -Store $ws
                      if ($n) {
                          $fs = Read-VmmStore
                          foreach ($h in $fs.Hosts) { $t = Initialize-VmmTicket -Record $h; if ($t.Workflow -eq $wf.Id) { $t.Workflow = $null; $t.Steps = $null } }
                          Save-VmmStore -Store $fs
                      }
                      Write-VmmLog "Deleted '$($wf.Name)'." -Level Success }) } }
            'S' { if ($wf) { $ws = $cat.Store; $ws.Default = $wf.Id; Save-VmmWorkflowStore -Store $ws; $status = "DEFAULT workflow is now '$($wf.Name)': every ticket without its own choice follows it" } }
            'X' { [void](Invoke-VmmTuiAction -Title 'Export the shared library' -Action {
                      $p = Read-VmmField -Prompt 'Library file' -Current $(if ($lib) { $lib } else { Join-Path ([Environment]::GetFolderPath('Desktop')) 'vmm-library.json' })
                      Export-VmmWorkflowLibrary -Path $p | Out-Null }) }
            'I' { [void](Invoke-VmmTuiAction -Title 'Import the shared library' -Action {
                      $p = Read-VmmField -Prompt 'Library file' -Current $lib -Required
                      Import-VmmWorkflowLibrary -Path $p | Out-Null }) }
        }
    }
}
