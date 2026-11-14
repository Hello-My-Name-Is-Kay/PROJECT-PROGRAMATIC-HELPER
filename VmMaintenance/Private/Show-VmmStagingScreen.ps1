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
            $txt = if ($p.Gate) { $p.Gate } else { "OK  $($p.Name)  ($($p.SizeMB) MB)$(if ($p.HashOk) { ' SHA256 verified' })" }
            @{ Text = $txt; Color = $(if ($p.Gate) { 'Red' } else { 'Green' }) }
        }
        $open = if ($err) { "Share problem: $err" } elseif (@($pk | Where-Object Gate).Count) { 'GATE CLOSED - put the missing files on the share, then R' } else { "Gate open: $(@($pk).Count) package(s) ready" }
        $r = Invoke-VmmListView -Title "Staging gate - share: $(Get-VmmSetting 'Staging.SourceShare' -Default '(not set)')" -Rows @($rows) -Selected $sel -Status $open `
             -Hotkeys @('R', 'O', 'S') -Help 'R re-check | O open share in Explorer | S set share path | Esc back'
        $sel = $r.Index
        switch ($r.Action) {
            'Esc' { return }
            'R'   { $err = & $load }
            'O'   { $s = Get-VmmSetting 'Staging.SourceShare'; if ($s) { Start-Process explorer.exe -ArgumentList $s } }
            'S'   { $v = Read-VmmPrompt 'Network share path (\\server\share\folder)'; if ($v) { try { Set-VmmSetting -Name Staging.SourceShare -Value $v } catch { } }; $err = & $load; Clear-Host }
        }
    }
}
