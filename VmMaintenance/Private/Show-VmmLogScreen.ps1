function Show-VmmLogScreen {
    # Full log (F3 on any screen, L in the main menu): today's file, newest at the bottom.
    # R refresh | D another day | F filter | E export plaintext copy | Esc back.
    [CmdletBinding()]
    param()
    if ($script:VmmInLogScreen) { return }
    $script:VmmInLogScreen = $true
    try {
        $date = (Get-Date).Date; $filter = ''; $status = ''; $sel = -1
        while ($true) {
            $all = @(Get-VmmLog -Date $date -Tail 3000 -PassThru -Quiet)
            if ($filter) { $all = @($all | Where-Object { $_.Text -like "*$filter*" -or $_.Level -eq $filter }) }
            $rows = foreach ($e in $all) {
                $c = switch ($e.Level) { 'Info' { 'Cyan' } 'Success' { 'Green' } 'Warn' { 'Yellow' } 'Error' { 'Red' } 'Muted' { 'DarkGray' } 'Trace' { 'DarkCyan' } 'Output' { 'DarkGray' } default { 'Gray' } }
                $t = if ($e.At) { $e.At.ToString('HH:mm:ss') } else { '--:--:--' }
                @{ Text = ('{0} {1,-7} {2}' -f $t, $e.Level, $e.Text); Color = $c }
            }
            if ($sel -lt 0 -or $sel -ge $all.Count) { $sel = [math]::Max(0, $all.Count - 1) }
            $f = if ($filter) { ", filter '$filter'" } else { '' }
            $r = Invoke-VmmListView -Title ("Log {0:yyyy-MM-dd}: {1} line(s){2}" -f $date, $all.Count, $f) -Rows @($rows) -Selected $sel -Status $status `
                 -Hotkeys @('R', 'D', 'F', 'E') -Help 'R refresh | D day | F filter (text or Warn/Error) | E export plaintext | Esc back'
            $sel = $r.Index; $status = ''
            switch ($r.Action) {
                'Esc' { return }
                'R'   { $sel = -1 }
                'D'   { $d = Read-VmmPrompt 'Day (yyyy-MM-dd, empty = today)'; try { $date = if ($d) { [datetime]::ParseExact($d.Trim(), 'yyyy-MM-dd', $null) } else { (Get-Date).Date } } catch { $status = 'Use yyyy-MM-dd' }; $sel = -1; Clear-Host }
                'F'   { $filter = "$(Read-VmmPrompt 'Filter (text, or Warn / Error / Trace; empty = all)')".Trim(); $sel = -1; Clear-Host }
                'E'   { [void](Invoke-VmmTuiAction -Title 'Export log' -Action { Get-VmmLog -Date $date -Export }) }
            }
        }
    } finally { $script:VmmInLogScreen = $false }
}
