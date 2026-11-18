function Get-VmmWorkflowCatalog {
    # Built-in + user catalog: Actions, Workflows, Kb (known fixes), Default (workflow id) and the store itself
    # (for saving). User items with the id of a built-in are ignored (built-ins cannot be replaced).
    [CmdletBinding()]
    param($Store)
    if (-not $Store) { $Store = Read-VmmWorkflowStore }
    $b = Get-VmmBuiltinWorkflow
    $bIds = @{}; foreach ($x in @($b.Actions) + @($b.Workflows) + @($b.Kb)) { $bIds[$x.Id] = $true }
    $own = { param($items) @($items | Where-Object { -not $bIds.ContainsKey("$($_.Id)") }) }
    $wf = @($b.Workflows) + (& $own $Store.Workflows)
    $def = if ($wf | Where-Object { $_.Id -eq $Store.Default }) { $Store.Default } else { 'wf-default' }
    [pscustomobject]@{
        Actions   = @($b.Actions) + (& $own $Store.Actions)
        Workflows = $wf
        Kb        = @($b.Kb) + (& $own $Store.Kb)
        Default   = $def
        Store     = $Store
    }
}
