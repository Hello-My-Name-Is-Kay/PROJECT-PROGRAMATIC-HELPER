function Invoke-VmmListView {
    # Generic scrollable list screen. Handles arrows, PgUp/PgDn, Home/End, wheel, click (select),
    # click on the selected row or double-click (open). Returns @{ Action; Index } where Action is
    # 'Enter', 'Esc' or one of -Hotkeys (upper-case char).
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
    while ($true) {
        $size = "$([Console]::WindowWidth)x$([Console]::WindowHeight)"
        if ($size -ne $lastSize) { Clear-Host; $lastSize = $size; $dirty = $true }
        $visible = [math]::Max(3, [Console]::WindowHeight - $listTop - 3)
        if ($Rows.Count) { $Selected = [math]::Max(0, [math]::Min($Selected, $Rows.Count - 1)) } else { $Selected = 0 }
        if ($Selected -lt $offset) { $offset = $Selected }
        if ($Selected -ge $offset + $visible) { $offset = $Selected - $visible + 1 }

        Show-VmmTuiHeader
        if ($dirty) {
            Write-VmmTuiLine -Row 3 -Text " $Title" -Fg Cyan
            Write-VmmTuiLine -Row 4 -Text " $ColumnHeader" -Fg DarkGray
            for ($i = 0; $i -lt $visible; $i++) {
                $idx = $offset + $i
                if ($idx -lt $Rows.Count) {
                    $r = $Rows[$idx]
                    $fg = if ($r.Color) { [ConsoleColor]$r.Color } else { [ConsoleColor]::Gray }
                    if ($idx -eq $Selected) { Write-VmmTuiLine -Row ($listTop + $i) -Text ("> " + $r.Text) -Fg Black -Bg Cyan }
                    else { Write-VmmTuiLine -Row ($listTop + $i) -Text ("  " + $r.Text) -Fg $fg }
                } else { Write-VmmTuiLine -Row ($listTop + $i) -Text '' }
            }
            $more = if ($Rows.Count -gt $visible) { "  [$($Selected + 1)/$($Rows.Count)]" } else { '' }
            Write-VmmTuiLine -Row ([Console]::WindowHeight - 2) -Text (" $Status$more") -Fg Yellow
            Write-VmmTuiLine -Row ([Console]::WindowHeight - 1) -Text " $Help" -Fg Black -Bg Gray
            $dirty = $false
        }

        $e = Read-VmmInput -TimeoutMs 1000
        switch ($e.Type) {
            'Tick' { continue }
            'Wheel' { if ($e.Delta -gt 0) { $Selected -= 3 } else { $Selected += 3 }; $dirty = $true }
            'Click' {
                $i = $e.Y - $listTop
                if ($i -ge 0 -and $i -lt $visible -and ($offset + $i) -lt $Rows.Count) {
                    if (($offset + $i) -eq $Selected) { return @{ Action = 'Enter'; Index = $Selected } }
                    $Selected = $offset + $i; $dirty = $true
                }
            }
            'DoubleClick' {
                $i = $e.Y - $listTop
                if ($i -ge 0 -and $i -lt $visible -and ($offset + $i) -lt $Rows.Count) { return @{ Action = 'Enter'; Index = $offset + $i } }
            }
            'Key' {
                $dirty = $true
                switch ($e.VK) {
                    38 { $Selected--; break }                       # Up
                    40 { $Selected++; break }                       # Down
                    33 { $Selected -= $visible; break }             # PgUp
                    34 { $Selected += $visible; break }             # PgDn
                    36 { $Selected = 0; break }                     # Home
                    35 { $Selected = $Rows.Count - 1; break }       # End
                    13 { return @{ Action = 'Enter'; Index = $Selected } }
                    27 { return @{ Action = 'Esc'; Index = $Selected } }
                    default {
                        $ch = "$($e.Char)".ToUpper()
                        if ($ch -and $Hotkeys -contains $ch) { return @{ Action = $ch; Index = $Selected } }
                    }
                }
            }
        }
    }
}
