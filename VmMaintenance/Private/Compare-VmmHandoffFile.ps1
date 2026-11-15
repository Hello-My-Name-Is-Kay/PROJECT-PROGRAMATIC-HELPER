function Compare-VmmHandoffFile {
    # Expected files (Get-VmmHandoffItem) against what a host reported (DestName, Size, Sha256; Size -1 or no
    # row = missing). Status per file: OK | Missing | SizeMismatch | HashMismatch | NotHashed (size right, but
    # an expected SHA256 could not be read with this method). Pure: no I/O.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Expected, [AllowEmptyCollection()][object[]]$Reported = @(), [string]$Method = '')
    foreach ($e in $Expected) {
        $r = @($Reported | Where-Object { $_.DestName -eq $e.DestName }) | Select-Object -Last 1
        $size = if ($r) { [long]$r.Size } else { [long]-1 }
        $sha = if ($r) { "$($r.Sha256)".ToUpper() } else { '' }
        $want = "$($e.Sha256)".ToUpper()
        $status = if ($size -lt 0) { 'Missing' }
                  elseif ($size -ne [long]$e.Size) { 'SizeMismatch' }
                  elseif ($want -and $sha -and $sha -ne $want) { 'HashMismatch' }
                  elseif ($want -and -not $sha) { 'NotHashed' }
                  else { 'OK' }
        [pscustomobject]@{ File = $e.DestName; Status = $status; ExpectedBytes = [long]$e.Size; HostBytes = $size
                           ExpectedSha256 = $want; HostSha256 = $sha; Method = $Method }
    }
}
