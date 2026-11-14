function Show-VmmMaintenanceScreen {
    # Maintenance tools for vmm itself (M in the main menu). Nothing here touches hosts or Azure.
    [CmdletBinding()]
    param()
    $items = @(
        @{ K = 'D'; T = 'Diagnose          versions, settings, data key, fleet store, backups, logs, tools, disk' }
        @{ K = 'L'; T = 'Log               full log of today (also F3 on any screen); D = another day' }
        @{ K = 'F'; T = 'Follow log        live log in this window (Esc stops) - or run "vmm log -Follow" in a 2nd window' }
        @{ K = 'X'; T = 'Export log        plaintext copy of a day for a ticket (delete it after use)' }
        @{ K = 'S'; T = 'Check store       decrypt the fleet store and its .bak, look for damaged/duplicate records' }
        @{ K = 'B'; T = 'Backup now        encrypted copy of the fleet store (vmm also makes one a day)' }
        @{ K = 'R'; T = 'Restore           put a backup back (current store kept as .before-restore)' }
        @{ K = 'C'; T = 'Clean logs        delete day logs older than Log.KeepDays' }
        @{ K = 'T'; T = 'Clean temp files  old generated extractors, plaintext log exports, half-written files' }
        @{ K = 'O'; T = 'Log options       live log on/off, pane size, encryption, days kept' }
        @{ K = 'Z'; T = 'Reset UI          clear caches and the on-screen log (files kept)' }
    )
    $sel = 0; $status = ''
    while ($true) {
        $rows = @($items | ForEach-Object { @{ Text = "[$($_.K)] $($_.T)"; Color = 'Gray' } })
        $r = Invoke-VmmListView -Title 'Maintenance (vmm itself - hosts and Azure are not touched)' -Rows $rows -Selected $sel -Status $status `
             -Help 'Letter or Up/Down + Enter | Esc back' -Hotkeys @($items | ForEach-Object { $_.K })
        $sel = $r.Index; $status = ''
        $key = if ($r.Action -eq 'Enter') { $items[$r.Index].K } elseif ($r.Action -eq 'Esc') { 'ESC' } else { $r.Action }
        switch ($key) {
            'ESC' { return }
            'D' { [void](Invoke-VmmTuiAction -Title 'Diagnose' -Action { Invoke-VmmMaintenance -Action Diagnose }) }
            'L' { Show-VmmLogScreen; Clear-Host }
            'F' { [void](Invoke-VmmTuiAction -Title 'Follow log (Esc or Q stops)' -Action { Get-VmmLog -Tail 30 -Follow }) }
            'X' { [void](Invoke-VmmTuiAction -Title 'Export log (plaintext)' -Action {
                      $d = Read-VmmPrompt 'Day (yyyy-MM-dd, empty = today)'
                      $day = if ($d) { [datetime]::ParseExact($d.Trim(), 'yyyy-MM-dd', $null) } else { (Get-Date).Date }
                      Get-VmmLog -Date $day -Export
                  }) }
            'S' { [void](Invoke-VmmTuiAction -Title 'Check fleet store' -Action { Invoke-VmmMaintenance -Action CheckStore }) }
            'B' { [void](Invoke-VmmTuiAction -Title 'Backup' -Action { Invoke-VmmMaintenance -Action Backup -Confirm:$false }) }
            'R' { [void](Invoke-VmmTuiAction -Title 'Restore a backup' -Action {
                      Invoke-VmmMaintenance -Action ListBackups
                      $f = Read-VmmPrompt 'Backup file name to restore (empty = cancel)'
                      if (-not $f) { return }
                      Write-VmmLog 'The current store is replaced (kept as fleet.vmm.before-restore). Changes since that backup are lost.' -Level Warn
                      if ((Read-VmmPrompt 'Type RESTORE to continue') -ceq 'RESTORE') { Invoke-VmmMaintenance -Action Restore -BackupFile $f.Trim() -Confirm:$false }
                      else { Write-VmmLog 'Nothing changed.' -Level Muted }
                  }) }
            'C' { [void](Invoke-VmmTuiAction -Title 'Clean logs' -Action {
                      $a = (Read-VmmPrompt "Delete logs older than $(Get-VmmSetting 'Log.KeepDays' -Default 30) days (Enter), A = every day except today, N = cancel")
                      if ($a -match '^[nN]') { return }
                      Invoke-VmmMaintenance -Action CleanLogs -All:($a -match '^[aA]') -Confirm:$false
                  }) }
            'T' { [void](Invoke-VmmTuiAction -Title 'Clean temp files' -Action { Invoke-VmmMaintenance -Action CleanTemp -Confirm:$false }) }
            'O' { [void](Invoke-VmmTuiAction -Title 'Log options' -Action {
                      $opts = @(
                          @('Log.Live', 'Live log pane + progress lines (F2 toggles on any screen)', $true)
                          @('Log.PaneLines', 'Rows of the log pane (2-20)', 6)
                          @('Log.HeartbeatSeconds', 'Seconds between "still running" lines', 5)
                          @('Log.ToFile', 'Write the day log file', $true)
                          @('Log.Encrypt', 'Encrypt log lines on disk (host names are in them)', $true)
                          @('Log.KeepDays', 'Days of logs kept', 30)
                          @('Maintenance.AutoBackup', 'Back up the fleet store once a day at start', $true)
                          @('Maintenance.KeepBackups', 'Backups kept', 14)
                      )
                      foreach ($o in $opts) { Write-VmmLog ('{0,-24} {1,-6} {2}' -f $o[0], (Get-VmmSetting $o[0] -Default $o[2]), $o[1]) }
                      $n = Read-VmmPrompt 'Setting to change (empty = back)'
                      if (-not $n) { return }
                      $v = Read-VmmPrompt "New value for $n"
                      if ("$v" -ne '') { Set-VmmSetting -Name $n.Trim() -Value $v; if ($n -match 'Log\.Live') { $script:VmmLogLive = $null } }
                  }) }
            'Z' { [void](Invoke-VmmTuiAction -Title 'Reset UI' -Action { Invoke-VmmMaintenance -Action ResetUi }) }
        }
    }
}
