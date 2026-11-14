function Show-VmmMainMenu {
    # Top-level menu of the terminal UI. Number/letter keys, arrows + Enter, or mouse.
    [CmdletBinding()]
    param()
    $items = @(
        @{ K = '1'; T = 'Plan today        what is allowed right now and the next host for each step' }
        @{ K = '2'; T = 'Fleet             all hosts: health, stage, OS, SQL, C: free - open a host' }
        @{ K = '3'; T = 'Check fleet now   parallel read-only check of every host (allowed any time)' }
        @{ K = '4'; T = 'Staging gate      OS images + host files on the media repository?' }
        @{ K = '5'; T = 'Azure             sign in / pick tenant + subscription (no stuck picker)' }
        @{ K = '6'; T = 'Credentials       set or clear this session''s Windows / SQL credentials' }
        @{ K = '7'; T = 'Reports           daily CSV + HTML for your manager, blocker reports' }
        @{ K = '8'; T = 'Snapshots, prune  preview and delete expired snapshots' }
        @{ K = '9'; T = 'Settings          share, targets, hours, snapshot policy, upgrade command...' }
        @{ K = '0'; T = 'Import hosts      new machines: CSV (hostname/FQDN, domain, IP), .txt list or names' }
        @{ K = 'E'; T = 'Extractor         import result files (VMM_*.vmm) from Desktop/Downloads; build the extractor' }
        @{ K = 'N'; T = 'Inventory         24 columns per host: what is missing, export CSV (I on a host to fill)' }
        @{ K = 'V'; T = 'VPN               status, connect, disconnect (you sign in in the VPN client)' }
        @{ K = 'A'; T = 'Assistant         optional AI help: explain an error, next step (off by default)' }
        @{ K = 'W'; T = 'Setup wizard      all options page by page, with explanations' }
        @{ K = 'U'; T = 'GitHub / updates  update vmm, sign in, report an issue, pull request' }
        @{ K = 'L'; T = 'Log               everything vmm did today, live (F2 shows/hides the log pane on any screen)' }
        @{ K = 'M'; T = 'Maintenance       diagnose vmm, check/back up/restore the fleet store, clean logs and temp files' }
        @{ K = 'H'; T = 'Help              keys, rules, where files live' }
        @{ K = 'Q'; T = 'Quit              clears session credentials from memory' }
    )
    $sel = 0; $status = (@("$script:VmmInboxNotice", "$script:VmmUpdateNotice") | Where-Object { $_ }) -join ' | '
    while ($true) {
        $rows = @($items | ForEach-Object { @{ Text = "[$($_.K)] $($_.T)"; Color = 'Gray' } })
        $r = Invoke-VmmListView -Title 'Main menu' -Rows $rows -Selected $sel -Status $status `
             -Help 'Number/letter or Up/Down + Enter or click | Esc/Q quit' -Hotkeys @($items | ForEach-Object { $_.K })
        $sel = $r.Index
        $key = if ($r.Action -eq 'Enter') { $items[$r.Index].K } elseif ($r.Action -eq 'Esc') { 'Q' } else { $r.Action }
        $status = ''
        switch ($key) {
            '1' { Show-VmmPlanScreen }
            '2' { Show-VmmFleetScreen }
            '3' { [void](Invoke-VmmTuiAction -Title 'Fleet check (read-only)' -Action { Invoke-VmmFleetCheck -Azure:([bool](Get-VmmSetting 'Azure.TenantId')) }) }
            '4' { Show-VmmStagingScreen }
            '5' { Show-VmmAzureScreen }
            '6' { Show-VmmCredentialScreen }
            '7' { Show-VmmReportsScreen }
            '8' { Show-VmmPruneScreen }
            '9' { Show-VmmSettingsScreen }
            '0' { [void](Invoke-VmmTuiAction -Title 'Import hosts (new machines from external data)' -Action {
                      Write-VmmLog 'CSV with 3 columns: hostname or FQDN, domain, IP (separator , or ;, header optional). Or a .txt with one name per line.' -Level Muted
                      $p = Read-VmmPrompt 'File path (drag the file here), names separated by commas, or Enter to browse'
                      if (-not $p) {
                          try {
                              Add-Type -AssemblyName System.Windows.Forms
                              $dlg = New-Object System.Windows.Forms.OpenFileDialog
                              $dlg.Filter = 'Host lists (*.csv;*.txt)|*.csv;*.txt|All files (*.*)|*.*'; $dlg.Title = 'vmm - host list to import'
                              if ($dlg.ShowDialog() -eq 'OK') { $p = $dlg.FileName }
                          } catch { Write-VmmLog 'File dialog not available here: type or drag the path instead.' -Level Warn }
                      }
                      if (-not $p) { return }
                      $p = $p.Trim().Trim('"')
                      if (Test-Path -LiteralPath $p -PathType Leaf) {
                          Import-VmmFleet -Path $p -Preview
                          if ((Read-VmmPrompt 'Import these? (y/N)') -notmatch '^[yY]') { Write-VmmLog 'Nothing imported.' -Level Muted; return }
                          $rm = (Read-VmmPrompt 'Delete the plaintext file afterwards, so the hosts live only in the encrypted store? (y/N)') -match '^[yY]'
                          Import-VmmFleet -Path $p -RemoveSource:$rm
                      } else { Import-VmmFleet -Name ($p -split '[,; ]+' | Where-Object { $_ }) }
                  }) }
            'V' { [void](Invoke-VmmTuiAction -Title 'VPN' -Action {
                      $s = Get-VmmVpnStatus; $s | Format-List | Out-Host
                      if ($s.State -eq 'NotConfigured') { Write-VmmLog 'Configure it in the setup wizard (W), VPN page.' -Level Info; return }
                      $a = Read-VmmPrompt 'C = connect, D = disconnect, Enter = back'
                      if ($a -match '^[cC]') { Connect-VmmVpn | Out-Null } elseif ($a -match '^[dD]') { Disconnect-VmmVpn -Confirm:$false }
                  }) }
            'A' { [void](Invoke-VmmTuiAction -Title 'Assistant (advisory)' -Action {
                      $q = Read-VmmPrompt 'Question (paste an error, or ask what to do next)'
                      if ($q) { $f = (Read-VmmPrompt 'Include a sanitized fleet summary? (y/N)') -match '^[yY]'; Invoke-VmmAssistant -Prompt $q -IncludeFleet:$f }
                  }) }
            'W' { [void](Invoke-VmmTuiAction -Title 'Setup wizard' -Action { Start-VmmSetupWizard }) }
            'U' { Show-VmmGitHubScreen }
            'E' { [void](Invoke-VmmTuiAction -Title 'Extractor (program for the remote hosts)' -Action {
                      Import-VmmResultInbox
                      Write-VmmLog 'B = build the extractor for every host (one file), a host name = extractor with that host''s plan, Enter = back' -Level Info
                      $a = Read-VmmPrompt 'Choice'
                      if ($a -match '^[bB]$') { Export-VmmHostAgent -Generic | Out-Null } elseif ($a) { Export-VmmHostAgent -HostName $a | Out-Null }
                  }) }
            'N' { [void](Invoke-VmmTuiAction -Title 'Inventory' -Action {
                      Get-VmmInventory
                      $a = Read-VmmPrompt 'E = export CSV, M = missing only, a host name = its columns, Enter = back'
                      if ($a -match '^[eE]$') { Get-VmmInventory -Export } elseif ($a -match '^[mM]$') { Get-VmmInventory -Missing } elseif ($a) { Get-VmmInventory -HostName $a }
                  }) }
            'L' { Show-VmmLogScreen; Clear-Host }
            'M' { Show-VmmMaintenanceScreen }
            'H' { Show-VmmHelpScreen }
            'Q' { return }
        }
    }
}
