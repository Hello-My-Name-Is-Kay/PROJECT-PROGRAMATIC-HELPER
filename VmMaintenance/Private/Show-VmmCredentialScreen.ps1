function Show-VmmCredentialScreen {
    # Session credentials: set, replace or clear. Nothing here is ever written to disk.
    [CmdletBinding()]
    param()
    $sel = 0
    while ($true) {
        $items = @(
            @{ K = 'W'; T = 'Set Windows admin credential for this session (CIM checks, C$ staging)' }
            @{ K = 'S'; T = 'Set SQL credential for this session (Lansweeper)' }
            @{ K = 'X'; T = 'Clear all session credentials now' }
        )
        $r = Invoke-VmmListView -Title "Credentials - $(Get-VmmCredentialState) (memory only, asked again every session)" `
             -Rows @($items | ForEach-Object { @{ Text = "[$($_.K)] $($_.T)" } }) -Selected $sel -Hotkeys @('W', 'S', 'X') -Help 'Letter or Enter | Esc back'
        $sel = $r.Index
        $k = if ($r.Action -eq 'Enter') { $items[$r.Index].K } else { $r.Action }
        switch ($k) {
            'Esc' { return }
            'W' { [void](Invoke-VmmTuiAction -Title 'Windows credential' -NoPause -Action { [void](Get-VmmSessionCredential -Purpose Windows -Force) }) }
            'S' { [void](Invoke-VmmTuiAction -Title 'SQL credential' -NoPause -Action { [void](Get-VmmSessionCredential -Purpose Sql -Force) }) }
            'X' { Clear-VmmSessionCredentialStore }
        }
        $script:VmmProgCache = $null
    }
}
