function Write-VmmTuiLine {
    # Writes one full-width line at a row (padded/truncated, so no Clear-Host flicker).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Row,
        [AllowEmptyString()][string]$Text = '',
        [ConsoleColor]$Fg = [ConsoleColor]::Gray,
        [ConsoleColor]$Bg = [ConsoleColor]::Black
    )
    $w = [Console]::WindowWidth - 1
    if ($Row -lt 0 -or $Row -ge [Console]::WindowHeight) { return }
    $t = $Text -replace '[\r\n\t]', ' '
    if ($t.Length -gt $w) { $t = $t.Substring(0, [math]::Max(0, $w - 1)) + '~' }
    [Console]::SetCursorPosition(0, $Row + [Console]::WindowTop)
    Write-Host $t.PadRight($w) -ForegroundColor $Fg -BackgroundColor $Bg -NoNewline
}
