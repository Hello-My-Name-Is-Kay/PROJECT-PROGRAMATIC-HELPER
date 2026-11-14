function Invoke-VmmListView {
    # Generic scrollable list screen. Handles arrows, PgUp/PgDn, Home/End, wheel, click (select),
    # click on the selected row or double-click (open). Returns @{ Action; Index } where Action is
    # 'Enter', 'Esc' or one of -Hotkeys (upper-case char). A row is @{ Text; Color } where Color is a status
    # (Green/Yellow/Red or Ok/Warn/Fail: a small coloured block in front of neutral text), DarkGray (muted
    # text) or anything else (plain text). The selected row is the deep iceberg bar.
    # @{ Text; Header = $true } is a section title: muted, and the cursor steps over it.
    # On every screen: F2 shows/hides the live
    # log pane at the bottom (Log.PaneLines rows, refreshed as lines arrive), F3 opens the full log.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$ColumnHeader = '',
        [AllowEmptyCollection()][object[]]$Rows = @(),
        [int]$Selected = 0,
        [string]$Help = 'Up/Down select | Enter open | Esc back',
        [string]$Status = '',
        [string[]]$Hotkeys = @()
    )
    [Console]::CursorVisible = $false
    $listTop = 5
    $offset = 0
    $lastSize = ''
    $dirty = $true
    $lastSeq = -1
    $dir = 1
    $paneLines = 6
    try { $paneLines = [math]::Min(20, [math]::Max(2, [int](Get-VmmSetting 'Log.PaneLines' -Default 6))) } catch { }
    $script:VmmTuiListActive = $true
    try {
    while ($true) {
        $size = "$([Console]::WindowWidth)x$([Console]::WindowHeight)"
        if ($size -ne $lastSize) { Clear-Host; $lastSize = $size; $dirty = $true }
        # Live log pane: shown when on (F2) and the window leaves at least 3 list rows
        $paneTop = [Console]::WindowHeight - 3 - $paneLines
        $pane = (Test-VmmLogLive) -and ($paneTop - $listTop) -ge 3
        $visible = if ($pane) { $paneTop - $listTop } else { [math]::Max(3, [Console]::WindowHeight - $listTop - 3) }
        if ($Rows.Count) { $Selected = [math]::Max(0, [math]::Min($Selected, $Rows.Count - 1)) } else { $Selected = 0 }
        # Section titles are not selectable: keep moving the way the cursor was going, else turn around
        for ($n = 0; $n -lt 2 * $Rows.Count -and $Rows.Count -and $Rows[$Selected].Header; $n++) {
            $next = $Selected + $dir
            if ($next -lt 0 -or $next -ge $Rows.Count) { $dir = -$dir; $next = $Selected + $dir }
            $Selected = [math]::Max(0, [math]::Min($next, $Rows.Count - 1))
        }
        if ($Selected -lt $offset) { $offset = $Selected }
        if ($Selected -ge $offset + $visible) { $offset = $Selected - $visible + 1 }

        Show-VmmTuiHeader
        if ($dirty) {
            Write-VmmTuiLine -Row 3 -Text " $Title" -Role Accent
            Write-VmmTuiLine -Row 4 -Text " $ColumnHeader" -Role Muted
            for ($i = 0; $i -lt $visible; $i++) {
                $idx = $offset + $i
                if ($idx -lt $Rows.Count) {
                    $r = $Rows[$idx]
                    if ($r.Header) { Write-VmmTuiLine -Row ($listTop + $i) -Text (' ' + $r.Text) -Role Muted; continue }
                    $role = ConvertTo-VmmColorRole "$($r.Color)"
                    $mark = if ($role -in 'Ok', 'Warn', 'Fail') { $role } else { $null }
                    $text = if ($mark) { ' ' + $r.Text } else { '  ' + $r.Text }   # the mark takes the first cell
                    if ($idx -eq $Selected) { Write-VmmTuiLine -Row ($listTop + $i) -Text $text -Role Strong -BgRole AccentBg -Mark $mark }
                    else { Write-VmmTuiLine -Row ($listTop + $i) -Text $text -Role $(if ($role -eq 'Muted') { 'Muted' } else { 'Text' }) -Mark $mark }
                } else { Write-VmmTuiLine -Row ($listTop + $i) -Text '' }
            }
            $more = if ($Rows.Count -gt $visible) { "  [$($Selected + 1)/$($Rows.Count)]" } else { '' }
            Write-VmmTuiLine -Row ([Console]::WindowHeight - 2) -Text (" $Status$more") -Role $(if ($Status -match '^(POLICY|WARN|No terminal route|Open blocker|Snapshot gaps|Agents:)') { 'Warn' } else { 'Text' })
            $logKey = if ($pane) { 'F2 hide log' } else { 'F2 show log' }
            Write-VmmTuiLine -Row ([Console]::WindowHeight - 1) -Text " $Help | $logKey | F3 full log" -Role Muted -BgRole BarBg
            if (-not $pane) { Write-VmmTuiLine -Row ([Console]::WindowHeight - 3) -Text '' }
            $lastSeq = -1
            $dirty = $false
        }
        if ($pane -and $lastSeq -ne [int]$script:VmmLogSeq) {
            Show-VmmLogPane -Top $paneTop -Lines $paneLines
            $lastSeq = [int]$script:VmmLogSeq
        }

        $e = Read-VmmInput -TimeoutMs 1000
        switch ($e.Type) {
            'Tick' { continue }
            'Wheel' { if ($e.Delta -gt 0) { $Selected -= 3; $dir = -1 } else { $Selected += 3; $dir = 1 }; $dirty = $true }
            'Click' {
                $i = $e.Y - $listTop
                if ($i -ge 0 -and $i -lt $visible -and ($offset + $i) -lt $Rows.Count -and -not $Rows[$offset + $i].Header) {
                    if (($offset + $i) -eq $Selected) { return @{ Action = 'Enter'; Index = $Selected } }
                    $Selected = $offset + $i; $dirty = $true
                }
            }
            'DoubleClick' {
                $i = $e.Y - $listTop
                if ($i -ge 0 -and $i -lt $visible -and ($offset + $i) -lt $Rows.Count -and -not $Rows[$offset + $i].Header) { return @{ Action = 'Enter'; Index = $offset + $i } }
            }
            'Key' {
                $dirty = $true
                switch ($e.VK) {
                    38 { $Selected--; $dir = -1; break }                       # Up
                    40 { $Selected++; $dir = 1; break }                        # Down
                    33 { $Selected -= $visible; $dir = -1; break }             # PgUp
                    34 { $Selected += $visible; $dir = 1; break }              # PgDn
                    36 { $Selected = 0; $dir = 1; break }                      # Home
                    35 { $Selected = $Rows.Count - 1; $dir = -1; break }       # End
                    13 { return @{ Action = 'Enter'; Index = $Selected } }
                    27 { return @{ Action = 'Esc'; Index = $Selected } }
                    113 { [void](Switch-VmmLogLive); Clear-Host; $lastSize = ''; break }   # F2
                    114 { if (-not $script:VmmInLogScreen) { Show-VmmLogScreen; $script:VmmTuiListActive = $true; Clear-Host; $lastSize = '' }; break }   # F3
                    default {
                        $ch = "$($e.Char)".ToUpper()
                        if ($ch -and $Hotkeys -contains $ch) { return @{ Action = $ch; Index = $Selected } }
                    }
                }
            }
        }
    }
    } finally { $script:VmmTuiListActive = $false }
}
