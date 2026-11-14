function Test-VmmStagingSource {
    <#
    .SYNOPSIS
        Staging gate: checks every package the workflow needs is on the network share (and its SHA256
        matches when one is configured). Missing files come back as a gate telling you exactly what to
        download and where to put it.
    .DESCRIPTION
        Share: Staging.SourceShare (set at install or in Settings). Packages: Staging.Packages.
        Hashes are cached per file size+date for the session, so big ISOs are hashed once.
    .EXAMPLE
        Test-VmmStagingSource
    #>
    [CmdletBinding()]
    param([AllowNull()]$Record, [switch]$PassThru, [switch]$Quiet)
    $share = Get-VmmSetting 'Staging.SourceShare' -Required
    if (-not (Test-Path -LiteralPath $share)) {
        throw (New-VmmErrorRecord -Activity 'Staging share not reachable.' -Target $share `
            -Cause 'Wrong path, VPN/network down, or your account has no read access to the staging share (SourceShare).' `
            -Fix 'Open the path in Explorer to test. Fix it in Settings (Staging.SourceShare), or raise a blocker report for read access.' `
            -Category ConnectionError -ErrorId 'VmmShareUnreachable')
    }
    if (-not $script:VmmHashCache) { $script:VmmHashCache = @{} }
    $rows = foreach ($p in Get-VmmStagingPackage -Record $Record) {
        $full = Join-Path $share $p.Path
        $row = [ordered]@{ Name = $p.Name; File = $full; Present = $false; HashOk = $null; SizeMB = $null; Gate = $null }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $fi = Get-Item -LiteralPath $full
            $row.Present = $true; $row.SizeMB = [math]::Round($fi.Length / 1MB, 1)
            if ($p.Sha256) {
                $key = "$full|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
                if (-not $script:VmmHashCache.ContainsKey($key)) {
                    if (-not $Quiet) { Write-VmmLog "Hashing $($p.Name) ($($row.SizeMB) MB)..." -Level Muted }
                    $script:VmmHashCache[$key] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
                }
                $row.HashOk = ($script:VmmHashCache[$key] -eq $p.Sha256)
                if (-not $row.HashOk) { $row.Gate = "HASH MISMATCH: $full is not the expected file (corrupt or wrong version). Re-download from $($p.Source) and replace it." }
            }
        } else {
            $row.Gate = "MISSING: download '$($p.Name)' from $($p.Source) and save it as $full$(if ($p.Sha256) { " (SHA256 $($p.Sha256))" })"
        }
        [pscustomobject]$row
    }
    $rows = @($rows)
    $gates = @($rows | Where-Object { $_.Gate })
    if (-not $Quiet) {
        $rows | Format-Table Name, Present, HashOk, SizeMB -AutoSize | Out-Host
        if ($gates) { foreach ($g in $gates) { Write-VmmLog $g.Gate -Level Error }; Write-VmmLog 'Staging gate CLOSED: fix the files above, then re-check (R in the console, or: vmm stage -Check).' -Level Warn }
        else { Write-VmmLog "Staging gate open: all $($rows.Count) package(s) present$(if ($rows | Where-Object HashOk) { ' and verified' })." -Level Success }
    }
    if ($PassThru) { $rows }
}
