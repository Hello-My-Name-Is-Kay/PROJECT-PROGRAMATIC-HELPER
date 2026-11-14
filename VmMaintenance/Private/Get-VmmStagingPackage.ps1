function Get-VmmStagingPackage {
    # What one host needs staged. Staging.Layout = 'Repository' (default):
    #   1. OS image: Staging.OsMediaVersion in the host's install language, from the share root
    #      (an in-place upgrade needs media in the same language as the installed OS);
    #   2. every file in the host's own folder <share>\<HOST>\ (or the Staging.HostFolders alias);
    #   3. extra fixed entries from Staging.Packages (AppliesTo = OS wildcard).
    # Layout 'Packages' = only (3), the behaviour before 2.3.
    # Gate set = cannot be resolved (no image for that language, language unknown) and closes the
    # staging gate. Note = warning only (e.g. SQL update for a version not found on the host).
    # Without -Record only (3) is returned. -Inventory reuses one Get-VmmMediaInventory for many hosts.
    [CmdletBinding()]
    param([AllowNull()]$Record, $Inventory)
    $layout = Get-VmmSetting 'Staging.Layout' -Default 'Repository'
    $item = {
        param($Name, $Path, $Sha, $Source, $Applies, $Kind, $Dest, $Gate, $Note)
        [pscustomobject]@{ Name = $Name; Path = $Path; Sha256 = "$Sha".ToUpper(); Source = $Source; AppliesTo = $Applies
                           Kind = $Kind; DestName = $Dest; Gate = $Gate; Note = $Note }
    }
    $os = if ($Record -and $Record.Check -and $Record.Check.OS) { "$($Record.Check.OS)" } else { '' }

    if ($layout -eq 'Repository' -and $Record) {
        if (-not $Inventory) { $Inventory = Get-VmmMediaInventory }
        $ver = "$(Get-VmmSetting 'Staging.OsMediaVersion' -Default '2019')".ToUpper()
        $raw = if ($Record.Check -and $Record.Check.PSObject.Properties['Lang'] -and $Record.Check.Lang) { $Record.Check.Lang }
               elseif ($Record.Baseline -and $Record.Baseline.PSObject.Properties['Lang']) { $Record.Baseline.Lang } else { '' }
        $lang = ConvertTo-VmmMediaLanguage $raw
        $have = (@($Inventory.Isos | Where-Object { $_.Version -eq $ver } | ForEach-Object { $_.Lang } | Sort-Object -Unique) -join ', ')
        if (-not $have) { $have = 'none' }
        if (-not $lang) {
            & $item "Windows Server $ver image" '' '' 'media repository' '*' 'OsMedia' '' `
                "LANGUAGE UNKNOWN: run Check (or the host agent / collector) first. The Windows Server $ver image must match the host's install language (on the share for $ver`: $have)." $null
        } else {
            $iso = @($Inventory.Isos | Where-Object { $_.Version -eq $ver -and $_.Lang -eq $lang }) | Select-Object -First 1
            if ($iso) {
                & $item $iso.Name $iso.Name $iso.Sha256 'media repository' '*' 'OsMedia' $iso.Name $null $null
            } else {
                $expect = 'Win_Server_{0}_{1}.iso' -f $ver, $lang.Replace('-', '_')
                & $item $expect $expect '' 'media repository' '*' 'OsMedia' $expect `
                    "MISSING: no Windows Server $ver image in $lang. Download it and save it as $(Join-Path $Inventory.Share $expect) (on the share for $ver`: $have)." $null
            }
        }

        $alias = Get-VmmSetting 'Staging.HostFolders' -Default @{}
        $fname = if ($alias -is [System.Collections.IDictionary] -and $alias[$Record.Name]) { "$($alias[$Record.Name])" } else { $Record.Name }
        $folder = @($Inventory.Folders | Where-Object { $_.Name -eq $fname }) | Select-Object -First 1
        if ($folder) {
            # SQL Server updates: warn when the host has no instance of that version (PatchLevel major).
            $years = @{ '10.0' = '2008'; '10.50' = '2008R2'; '11' = '2012'; '12' = '2014'; '13' = '2016'; '14' = '2017'; '15' = '2019'; '16' = '2022'; '17' = '2025' }
            $sql = if ($Record.Check -and $Record.Check.Sql) { "$($Record.Check.Sql)" } else { '' }
            $found = @(foreach ($m in [regex]::Matches($sql, '\b(\d{2})\.(\d{1,2})\.\d+')) {
                $k = if ($m.Groups[1].Value -eq '10') { '10.' + $m.Groups[2].Value } else { $m.Groups[1].Value }
                if ($years.ContainsKey($k)) { $years[$k] }
            }) | Sort-Object -Unique
            foreach ($f in $folder.Files) {
                $note = $null
                if ($sql -and $f.Name -match '^SQLServer(\d{4}(R2)?)') {
                    $y = $Matches[1].ToUpper()
                    if ($sql -eq 'none') { $note = "SQL Server $y update, but no SQL Server instance was found on this host." }
                    elseif ($found -and $found -notcontains $y) { $note = "SQL Server $y update, but this host has SQL Server $($found -join ', ')." }
                }
                & $item $f.Name (Join-Path $folder.Name $f.Name) $f.Sha256 "host folder $($folder.Name)" '*' 'HostFile' $f.Name $null $note
            }
        }
    }

    $pk = if ($layout -eq 'Repository') { @(Get-VmmSetting 'Staging.Packages' -Default @()) } else { @(Get-VmmSetting 'Staging.Packages' -Required) }
    foreach ($p in $pk) {
        if (-not $p -or "$($p.Name)$($p.Path)" -match '<[^>]*>') { continue }   # unedited example entry
        $applies = if ($p.AppliesTo) { $p.AppliesTo } else { '*' }
        if (-not $Record -or $applies -eq '*' -or $os -like $applies) {
            & $item $p.Name $p.Path $p.Sha256 $p.Source $applies 'Package' ([IO.Path]::GetFileName($p.Path)) $null $null
        }
    }
}
