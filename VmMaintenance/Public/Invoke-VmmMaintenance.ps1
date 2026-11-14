function Invoke-VmmMaintenance {
    <#
    .SYNOPSIS
        Maintenance tools for vmm itself: health check, fleet store check, backup/restore, log and
        temp clean-up, UI reset.
    .DESCRIPTION
        Diagnose     versions, config, data key, fleet store, backups, logs, leftovers, tools, disk
        CheckStore   decrypts the fleet store and its .bak and looks for damaged or duplicate records
        Backup       copies the encrypted fleet store to data\backups (keeps Maintenance.KeepBackups, 14)
        ListBackups  backups with date, size and host count
        Restore      puts a backup back (-BackupFile); the current store is kept as fleet.vmm.before-restore
        CleanLogs    deletes day logs older than Log.KeepDays (30); -All: every day except today
        CleanTemp    old generated extractors, plaintext log exports, half-written files
        ResetUi      clears the UI caches and the in-memory log (files are kept)
        Nothing here touches hosts or Azure. Backups stay encrypted with the same DPAPI-protected key.
    .EXAMPLE
        vmm maint -Action Diagnose
    .EXAMPLE
        vmm maint -Action Restore -BackupFile fleet_20261114_0800.vmm
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Position = 0)][ValidateSet('Diagnose', 'CheckStore', 'Backup', 'ListBackups', 'Restore', 'CleanLogs', 'CleanTemp', 'ResetUi')]
        [string]$Action = 'Diagnose',
        [string]$BackupFile,
        [switch]$All,
        [switch]$PassThru,
        [switch]$Quiet
    )
    $dataDir = Get-VmmPath -Name Data
    $store   = Join-Path $dataDir 'fleet.vmm'
    $bdir    = Get-VmmPath -Name Backups
    $keep    = [math]::Max(1, [int](Get-VmmSetting 'Maintenance.KeepBackups' -Default 14))
    $testStore = {
        param($file)
        $plain = Unprotect-VmmBytes -Bytes ([IO.File]::ReadAllBytes($file)) -Source $file
        try { $o = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json } finally { [Array]::Clear($plain, 0, $plain.Length) }
        $o
    }
    $size = { param($path) if (Test-Path -LiteralPath $path) { ('{0:N1} MB' -f ((@(Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue) | Measure-Object Length -Sum).Sum / 1MB)) } else { 'missing' } }
    Write-VmmLog "Maintenance: $Action" -Level Muted -FileOnly

    switch ($Action) {
        'Diagnose' {
            $rows = New-Object System.Collections.Generic.List[object]
            $add = { param($c, $s, $d) $rows.Add([pscustomobject]@{ Check = $c; Status = $s; Detail = $d }) }
            $mod = Get-Module VmMaintenance
            & $add 'vmm version' 'OK' ("{0} | PowerShell {1} ({2})" -f $(if ($mod) { $mod.Version } else { '?' }), $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
            try { $cp = Resolve-VmmConfigPath; if ($cp) { $null = Import-PowerShellDataFile -LiteralPath $cp; & $add 'Settings file' 'OK' $cp } else { & $add 'Settings file' 'WARN' 'none yet: run vmm setup' } }
            catch { & $add 'Settings file' 'FAIL' $_.Exception.Message.Split([Environment]::NewLine)[0] }
            try { $k = Get-VmmDataKey; [Array]::Clear($k.Enc, 0, 32); [Array]::Clear($k.Mac, 0, 32); & $add 'Data key' 'OK' 'store.key opens for this Windows user (DPAPI)' }
            catch { & $add 'Data key' 'FAIL' $_.Exception.Message.Split([Environment]::NewLine)[0] }
            if (Test-Path -LiteralPath $store) {
                try { $s = & $testStore $store; & $add 'Fleet store' 'OK' ("{0} host(s), saved {1}, {2:N0} KB" -f @($s.Hosts).Count, $s.Updated, ((Get-Item -LiteralPath $store).Length / 1KB)) }
                catch { & $add 'Fleet store' 'FAIL' "$($_.Exception.Message.Split([Environment]::NewLine)[0]) - maintenance: Restore" }
            } else { & $add 'Fleet store' 'WARN' 'empty: import hosts (0 in the menu)' }
            if (Test-Path -LiteralPath "$store.bak") { try { $null = & $testStore "$store.bak"; & $add 'Store .bak' 'OK' 'previous save opens' } catch { & $add 'Store .bak' 'WARN' 'previous save does not open' } }
            $bk = @(Get-ChildItem -LiteralPath $bdir -Filter 'fleet_*.vmm' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
            if ($bk) { $age = ((Get-Date) - $bk[-1].LastWriteTime).TotalDays; & $add 'Backups' $(if ($age -gt 7) { 'WARN' } else { 'OK' }) ("{0} kept, newest {1:yyyy-MM-dd HH:mm}" -f $bk.Count, $bk[-1].LastWriteTime) }
            else { & $add 'Backups' 'WARN' 'none yet: maintenance B (vmm also makes one a day at start)' }
            $ldir = Get-VmmPath -Name Logs
            $lf = @(Get-ChildItem -LiteralPath $ldir -Filter 'vmm_*.log' -File -ErrorAction SilentlyContinue)
            & $add 'Log files' 'OK' ("{0} day(s), {1}, encrypted: {2}, live view: {3}, kept {4} days" -f $lf.Count, (& $size $ldir), [bool](Get-VmmSetting 'Log.Encrypt' -Default $true), (Test-VmmLogLive), (Get-VmmSetting 'Log.KeepDays' -Default 30))
            $ef = Join-Path $ldir 'errors.log'
            if (Test-Path -LiteralPath $ef) {
                $since = (Get-Date).AddDays(-7).ToUniversalTime().ToString('o')
                $n = @(Get-Content -LiteralPath $ef -ErrorAction SilentlyContinue | Where-Object { $_.Substring(0, [math]::Min(33, $_.Length)) -ge $since }).Count
                & $add 'Errors (7 days)' $(if ($n) { 'WARN' } else { 'OK' }) ("{0} unexpected error(s) - vmm issue -FromErrorLog sends them as a ticket" -f $n)
            }
            $old = @(Get-ChildItem -LiteralPath (Get-VmmPath -Name Agents) -File -ErrorAction SilentlyContinue)
            $plain = @(Get-ChildItem -LiteralPath (Join-Path (Get-VmmPath -Name Reports) 'Logs') -File -ErrorAction SilentlyContinue)
            & $add 'Leftover files' $(if ($old.Count + $plain.Count) { 'WARN' } else { 'OK' }) ("{0} generated extractor(s), {1} plaintext log export(s) - maintenance T cleans them" -f $old.Count, $plain.Count)
            & $add 'Reports folder' 'OK' ("{0} ({1})" -f (Get-VmmPath -Name Reports), (& $size (Get-VmmPath -Name Reports)))
            & $add 'GitHub CLI' $(if (Get-Command gh -ErrorAction SilentlyContinue) { 'OK' } else { 'WARN' }) $(if (Get-Command gh -ErrorAction SilentlyContinue) { 'gh found (updates, issues, PRs)' } else { 'gh not found: updates and tickets from vmm need it (winget install GitHub.cli)' })
            & $add 'Az modules' $(if (Get-Module -ListAvailable Az.Accounts) { 'OK' } else { 'WARN' }) $(if (Get-Module -ListAvailable Az.Accounts) { 'Az.Accounts available' } else { 'Az.Accounts missing: Install-Module Az -Scope CurrentUser' })
            try {
                $root = [IO.Path]::GetPathRoot($dataDir); $d = New-Object IO.DriveInfo($root)
                & $add 'Disk (data)' $(if ($d.AvailableFreeSpace -lt 2GB) { 'WARN' } else { 'OK' }) ('{0} {1:N1} GB free' -f $root, ($d.AvailableFreeSpace / 1GB))
            } catch { }
            try { & $add 'Console' $(if ([Console]::WindowWidth -lt 100 -or [Console]::WindowHeight -lt 30) { 'WARN' } else { 'OK' }) ('{0}x{1} (100x30 or more recommended for the log pane), host {2}' -f [Console]::WindowWidth, [Console]::WindowHeight, $Host.Name) } catch { }
            if (-not $Quiet) {
                foreach ($r in $rows) {
                    $lvl = switch ($r.Status) { 'OK' { 'Success' } 'WARN' { 'Warn' } default { 'Error' } }
                    Write-VmmLog ('{0,-16} {1,-5} {2}' -f $r.Check, $r.Status, $r.Detail) -Level $lvl
                }
            }
            if ($PassThru) { return $rows }
        }
        'CheckStore' {
            if (-not (Test-Path -LiteralPath $store)) { Write-VmmLog 'No fleet store yet: nothing to check.' -Level Muted; return }
            $s = & $testStore $store
            $hosts = @($s.Hosts | Where-Object { $_ })
            $noName = @($hosts | Where-Object { -not $_.Name }).Count
            $dups = @($hosts | Where-Object { $_.Name } | Group-Object Name | Where-Object Count -gt 1 | ForEach-Object Name)
            Write-VmmLog ("Fleet store opens: {0} host(s), last saved {1}." -f $hosts.Count, $s.Updated) -Level Success
            if ($noName) { Write-VmmLog "$noName record(s) without a name: restore a backup or remove them." -Level Warn }
            if ($dups) { Write-VmmLog ("Duplicate host names: {0}. Remove one (D on the fleet screen) and re-import." -f ($dups -join ', ')) -Level Warn }
            if (-not $noName -and -not $dups) { Write-VmmLog 'No damaged or duplicate records.' -Level Success }
            if ($PassThru) { [pscustomobject]@{ Hosts = $hosts.Count; NoName = $noName; Duplicates = $dups } }
        }
        'Backup' {
            if (-not (Test-Path -LiteralPath $store)) { Write-VmmLog 'No fleet store yet: nothing to back up.' -Level Muted; return }
            if (-not (Test-Path -LiteralPath $bdir)) { New-Item -ItemType Directory -Path $bdir -Force | Out-Null }
            $dest = Join-Path $bdir ('fleet_{0}.vmm' -f (Get-Date).ToString('yyyyMMdd_HHmmss'))
            if ($PSCmdlet.ShouldProcess($dest, 'Back up the encrypted fleet store')) {
                Copy-Item -LiteralPath $store -Destination $dest -Force
                $existing = @(Get-ChildItem -LiteralPath $bdir -Filter 'fleet_*.vmm' -File | Sort-Object LastWriteTime -Descending)
                $existing | Select-Object -Skip $keep | Remove-Item -Force -ErrorAction SilentlyContinue
                if (-not $Quiet) { Write-VmmLog "Backup: $dest (kept: $([math]::Min($existing.Count, $keep)))" -Level Success } else { Write-VmmLog "Backup: $dest" -Level Muted -FileOnly }
                if ($PassThru) { $dest }
            }
        }
        'ListBackups' {
            $bk = @(Get-ChildItem -LiteralPath $bdir -Filter 'fleet_*.vmm' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if (-not $bk) { Write-VmmLog 'No backups yet.' -Level Muted; return }
            $rows = foreach ($f in $bk) {
                $n = try { @((& $testStore $f.FullName).Hosts).Count } catch { 'damaged' }
                [pscustomobject]@{ File = $f.Name; Saved = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); KB = [math]::Round($f.Length / 1KB, 1); Hosts = $n }
            }
            if ($PassThru) { return $rows }
            $rows | Format-Table -AutoSize | Out-VmmHost
        }
        'Restore' {
            if (-not $BackupFile) {
                throw (New-VmmErrorRecord -Activity 'Which backup?' -Fix 'vmm maint -Action ListBackups, then -Action Restore -BackupFile <name>' -Category InvalidArgument)
            }
            $src = if (Test-Path -LiteralPath $BackupFile) { $BackupFile } else { Join-Path $bdir ([IO.Path]::GetFileName($BackupFile)) }
            if (-not (Test-Path -LiteralPath $src)) { throw (New-VmmErrorRecord -Activity 'Backup not found.' -Target $src -Fix 'vmm maint -Action ListBackups' -Category ObjectNotFound) }
            $s = & $testStore $src   # refuses a damaged or foreign file before anything changes
            if ($PSCmdlet.ShouldProcess($store, "Replace the fleet store with $([IO.Path]::GetFileName($src)) ($(@($s.Hosts).Count) hosts)")) {
                if (Test-Path -LiteralPath $store) { Copy-Item -LiteralPath $store -Destination "$store.before-restore" -Force }
                Copy-Item -LiteralPath $src -Destination $store -Force
                $script:VmmProgCache = $null
                Write-VmmLog ("Restored {0} ({1} host(s)). The store it replaced: {2}.before-restore" -f [IO.Path]::GetFileName($src), @($s.Hosts).Count, $store) -Level Success
            }
        }
        'CleanLogs' {
            $keepDays = if ($All) { 0 } else { -1 }
            if ($PSCmdlet.ShouldProcess((Get-VmmPath -Name Logs), $(if ($All) { 'Delete all day logs except today' } else { 'Delete day logs older than Log.KeepDays' }))) {
                $gone = @(Remove-VmmOldLog -KeepDays $keepDays)
                Write-VmmLog ("{0} old log file(s) deleted." -f $gone.Count) -Level Success
            }
        }
        'CleanTemp' {
            $cut = (Get-Date).AddDays(-1)
            $files = @()
            $files += @(Get-ChildItem -LiteralPath (Get-VmmPath -Name Agents) -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut })
            $files += @(Get-ChildItem -LiteralPath (Join-Path (Get-VmmPath -Name Reports) 'Logs') -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut })
            $files += @(Get-ChildItem -LiteralPath $dataDir -Filter '*.tmp' -File -ErrorAction SilentlyContinue)
            $files += @(Get-ChildItem -LiteralPath (Get-VmmPath -Name Logs) -Filter '*.old' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) })
            if (-not $files) { Write-VmmLog 'Nothing to clean.' -Level Success; return }
            if ($PSCmdlet.ShouldProcess("$($files.Count) file(s)", 'Delete leftover temp files')) {
                foreach ($f in $files) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; Write-VmmLog "deleted $($f.Name)" -Level Muted }
                Write-VmmLog "$($files.Count) leftover file(s) deleted." -Level Success
            }
        }
        'ResetUi' {
            $script:VmmProgCache = $null
            $script:VmmLogLive = $null
            if ($script:VmmLogBuffer) { $script:VmmLogBuffer.Clear() }
            $script:VmmLogSeq = 1 + [int]$script:VmmLogSeq
            Write-VmmLog 'UI caches and the on-screen log cleared (log files kept).' -Level Success
        }
    }
}
