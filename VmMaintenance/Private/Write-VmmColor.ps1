function Write-VmmColor {
    # Write-Host in a theme role (Get-VmmTheme). 24-bit colour when the console takes it, else the nearest of
    # the 16 console colours, else plain text (--no-color). -Always: colour even with --no-color (the list
    # screens need a visible selection bar).
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Text = '',
        [string]$Role = 'Text',
        [string]$BgRole,
        [switch]$NoNewline,
        [switch]$Always
    )
    $th = Get-VmmTheme
    if ($th.Plain -and -not $Always) { Write-Host $Text -NoNewline:$NoNewline; return }
    $f = $th.Roles[$Role]; if (-not $f) { $f = $th.Roles.Text }
    $b = if ($BgRole) { $th.Roles[$BgRole] } else { $null }
    if ($th.TrueColor) {
        $e = [char]27
        $seq = "${e}[38;2;$($f.R);$($f.G);$($f.B)m"
        if ($b) { $seq += "${e}[48;2;$($b.R);$($b.G);$($b.B)m" }
        Write-Host ($seq + $Text + "${e}[0m") -NoNewline:$NoNewline
    } else {
        $p = @{ ForegroundColor = $f.Console }
        if ($b) { $p.BackgroundColor = $b.Console }
        Write-Host $Text @p -NoNewline:$NoNewline
    }
}
