function Get-VmmTheme {
    # The one place colours are defined. Deep iceberg blue throughout: a blue-black background, blue-tinted text, iceberg blue accents, and
    # green / orange / red kept for statuses only.
    #   TrueColor = 24-bit escape sequences (Windows Terminal, Windows 10+ console); else the 16 console
    #   colours in Console. Plain = no colour at all (--no-color).
    # UI.TrueColor: 'Auto' (default: try, fall back), $true, $false.
    [CmdletBinding()]
    param([switch]$Refresh)
    if ($script:VmmThemeCache -and -not $Refresh) { return $script:VmmThemeCache }
    $c = { param($r, $g, $b, $console) @{ R = $r; G = $g; B = $b; Console = [ConsoleColor]$console } }
    $roles = @{
        Bg       = & $c 4 16 27 'Black'            # deep blue-black (see Set-VmmConsoleBackground)
        Text     = & $c 196 214 229 'Gray'         # body text, ice tint
        Strong   = & $c 238 247 255 'White'        # text on the accent bar and the selected row
        Muted    = & $c 98 128 153 'DarkGray'      # blue-grey: column headers, hints, skipped rows
        Accent   = & $c 124 188 232 'Cyan'         # iceberg: titles and section headers
        AccentBg = & $c 24 92 138 'DarkBlue'       # deep iceberg: top bar and the selected row
        BarBg    = & $c 10 38 58 'DarkBlue'        # key bar at the bottom
        Ok       = & $c 63 185 80 'Green'
        Warn     = & $c 227 136 45 'DarkYellow'    # orange
        Fail     = & $c 229 83 75 'Red'
    }
    $plain = [bool]($script:VmmFlags -and $script:VmmFlags.NoColor)
    $want = 'Auto'
    try { $want = Get-VmmSetting 'UI.TrueColor' -Default 'Auto' } catch { }
    $true24 = $false
    if (-not $plain -and "$want" -ne 'False' -and $Host.Name -eq 'ConsoleHost') {
        if ($env:WT_SESSION -or "$want" -eq 'True') { $true24 = $true }
        else {
            try {
                if (-not ('VmmConsoleInput' -as [type])) {
                    Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'Resources\VmmConsoleInput.cs') -Raw) -Language CSharp -ErrorAction Stop
                }
                $true24 = [bool][VmmConsoleInput]::EnableVt()
            } catch { $true24 = $false }
        }
    }
    $script:VmmThemeCache = @{ Roles = $roles; TrueColor = $true24; Plain = $plain }
    $script:VmmThemeCache
}
