function Update-VmmStepName {
    # 2.17.0 migration, in memory (saved with the next Save-VmmStore): PreSnapshot became SnapPreSql, and hosts
    # worked before 2.17.0 have no record of the new snapshot points they already passed. A missing SnapStart
    # (Stage or later recorded) or SnapPostSql (Verify recorded) is marked Skipped with an honest note, so the host
    # does not go back to a point that can no longer be taken at the right moment. ManualCheck and SnapFinal are
    # never filled in: such a host still gets your manual check and the final snapshot.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    $steps = $Record.Steps
    if (-not $steps) { return }
    $old = $steps.PSObject.Properties['PreSnapshot']
    if ($old) {
        if (-not $steps.PSObject.Properties['SnapPreSql']) { $steps | Add-Member -NotePropertyName SnapPreSql -NotePropertyValue $old.Value -Force }
        $steps.PSObject.Properties.Remove('PreSnapshot')
    }
    $order = 'Precheck', 'SnapStart', 'Stage', 'SnapPreSql', 'ExpandDisk', 'Upgrade', 'SnapPostSql', 'Verify', 'ManualCheck', 'SnapFinal'
    foreach ($fill in 'SnapStart', 'SnapPostSql') {
        if ($steps.PSObject.Properties[$fill]) { continue }
        $later = @($order[([array]::IndexOf($order, $fill) + 1)..($order.Count - 1)] | Where-Object { $steps.PSObject.Properties[$_] })
        if (-not $later) { continue }
        $steps | Add-Member -NotePropertyName $fill -NotePropertyValue ([pscustomobject]@{
            Status = 'Skipped'; At = (Get-Date).ToUniversalTime().ToString('o'); Snapshot = $null
            Note = "Not in the workflow when this host passed this point (before 2.17.0): no snapshot was taken here" }) -Force
    }
}
