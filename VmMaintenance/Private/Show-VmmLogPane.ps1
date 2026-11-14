function Show-VmmLogPane {
    # Live log pane at the bottom of a list screen: a title row, then the newest -Lines entries.
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Top, [int]$Lines = 6)
    $w = [Console]::WindowWidth - 1
    $title = ' Live log  (F2 hide | F3 full log) '
    Write-VmmTuiLine -Row $Top -Text ($title + ('-' * [math]::Max(0, $w - $title.Length))) -Fg DarkGray
    $items = @()
    if ($script:VmmLogBuffer) { $items = @($script:VmmLogBuffer | Where-Object { $_.Level -ne 'Output' } | Select-Object -Last $Lines) }
    for ($i = 0; $i -lt $Lines; $i++) {
        if ($i -lt $items.Count) {
            $e = $items[$i]
            $fg = switch ($e.Level) { 'Info' { 'Cyan' } 'Success' { 'Green' } 'Warn' { 'Yellow' } 'Error' { 'Red' } 'Muted' { 'DarkGray' } 'Trace' { 'DarkCyan' } default { 'Gray' } }
            $tag = switch ($e.Level) { 'Warn' { 'WARNING: ' } 'Error' { 'ERROR: ' } default { '' } }
            Write-VmmTuiLine -Row ($Top + 1 + $i) -Text (' ' + $e.At.ToString('HH:mm:ss') + ' ' + $tag + $e.Text) -Fg $fg
        } else { Write-VmmTuiLine -Row ($Top + 1 + $i) -Text '' }
    }
}
