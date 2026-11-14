function Show-VmmGuideScreen {
    # RDP/RDM checklist for one step. Enter ticks the selected item, C copies its command to the
    # clipboard, L starts mstsc, Y confirms the step done, F raises a blocker report and moves on.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][string]$Step)
    $items = @(Get-VmmRdpGuide -HostName $HostName -Step $Step)
    $done = @{}; $sel = 0; $status = ''
    while ($true) {
        $rows = for ($i = 0; $i -lt $items.Count; $i++) {
            $mark = if ($done[$i]) { '[x]' } else { '[ ]' }
            $cmd = if ($items[$i].Command) { '   >> ' + (($items[$i].Command -split "`n")[0]) + $(if ($items[$i].Command -match "`n") { ' ...(C copies all)' }) } else { '' }
            @{ Text = "$mark $($i + 1). $($items[$i].Text)$cmd"; Color = $(if ($done[$i]) { 'DarkGray' } else { 'Gray' }) }
        }
        $r = Invoke-VmmListView -Title "RDP guide: $HostName / $Step" -Rows @($rows) -Selected $sel -Status $status -Hotkeys @('C', 'L', 'Y', 'F', 'P') `
             -Help 'Enter tick | C copy command | L mstsc | P paste collector | Y step done | F failed: blocker + move on | Esc'
        $sel = $r.Index; $status = ''
        switch ($r.Action) {
            'Esc'   { return }
            'Enter' { $done[$r.Index] = -not $done[$r.Index]; if ($done[$r.Index]) { $sel++ } }
            'C'     { $c = $items[$r.Index].Command; if ($c) { try { $c | Set-Clipboard; $status = 'Command copied - paste it in the RDP session (Ctrl+V / right-click)' } catch { $status = "Clipboard failed: $($_.Exception.Message)" } } else { $status = 'No command on this line' } }
            'L'     { Start-Process mstsc.exe -ArgumentList "/v:$HostName"; $status = 'mstsc started (or use RDM)' }
            'P'     { [void](Invoke-VmmTuiAction -Title 'Paste collector result' -Action {
                          $clip = try { (Get-Clipboard) -join '' } catch { '' }
                          if ($clip -notmatch '^VMM1\|') { $clip = Read-VmmPrompt 'Paste the VMM1|... line' }
                          Import-VmmCollectorResult -Line $clip -Step $(if ($Step -eq 'Verify') { 'Verify' } else { 'Precheck' }) }); return }
            'Y'     { if ($Step -in 'Precheck', 'Verify') { $status = 'For checks, paste the collector result with P instead' }
                      else { [void](Invoke-VmmTuiAction -Title "Confirm $Step" -Action { Invoke-VmmStepFromTui -HostName $HostName -Step $Step -Confirmed }); return } }
            'F'     { [void](Invoke-VmmTuiAction -Title "Blocker report - $HostName / $Step" -Action {
                          $m = Read-VmmPrompt 'Exact error or what blocked you (paste it)'
                          if ($m) { New-VmmBlockerReport -HostName $HostName -Step $Step -Message $m | Out-Null } }); return }
        }
    }
}
