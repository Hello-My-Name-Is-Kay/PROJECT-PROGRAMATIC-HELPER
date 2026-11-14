function Show-VmmStagingScreen {
    # Staging gate: one row per package (present / hash). R re-checks; O opens the share in Explorer.
    [CmdletBinding()]
    param()
    $sel = 0; $status = ''; $rows = @(); $err = $null
    $load = {
        try { $script:VmmStagingRows = @(Test-VmmStagingSource -PassThru -Quiet); $null }
        catch { $script:VmmStagingRows = @(); $_.Exception.Message.Split([Environment]::NewLine)[0] }
    }
    $err = & $load
    while ($true) {
        $pk = $script:VmmStagingRows
        $rows = foreach ($p in $pk) {
            $txt = if ($p.Gate) { $p.Gate } else { "OK  $($p.Kind)  $($p.Name)  ($($p.SizeMB) MB)$(if ($p.HashOk) { ' SHA256 verified' })" }
            if ($p.Hosts) { $txt += "  [hosts: $($p.Hosts)]" }
            if ($p.Note) { $txt += "  NOTE: $($p.Note)" }
            @{ Text = $txt; Color = $(if ($p.Gate) { 'Red' } elseif ($p.Note) { 'Yellow' } else { 'Green' }) }
        }
        $open = if ($err) { "Share problem: $err" } elseif (@($pk | Where-Object Gate).Count) { 'GATE CLOSED - put the missing files on the share, then R' } else { "Gate open: $(@($pk).Count) package(s) ready" }
        $r = Invoke-VmmListView -Title "Staging gate - share: $(Get-VmmSetting 'Staging.SourceShare' -Default '(not set)')" -Rows @($rows) -Selected $sel -Status $open `
             -Hotkeys @('R', 'O', 'S', 'M', 'F') -Help 'R re-check | M media report | F fetch SQL updates | O open share in Explorer | S set share path | Esc back'
        $sel = $r.Index
        switch ($r.Action) {
            'Esc' { return }
            'R'   { $err = & $load }
            'M'   { Clear-Host; try { Get-VmmMediaReport } catch { Write-VmmLog $_.Exception.Message -Level Error }; [void](Read-Host 'Enter to go back'); Clear-Host }
            'F'   { [void](Invoke-VmmTuiAction -Title 'SQL Server updates: download once, copy to host folders' -Action {
                      Save-VmmSqlUpdate -Preview
                      if ((Read-VmmPrompt 'Download what is missing and fill the host folders? (y/N)') -match '^[yY]') { Save-VmmSqlUpdate -Confirm:$false }
                  }); $err = & $load }
            'O'   { $s = Get-VmmSetting 'Staging.SourceShare'; if ($s) { Start-Process explorer.exe -ArgumentList $s } }
            'S'   { $v = Read-VmmPrompt 'Media repository path (\\server\share\project\iso-folder)'; if ($v) { try { Set-VmmSetting -Name Staging.SourceShare -Value $v } catch { } }; $err = & $load; Clear-Host }
        }
    }
}
