function Read-VmmHostCsv {
    # Reads an external host list: three columns, hostname or FQDN, domain, IP. Tolerant on purpose:
    #   - separator , ; or tab (detected from the first line); optional header row (detected: the third
    #     value of the first line is not an IP); with a header, columns are found by name
    #     (Hostname/FQDN/Name/ComputerName/Server, Domain, IP/IPAddress/IPv4/Address), else by position;
    #   - blank lines and lines starting with # are skipped; quotes are removed;
    #   - FQDN: short name = first label; empty domain = the rest of the FQDN;
    #   - IP must be IPv4 (0-255 x4) or it is dropped with a warning; the host is still imported.
    # Returns one object per valid row: Name, Fqdn, Domain, IP, Line. Bad rows are reported, not fatal.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-VmmErrorRecord -Activity 'Host CSV not found.' -Target $Path -Fix 'Check the path, or drag the file into the window to paste its path.' -Category ObjectNotFound -ErrorId 'VmmCsvNotFound')
    }
    $lines = @(Get-Content -LiteralPath $Path | ForEach-Object { "$_" })
    $data = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -and -not $lines[$i].TrimStart().StartsWith('#')) { [pscustomobject]@{ N = $i + 1; T = $lines[$i] } } })
    if (-not $data) { throw (New-VmmErrorRecord -Activity 'Host CSV is empty.' -Target $Path -Fix 'One host per line: hostname or FQDN, domain, IP.' -Category InvalidData -ErrorId 'VmmCsvEmpty') }
    $first = $data[0].T
    $sep = ','
    foreach ($c in ';', "`t") { if (($first.Split($c).Count) -gt ($first.Split($sep).Count)) { $sep = $c } }
    $split = { param($t) @($t.Split($sep) | ForEach-Object { $_.Trim().Trim('"').Trim("'").Trim() }) }
    $isIp = { param($v) $v -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$' -and -not (@($Matches[1..4] | Where-Object { [int]$_ -gt 255 })) }

    $col = @{ Host = 0; Domain = 1; IP = 2 }
    $cells = & $split $first
    $hasHeader = [bool]($cells | Where-Object { $_ -match '^(?i)(host ?name|fqdn|name|computer ?name|server|host|domain|ip|ip ?address|ipv4|address)$' })
    if (-not $hasHeader -and $cells.Count -ge 3 -and $cells[2] -and -not (& $isIp $cells[2])) { $hasHeader = $true }
    if ($hasHeader) {
        for ($k = 0; $k -lt $cells.Count; $k++) {
            switch -Regex ($cells[$k]) {
                '^(?i)(host ?name|fqdn|name|computer ?name|server|host)$' { $col.Host = $k }
                '^(?i)domain$'                                            { $col.Domain = $k }
                '^(?i)(ip|ip ?address|ipv4|address)$'                     { $col.IP = $k }
            }
        }
        $data = @($data | Select-Object -Skip 1)
    }
    $valid = '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$'
    foreach ($d in $data) {
        $c = & $split $d.T
        $h = if ($c.Count -gt $col.Host) { $c[$col.Host] } else { '' }
        $dom = if ($c.Count -gt $col.Domain) { $c[$col.Domain] } else { '' }
        $ip = if ($c.Count -gt $col.IP) { $c[$col.IP] } else { '' }
        $short = ($h -split '\.')[0]
        if ($short -notmatch $valid) { Write-VmmLog "Line $($d.N): '$h' is not a host name - skipped (letters, digits, '-', '_'; FQDN allowed)." -Level Warn; continue }
        $fqdn = $null
        if ($h -match '\.') {
            if ($h -notmatch '^[A-Za-z0-9_-]+(\.[A-Za-z0-9-]+)+$') { Write-VmmLog "Line $($d.N): '$h' is not a valid FQDN - short name kept." -Level Warn }
            else { $fqdn = $h.ToLower(); if (-not $dom) { $dom = $h.Substring($h.IndexOf('.') + 1) } }
        }
        if ($dom -and $dom -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$') { Write-VmmLog "Line $($d.N): domain '$dom' is not valid - left empty." -Level Warn; $dom = '' }
        if ($ip -and -not (& $isIp $ip)) { Write-VmmLog "Line $($d.N): '$ip' is not an IPv4 address - IP left empty for $short." -Level Warn; $ip = '' }
        if (-not $fqdn -and $dom -and $dom -match '\.') { $fqdn = ("$short.$dom").ToLower() }
        [pscustomobject]@{ Name = $short.ToUpper(); Fqdn = $fqdn; Domain = $dom.ToLower(); IP = $ip; Line = $d.N }
    }
}
