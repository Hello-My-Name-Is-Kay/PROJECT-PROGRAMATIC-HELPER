function Get-VmmMediaInventory {
    # Reads the media repository (Staging.SourceShare). Read-only, top level of each folder only.
    #   <share>\Win_Server_2019_FR_FR.iso   OS images at the root, matched by Staging.OsMediaPattern
    #                                       (named groups Version and Lang; case-insensitive)
    #   <share>\<HOST>\*                    files only that host needs (SQL Server updates, tools)
    #   <file>.sha256                       optional sidecar holding the file's SHA256; when present the
    #                                       staging gate and the copy verify against it
    # Hidden files (Thumbs.db, desktop.ini) are ignored, and so are folders starting with _ (the
    # download cache _Downloads, your own _Archive...).
    [CmdletBinding()]
    param([string]$Share)
    if (-not $Share) { $Share = Get-VmmSetting 'Staging.SourceShare' -Required }
    if (-not (Test-Path -LiteralPath $Share)) {
        throw (New-VmmErrorRecord -Activity 'Media repository not reachable.' -Target $Share `
            -Cause 'Wrong path, VPN/network down, or your account has no read access to the share (Staging.SourceShare).' `
            -Fix 'Open the path in Explorer to test. Fix it in Settings (Staging.SourceShare), or raise a blocker report for read access.' `
            -Category ConnectionError -ErrorId 'VmmShareUnreachable')
    }
    $pattern = Get-VmmSetting 'Staging.OsMediaPattern' -Default '^Win_Server_(?<Version>\d{4}(R2)?)_(?<Lang>[A-Za-z]{2,3}[_-][A-Za-z]{2,4})\.iso$'
    $sidecar = {
        param($Path)
        $sc = "$Path.sha256"
        if (-not (Test-Path -LiteralPath $sc -PathType Leaf)) { return '' }
        $t = [IO.File]::ReadAllText($sc)
        if ($t -match '\b([A-Fa-f0-9]{64})\b') { $Matches[1].ToUpper() } else { '' }
    }
    $isos = @(); $folders = @(); $other = @()
    foreach ($i in @(Get-ChildItem -LiteralPath $Share -ErrorAction Stop)) {
        if ($i.PSIsContainer -and $i.Name.StartsWith('_')) { continue }
        if ($i.PSIsContainer) {
            $files = foreach ($f in @(Get-ChildItem -LiteralPath $i.FullName -ErrorAction SilentlyContinue)) {
                if ($f.PSIsContainer -or $f.Extension -eq '.sha256') { continue }
                [pscustomobject]@{ Name = $f.Name; Path = $f.FullName; SizeMB = [math]::Round($f.Length / 1MB, 1); Sha256 = (& $sidecar $f.FullName) }
            }
            $folders += [pscustomobject]@{ Name = $i.Name; Path = $i.FullName; Files = @($files) }
        } elseif ($i.Extension -eq '.sha256') {
            continue
        } elseif ($i.Name -match $pattern) {
            $isos += [pscustomobject]@{
                Name = $i.Name; Version = "$($Matches['Version'])".ToUpper(); Lang = (ConvertTo-VmmMediaLanguage $Matches['Lang'])
                Path = $i.FullName; SizeMB = [math]::Round($i.Length / 1MB, 1); Sha256 = (& $sidecar $i.FullName)
            }
        } else { $other += $i.Name }
    }
    [pscustomobject]@{ Share = $Share; Isos = @($isos); Folders = @($folders); Other = @($other) }
}
