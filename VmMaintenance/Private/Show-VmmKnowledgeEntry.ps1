function Show-VmmKnowledgeEntry {
    # One known fix as a dialogue: what happened, why, the fix steps (Enter ticks), commands (C copies).
    # -Ask: the step just failed - Y = it fixed it, N = it did not help (both counted, so the best fix comes
    # first next time). Returns 'Fixed', 'NotFixed' or $null (Esc).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EntryId, [switch]$Ask)
    $sel = 0; $status = ''; $done = @{}
    while ($true) {
        $cat = Get-VmmWorkflowCatalog
        $e = $cat.Kb | Where-Object Id -eq $EntryId | Select-Object -First 1
        if (-not $e) { return $null }
        $rows = @(); $cmds = @()
        $rows += @{ Text = 'WHAT HAPPENED'; Header = $true }; $cmds += $null
        $rows += @{ Text = "$($e.Symptom)" }; $cmds += $null
        if ($e.Cause) { $rows += @{ Text = 'WHY'; Header = $true }; $cmds += $null; $rows += @{ Text = "$($e.Cause)" }; $cmds += $null }
        $rows += @{ Text = 'FIX (Enter ticks a step)'; Header = $true }; $cmds += $null
        $n = 0; foreach ($f in $e.Fix) { $rows += @{ Text = "$(if ($done[$n]) { '[x]' } else { '[ ]' }) $($n + 1). $f"; Color = $(if ($done[$n]) { 'DarkGray' } else { 'Gray' }); Tick = $n }; $cmds += $null; $n++ }
        if ($e.Commands) { $rows += @{ Text = 'COMMANDS (C copies)'; Header = $true }; $cmds += $null; foreach ($c in $e.Commands) { $rows += @{ Text = ">> $c" }; $cmds += , $c } }
        $rows += @{ Text = "Helped $([int]$e.Helped) time(s), did not help $([int]$e.NotHelped) time(s)"; Header = $true }; $cmds += $null
        $help = if ($Ask) { 'Enter tick | C copy | Y it fixed it | N did not help | Esc back' } else { 'Enter tick | C copy | Esc back' }
        $r = Invoke-VmmListView -Title 'Suggested resolution (known fix)' -Rows $rows -Selected $sel -Status $status -Hotkeys @('C', 'Y', 'N') -Help $help
        $sel = $r.Index; $status = ''
        switch ($r.Action) {
            'Esc'   { return $null }
            'Enter' { $tk = $rows[$r.Index].Tick; if ($null -ne $tk) { $done[$tk] = -not $done[$tk]; if ($done[$tk]) { $sel++ } } }
            'C'     { $c = $cmds[$r.Index]; if (-not $c -and $e.Commands) { $c = $e.Commands -join "`r`n" }; if ($c) { try { $c | Set-Clipboard; $status = 'Copied - paste it in the RDP session' } catch { $status = "Clipboard failed: $($_.Exception.Message)" } } else { $status = 'No command in this fix' } }
            { $_ -in 'Y', 'N' } {
                if (-not $Ask) { continue }
                if (-not $e.BuiltinItem) {
                    $ws = $cat.Store; $o = $ws.Kb | Where-Object Id -eq $e.Id | Select-Object -First 1
                    if ($r.Action -eq 'Y') { $o.Helped = [int]$o.Helped + 1 } else { $o.NotHelped = [int]$o.NotHelped + 1 }
                    Save-VmmWorkflowStore -Store $ws
                }
                if ($r.Action -eq 'Y') { return 'Fixed' } else { return 'NotFixed' }
            }
        }
    }
}
