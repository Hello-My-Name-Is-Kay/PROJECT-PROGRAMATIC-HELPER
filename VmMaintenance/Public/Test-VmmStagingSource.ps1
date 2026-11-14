function Test-VmmStagingSource {
    <#
    .SYNOPSIS
        Staging gate: checks that every file a host needs is in the media repository (and its SHA256
        matches when one is known). Missing files come back as a gate saying exactly what to download
        and where to save it.
    .DESCRIPTION
        Repository: Staging.SourceShare. OS images sit at its root (Win_Server_2019_FR_FR.iso), one
        folder per host holds that host's own files (SQL Server updates...). The image is picked by
        Staging.OsMediaVersion and the host's install language. Hashes come from Staging.Packages or
        from a <file>.sha256 sidecar; they are cached per file size+date for the session.
        -Record: one host. Without it: every workable host in the fleet (rows show which hosts need each file).
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
    $layout = Get-VmmSetting 'Staging.Layout' -Default 'Repository'
    $inv = if ($layout -eq 'Repository') { Get-VmmMediaInventory -Share $share } else { $null }
    $targets = @($null)
    if ($Record) { $targets = @($Record) }
    elseif ($layout -eq 'Repository') {
        $hosts = @(try { (Read-VmmStore).Hosts | Where-Object { -not $_.Hold -and (Get-VmmHostPolicy -Record $_).Workable } } catch { })
        $targets = @($hosts) + @($null)
    }

    # One row per distinct file (or per unresolved gate); Hosts lists who needs it.
    $byKey = [ordered]@{}
    foreach ($t in $targets) {
        foreach ($p in @(Get-VmmStagingPackage -Record $t -Inventory $inv)) {
            $key = if ($p.Path) { "$($p.Kind)|$($p.Path)".ToUpper() } else { "$($p.Kind)|?|$($t.Name)" }
            if (-not $byKey.Contains($key)) { $byKey[$key] = @{ P = $p; Hosts = New-Object System.Collections.Generic.List[string]; Notes = New-Object System.Collections.Generic.List[string] } }
            if ($t) { $byKey[$key].Hosts.Add($t.Name) }
            if ($p.Note) { $byKey[$key].Notes.Add($(if ($t) { "$($t.Name): $($p.Note)" } else { $p.Note })) }
        }
    }

    if (-not $script:VmmHashCache) { $script:VmmHashCache = @{} }
    $rows = foreach ($e in $byKey.Values) {
        $p = $e.P
        $full = if ($p.Path) { Join-Path $share $p.Path } else { '' }
        $row = [ordered]@{ Name = $p.Name; Kind = $p.Kind; File = $full; DestName = $p.DestName; Sha256 = $p.Sha256; Present = $false; HashOk = $null
                           SizeMB = $null; Hosts = (@($e.Hosts) -join ', '); Gate = $p.Gate; Note = (@($e.Notes) -join ' | ') }
        if ($row.Gate) { [pscustomobject]$row; continue }
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
        $rows | Format-Table Kind, Name, Present, HashOk, SizeMB, Hosts -AutoSize | Out-Host
        foreach ($n in @($rows | Where-Object { $_.Note })) { Write-VmmLog "$($n.Name): $($n.Note)" -Level Warn }
        if (-not $rows) { Write-VmmLog 'Nothing to stage: no workable hosts in the fleet and no extra packages (Staging.Packages).' -Level Warn }
        elseif ($gates) { foreach ($g in $gates) { Write-VmmLog "$($g.Gate)$(if ($g.Hosts) { " [hosts: $($g.Hosts)]" })" -Level Error }; Write-VmmLog 'Staging gate CLOSED: fix the files above, then re-check (R in the console, or: vmm stage).' -Level Warn }
        else { Write-VmmLog "Staging gate open: all $($rows.Count) file(s) present$(if ($rows | Where-Object HashOk) { ', hashes verified where known' })." -Level Success }
    }
    if ($PassThru) { $rows }
}
