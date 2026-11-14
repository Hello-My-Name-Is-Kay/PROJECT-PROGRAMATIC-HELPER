function Save-VmmSqlUpdate {
    <#
    .SYNOPSIS
        Downloads the SQL Server updates (service pack and/or CU) each host needs, once, and puts them
        in each host's folder on the media repository.
    .DESCRIPTION
        From each host's last check (SQL version and install language) and the dbatools build
        reference, finds the target update per instance (latest, or SqlUpdates.MaxBehind), then:
          1. downloads each KB once into the cache <share>\_Downloads\SQL\<KB>\ (Downloads.CacheFolder),
             keeps it only when Microsoft's signature is valid, writes a .sha256 next to it;
          2. copies it into <share>\<HOST>\ unless a file with that KB number is already there.
        Staging then copies the host folder to C:\Temp on the host like any other file, and someone
        working in RDP/RDM finds everything for that host in one folder. Nothing is installed: vmm
        never runs SQL updates. Changes only the share, so it is allowed any time.
        Needs dbatools (Install-Module dbatools -Scope CurrentUser) and internet access from this laptop.
    .EXAMPLE
        vmm fetch -Preview          # what each host needs, what is cached, nothing downloaded
    .EXAMPLE
        vmm fetch                   # download what is missing, fill the host folders
    .EXAMPLE
        Save-VmmSqlUpdate -HostName srv01, srv02
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$HostName, [switch]$Preview, [switch]$PassThru)
    Assert-VmmVpn -Activity 'SQL update fetch'
    $share = Get-VmmSetting 'Staging.SourceShare' -Required
    $cache = Get-VmmSetting 'Downloads.CacheFolder' -Default (Join-Path $share '_Downloads')
    if (-not (Get-Command Test-DbaBuild -ErrorAction SilentlyContinue)) {
        Write-VmmLog 'Loading dbatools (first time can take 20 s)...' -Level Trace
        try { Import-Module dbatools -ErrorAction Stop } catch {
            throw (New-VmmErrorRecord -Activity 'dbatools is not installed (it holds the list of every SQL Server SP/CU and downloads them).' `
                -Fix 'Install it once: Install-Module dbatools -Scope CurrentUser   (no admin needed), then run: vmm fetch -Preview' -Category NotInstalled -ErrorId 'VmmNoDbatools')
        }
    }
    try { $null = Get-DbaBuild -Build '13.0.5026' -Update -EnableException; Write-VmmLog 'SQL build reference refreshed from the internet' -Level Trace }
    catch { Write-VmmLog "Could not refresh the SQL build reference (offline?): using the copy in dbatools. Newest CUs may be missing. ($($_.Exception.Message))" -Level Warn }

    $store = Read-VmmStore
    $hosts = @($store.Hosts | Where-Object { -not $HostName -or $HostName -contains $_.Name })
    $alias = Get-VmmSetting 'Staging.HostFolders' -Default @{}
    $plans = @{}
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($h in $hosts) {
        $pol = try { Get-VmmHostPolicy -Record $h } catch { $null }
        if ($pol -and $pol.PSObject.Properties['Workable'] -and -not $pol.Workable) { continue }
        foreach ($i in @(Get-VmmSqlInstance -Record $h)) {
            if (-not $i.Build) { continue }
            if (-not $plans.ContainsKey($i.Build)) {
                try { $plans[$i.Build] = Get-VmmSqlUpdatePlan -Build $i.Build }
                catch { $plans[$i.Build] = [pscustomobject]@{ Current = $i.PatchLevel; Target = ''; Steps = @(); Warning = "Build lookup failed: $($_.Exception.Message)" } }
            }
            $p = $plans[$i.Build]
            $folder = if ($alias -is [System.Collections.IDictionary] -and $alias[$h.Name]) { "$($alias[$h.Name])" } else { $h.Name }
            if (-not $p.Steps.Count) {
                $rows.Add([pscustomobject]@{ Host = $h.Name; Instance = $i.Instance; Current = $p.Current; Target = $(if ($p.Warning) { '?' } else { 'up to date' }); Kb = ''; Lang = $i.Lang; Status = $(if ($p.Warning) { $p.Warning } else { 'nothing to fetch' }); Folder = $folder })
                continue
            }
            foreach ($s in $p.Steps) {
                $hostDir = Join-Path $share $folder
                $inHost = @(Get-ChildItem -LiteralPath $hostDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match [regex]::Escape($s.Kb) -and $_.Extension -ne '.sha256' })
                $inCache = @(Get-ChildItem -LiteralPath (Join-Path (Join-Path $cache 'SQL') $s.Kb) -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne '.sha256' })
                $st = if ($inHost) { 'in host folder' } elseif ($inCache) { 'in cache: copy to host folder' } else { 'download, then copy' }
                $rows.Add([pscustomobject]@{ Host = $h.Name; Instance = $i.Instance; Current = $p.Current; Target = $s.Label; Kb = $s.Kb; Kind = $s.Kind; Lang = $i.Lang; Status = $st; Folder = $folder })
            }
        }
    }
    if (-not $rows.Count) { Write-VmmLog 'No SQL Server instance found in the last checks (run Check first: 3 in the menu).' -Level Muted; return }
    $rows | Sort-Object Host, Instance | Format-Table Host, Instance, Current, Target, Kb, Lang, Status -AutoSize | Out-VmmHost
    $todo = @($rows | Where-Object { $_.Kb -and $_.Status -ne 'in host folder' })
    $dl = @($todo | Where-Object { $_.Status -like 'download*' } | ForEach-Object { "$($_.Kb)|$($_.Lang)" } | Sort-Object -Unique)
    Write-VmmLog ("{0} update file(s) to put in host folders, {1} download(s) (each KB once, cached in {2})" -f $todo.Count, $dl.Count, $cache) -Level Info
    if ($Preview -or -not $todo) { if ($PassThru) { $rows }; return }

    $i = 0
    foreach ($t in @($todo | Sort-Object Kb, Lang, Host)) {
        $i++
        Write-VmmLog ("{0}/{1}: {2} {3} for {4}" -f $i, $todo.Count, $t.Kb, $t.Lang, $t.Host) -Level Trace
        try {
            $files = @(Get-VmmCachedSqlUpdate -Kb $t.Kb -Lang $t.Lang -CacheDir $cache)
            if (-not $files) { continue }
            $hostDir = Join-Path $share $t.Folder
            if (-not (Test-Path -LiteralPath $hostDir)) { New-Item -ItemType Directory -Path $hostDir -Force | Out-Null }
            foreach ($f in $files) {
                $dest = Join-Path $hostDir $f.Name
                if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -eq $f.Length) { continue }
                if ($PSCmdlet.ShouldProcess($dest, "Copy $($f.Name) from the cache")) {
                    Copy-VmmFileWithProgress -Source $f.FullName -Destination $dest -Label "$($t.Host): $($f.Name)"
                    if (Test-Path -LiteralPath "$($f.FullName).sha256") { Copy-Item -LiteralPath "$($f.FullName).sha256" -Destination "$dest.sha256" -Force }
                }
            }
            $t.Status = 'in host folder'
            Write-VmmLog "$($t.Host): $($t.Kb) ready in $hostDir" -Level Success
        } catch {
            $t.Status = "failed: $($_.Exception.Message.Split([Environment]::NewLine)[0])"
            Write-VmmLog "$($t.Host): $($t.Kb) - $($_.Exception.Message)" -Level Error
            if ($_.FullyQualifiedErrorId -like 'VmmNoDbatools*') { break }
        }
    }
    $bad = @($todo | Where-Object { $_.Status -like 'failed*' })
    if ($bad) { Write-VmmLog "$($bad.Count) of $($todo.Count) not done - see the lines above; run the fetch again later (finished downloads are kept)." -Level Warn }
    else { Write-VmmLog 'All SQL updates are in the host folders. Stage (or copy by hand in RDP) as usual; installing them stays a manual step.' -Level Success }
    if ($PassThru) { $rows }
}
