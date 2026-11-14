function Show-VmmPruneScreen {
    # Prune is always preview first; deleting needs a second, explicit choice.
    [CmdletBinding()]
    param()
    [void](Invoke-VmmTuiAction -Title 'Prune preview (nothing deleted)' -Action {
        Invoke-VmmPrune
        Write-VmmLog 'IMPORTANT: deleting snapshots cannot be undone.' -Level Warn
        $a = Read-VmmPrompt 'Type DELETE to delete the expired snapshots listed above, anything else to keep them'
        if ($a -ceq 'DELETE') { Invoke-VmmPrune -Apply -Confirm:$false } else { Write-VmmLog 'Kept - nothing deleted.' -Level Muted }
    })
}
