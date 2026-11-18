function Read-VmmLines {
    # Several lines typed or pasted one per line; an empty line ends. Enter on the first line keeps -Current.
    # '-' alone on the first line clears the list.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt, [string[]]$Current = @())
    if ($Current) {
        Write-VmmLog "$Prompt - now:" -Level Info
        $n = 0; foreach ($c in $Current) { $n++; Write-VmmLog ("  {0}. {1}" -f $n, $c) -Level Muted }
        Write-VmmLog 'Type the new lines (an empty line ends), Enter at once keeps them, - clears them.' -Level Muted
    } else { Write-VmmLog "$Prompt - one per line, an empty line ends." -Level Info }
    $out = @()
    while ($true) {
        $l = Read-VmmPrompt ('  ' + ($out.Count + 1))
        if (-not $l) { break }
        if (-not $out.Count -and $l -eq '-') { return @() }
        $out += $l
    }
    if (-not $out.Count) { return @($Current) }
    $out
}
