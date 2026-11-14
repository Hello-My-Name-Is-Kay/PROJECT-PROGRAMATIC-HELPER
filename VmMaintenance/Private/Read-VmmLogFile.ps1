function Read-VmmLogFile {
    # Reads a day log from byte -From on (encrypted or plain lines). Returns @{ Entries; Position }
    # so 'vmm log -Follow' can read only what is new. One key fetch for the whole read.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [long]$From = 0)
    $entries = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Entries = $entries; Position = 0 } }
    $fs = New-Object System.IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($From -gt $fs.Length) { $From = 0 }   # file replaced
        [void]$fs.Seek($From, [IO.SeekOrigin]::Begin)
        $sr = New-Object System.IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd()
        $pos = $fs.Length
    } finally { $fs.Dispose() }
    # Keep a half-written last line for the next read
    $cut = $text.LastIndexOf("`n")
    if ($cut -lt 0) { return [pscustomobject]@{ Entries = $entries; Position = $From } }
    $pos = $From + [Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $cut + 1))
    $key = $null
    try {
        foreach ($l in $text.Substring(0, $cut).Split("`n")) {
            $l = $l.TrimEnd("`r")
            if (-not $l) { continue }
            if ($l.StartsWith('E1:')) {
                try {
                    if (-not $key) { $key = Get-VmmDataKey }
                    $p = Unprotect-VmmBytes -Bytes ([Convert]::FromBase64String($l.Substring(3))) -Source $Path -DataKey $key
                    try { $l = [Text.Encoding]::UTF8.GetString($p) } finally { [Array]::Clear($p, 0, $p.Length) }
                } catch { $l = '|ERROR|(line could not be decrypted: damaged, or written by another Windows user)' }
            }
            $parts = $l.Split([char[]]'|', 3)
            if ($parts.Count -lt 3) { $parts = @('', 'PLAIN', $l) }
            $at = $null; try { $at = [datetime]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture) } catch { }
            $entries.Add([pscustomobject]@{ At = $at; Level = (Get-Culture).TextInfo.ToTitleCase($parts[1].ToLowerInvariant()); Text = $parts[2] })
        }
    } finally { if ($key) { [Array]::Clear($key.Enc, 0, 32); [Array]::Clear($key.Mac, 0, 32) } }
    [pscustomobject]@{ Entries = $entries; Position = $pos }
}
