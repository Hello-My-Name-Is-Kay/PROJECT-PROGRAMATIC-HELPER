function ConvertFrom-VmmHandoffReport {
    # Reads the VMMSTAGE1 line printed by the handoff script on a host:
    #   VMMSTAGE1|<HOST>|<file>*<bytes>*<sha256>|<file>*-1*|...   (-1 = file missing)
    # Returns one row per file (Host, DestName, Size, Sha256) from the last line for -HostName (any host
    # when not given). Text without such a line returns nothing.
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Text, [string]$HostName)
    if (-not $Text) { return }
    $line = @(($Text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^VMMSTAGE1\|[^|]+' } |
              Where-Object { -not $HostName -or ($_.Split('|')[1] -eq $HostName.ToUpper()) }) | Select-Object -Last 1
    if (-not $line) { return }
    $parts = $line.Split('|')
    foreach ($e in ($parts | Select-Object -Skip 2)) {
        $f = $e.Split('*')
        if ($f.Count -lt 2 -or -not $f[0]) { continue }
        $size = [long]-1; [void][long]::TryParse($f[1], [ref]$size)
        [pscustomobject]@{ Host = $parts[1]; DestName = $f[0]; Size = $size; Sha256 = $(if ($f.Count -gt 2) { "$($f[2])".ToUpper() } else { '' }) }
    }
}
