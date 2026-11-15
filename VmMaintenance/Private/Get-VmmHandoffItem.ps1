function Get-VmmHandoffItem {
    # The files one host needs in Staging.TargetFolder, for the RDP/RDM handoff: what to copy, from where
    # (the share as the host would open it, the laptop outbox over \\tsclient), and the size and SHA256 the
    # copy must have. Same list and same gate as the terminal copy (Copy-VmmStagingPackage).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [switch]$WithOutbox)
    $pk = @(Test-VmmStagingSource -Record $Record -PassThru -Quiet)
    $gates = @($pk | Where-Object { $_.Gate })
    if ($gates) {
        throw (New-VmmErrorRecord -Activity 'Staging gate closed: required files are missing or wrong on the share.' -Target $Record.Name `
            -Cause (($gates | ForEach-Object { $_.Gate }) -join ' | ') -Fix 'Put the files on the share as listed first: RDP cannot fix a missing file.' `
            -Category ObjectNotFound -ErrorId 'VmmStagingGate')
    }
    $outbox = if ($WithOutbox) { Get-VmmPath -Name Outbox } else { $null }
    foreach ($p in $pk) {
        $dest = if ($p.DestName) { $p.DestName } else { [IO.Path]::GetFileName($p.File) }
        $fi = Get-Item -LiteralPath $p.File
        $local = if ($outbox) { Join-Path $outbox $dest } else { '' }
        $sources = @($p.File)
        $ts = ConvertTo-VmmTsClientPath $p.File            # share given as a local drive: reachable over \\tsclient as is
        if ($ts) { $sources += $ts }
        if ($local) { $sources += (ConvertTo-VmmTsClientPath $local) }
        [pscustomobject]@{ Name = $p.Name; DestName = $dest; Source = $p.File; Size = [long]$fi.Length; SizeMB = [math]::Round($fi.Length / 1MB, 1)
                           Sha256 = "$($p.Sha256)".ToUpper(); Outbox = $local; Sources = @($sources | Where-Object { $_ } | Select-Object -Unique) }
    }
}
