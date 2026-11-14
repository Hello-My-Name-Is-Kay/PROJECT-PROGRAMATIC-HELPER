function Write-VmmTuiLine {
    # Writes one full-width line at a row (padded/truncated, so no Clear-Host flicker), in a theme role.
    # -Mark <role>: the first cell of the line is a small block in that status colour (Ok / Warn / Fail) and
    # the text stays neutral - colour marks the status, it does not paint the row.
    # -Fg / -Bg (console colour names) are still accepted and mapped to roles.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Row,
        [AllowEmptyString()][string]$Text = '',
        [ConsoleColor]$Fg = [ConsoleColor]::Gray,
        [ConsoleColor]$Bg = [ConsoleColor]::Black,
        [string]$Role,
        [string]$BgRole,
        [string]$Mark
    )
    $w = [Console]::WindowWidth - 1
    if ($Row -lt 0 -or $Row -ge [Console]::WindowHeight) { return }
    if (-not $Role) { $Role = ConvertTo-VmmColorRole "$Fg" }
    if (-not $BgRole) { $BgRole = switch ("$Bg") { 'DarkBlue' { 'AccentBg' } 'Cyan' { 'AccentBg' } 'Gray' { 'BarBg' } default { 'Bg' } } }
    if ($BgRole -eq 'AccentBg' -and $Role -eq 'Text') { $Role = 'Strong' }
    $t = $Text -replace '[\r\n\t]', ' '
    [Console]::SetCursorPosition(0, $Row + [Console]::WindowTop)
    if ($Mark -and $w -gt 2) {
        Write-VmmColor ' ' -Role Strong -BgRole $Mark -NoNewline -Always
        $w--
    }
    if ($t.Length -gt $w) { $t = $t.Substring(0, [math]::Max(0, $w - 1)) + '~' }
    Write-VmmColor $t.PadRight($w) -Role $Role -BgRole $BgRole -NoNewline -Always
}
