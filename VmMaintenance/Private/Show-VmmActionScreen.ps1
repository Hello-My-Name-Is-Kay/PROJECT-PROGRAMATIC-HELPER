function Show-VmmActionScreen {
    # One action, read-only view: what it does, the instructions, the commands (C copies the selected one), what
    # success looks like, and how many known fixes exist (K). E edits it (a copy for built-ins).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ActionId)
    $sel = 0; $status = ''
    while ($true) {
        $cat = Get-VmmWorkflowCatalog
        $a = $cat.Actions | Where-Object Id -eq $ActionId | Select-Object -First 1
        if (-not $a) { return }
        $rows = @(); $cmds = @()
        $rows += @{ Text = "$($a.Category) | $($a.Mode) | group $($a.Group)$(if ($a.RunOnHost) { ' | runbook may run it on the host' })$(if ($a.BuiltinItem) { ' | built-in' })"; Header = $true }; $cmds += $null
        $rows += @{ Text = 'INSTRUCTIONS'; Header = $true }; $cmds += $null
        $n = 0; foreach ($s in $a.Steps) { $n++; $rows += @{ Text = "$n. $s" }; $cmds += $null }
        if ($a.Commands) { $rows += @{ Text = 'COMMANDS (C copies the selected one)'; Header = $true }; $cmds += $null; foreach ($c in $a.Commands) { $rows += @{ Text = ">> $c" }; $cmds += , $c } }
        $rows += @{ Text = 'SUCCESS LOOKS LIKE'; Header = $true }; $cmds += $null
        $rows += @{ Text = "$($a.Expect)" }; $cmds += $null
        $rows += @{ Text = "KNOWN FIXES: $(@($cat.Kb | Where-Object { $_.ActionId -eq $a.Id -or $_.ActionId -eq '*' }).Count) (K)"; Header = $true }; $cmds += $null
        $r = Invoke-VmmListView -Title "Action: $($a.Name) - $($a.Title)" -Rows $rows -Selected $sel -Status $status -Hotkeys @('C', 'E', 'K') -Help 'C copy command | E edit | K known fixes | Esc'
        $sel = $r.Index; $status = ''
        switch ($r.Action) {
            'Esc' { return }
            'C'   { $c = $cmds[$r.Index]; if (-not $c -and $a.Commands) { $c = $a.Commands -join "`r`n" }; if ($c) { try { $c | Set-Clipboard; $status = 'Copied - paste it in the RDP session' } catch { $status = "Clipboard failed: $($_.Exception.Message)" } } else { $status = 'No command' } }
            'E'   { if ($a.Builtin) { $status = 'A maintenance step: not editable' } else { [void](Edit-VmmActionFromTui -ActionId $a.Id) } }
            'K'   { Show-VmmKnowledgeScreen -ActionId $a.Id }
        }
    }
}
