function Show-VmmReportsScreen {
    # Daily export and blocker reports. Sending is done by you in Outlook.
    [CmdletBinding()]
    param()
    $sel = 0
    while ($true) {
        $items = @(
            @{ K = 'E'; T = 'Export daily report now (CSV + HTML + JSON) and open the HTML' }
            @{ K = 'F'; T = 'Open the reports folder' }
            @{ K = 'B'; T = 'Open blocker reports (send them from Outlook)' }
            @{ K = 'P'; T = 'Show progress against today''s target' }
            @{ K = 'U'; T = 'Upgrade path report: next SQL/Windows step per host, file + language (TXT + CSV for the e-mail)' }
        )
        $r = Invoke-VmmListView -Title 'Reports (plaintext by design: host names, never credentials)' -Rows @($items | ForEach-Object { @{ Text = "[$($_.K)] $($_.T)" } }) `
             -Selected $sel -Hotkeys @('E', 'F', 'B', 'P', 'U') -Help 'Letter or Enter | Esc back'
        $sel = $r.Index
        $k = if ($r.Action -eq 'Enter') { $items[$r.Index].K } else { $r.Action }
        switch ($k) {
            'Esc' { return }
            'E' { [void](Invoke-VmmTuiAction -Title 'Daily report' -Action { Export-VmmDailyReport -Open | Format-List }) }
            'F' { Start-Process explorer.exe -ArgumentList (Get-VmmPath -Name Reports) }
            'B' { Start-Process explorer.exe -ArgumentList (Get-VmmPath -Name Blockers) }
            'P' { [void](Invoke-VmmTuiAction -Title 'Progress' -Action { Get-VmmDailyProgress | Format-List }) }
            'U' { [void](Invoke-VmmTuiAction -Title 'Upgrade path report' -Action { Export-VmmUpgradePathReport -Open -Clipboard | Format-List }) }
        }
    }
}
