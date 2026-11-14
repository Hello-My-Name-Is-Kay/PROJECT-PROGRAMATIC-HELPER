function Get-VmmMediaReport {
    <#
    .SYNOPSIS
        Shows the media repository: Windows Server images by version and language, the per-host
        folders (and whether each host is in your fleet), and what the fleet still needs downloaded.
    .DESCRIPTION
        Read-only. Layout expected under Staging.SourceShare:
            Win_Server_2019_EN_US.iso, Win_Server_2019_FR_FR.iso ...   OS images at the root
            <HOST>\SQLServer2016SP3-KB5003279-x64-FRA.exe ...          files for one host only
        Optional <file>.sha256 next to any file holds its SHA256; staging then verifies it.
    .EXAMPLE
        Get-VmmMediaReport
    .EXAMPLE
        vmm media
    #>
    [CmdletBinding()]
    param([switch]$PassThru)
    $inv = Get-VmmMediaInventory
    $ver = "$(Get-VmmSetting 'Staging.OsMediaVersion' -Default '2019')".ToUpper()
    $fleet = @(try { @((Read-VmmStore).Hosts | ForEach-Object { $_.Name }) } catch { })
    $alias = Get-VmmSetting 'Staging.HostFolders' -Default @{}
    $folderOf = @{}
    foreach ($h in $fleet) { $folderOf[$(if ($alias -is [System.Collections.IDictionary] -and $alias[$h]) { "$($alias[$h])".ToUpper() } else { $h.ToUpper() })] = $h }

    Write-VmmLog "Media repository: $($inv.Share)" -Level Info
    Write-VmmLog "OS images ($($inv.Isos.Count)); upgrade target $ver" -Level Info
    $inv.Isos | Sort-Object Version, Lang | Format-Table @{ n = 'Target'; e = { if ($_.Version -eq $ver) { '*' } else { '' } } }, Version, Lang, SizeMB,
        @{ n = 'Sha256'; e = { if ($_.Sha256) { 'sidecar' } else { '-' } } }, Name -AutoSize | Out-Host
    if (-not @($inv.Isos | Where-Object { $_.Version -eq $ver })) { Write-VmmLog "No Windows Server $ver image on the share yet (expected name: Win_Server_$($ver)_EN_US.iso and one per host language)." -Level Warn }

    $fold = foreach ($f in $inv.Folders) {
        $h = $folderOf[$f.Name.ToUpper()]
        [pscustomobject]@{ Folder = $f.Name; Files = $f.Files.Count; SizeMB = [math]::Round((@($f.Files | ForEach-Object SizeMB) | Measure-Object -Sum).Sum, 1)
                           InFleet = $(if ($h) { 'Yes' } else { 'No' }); List = (@($f.Files | ForEach-Object Name) -join ', ') }
    }
    Write-VmmLog "Host folders ($(@($fold).Count))" -Level Info
    if ($fold) { $fold | Format-Table Folder, InFleet, Files, SizeMB, List -AutoSize -Wrap | Out-Host }
    foreach ($f in @($fold | Where-Object { $_.InFleet -eq 'No' })) { Write-VmmLog "Folder '$($f.Folder)' matches no host in your fleet (typo, not imported yet, or set an alias in Staging.HostFolders)." -Level Warn }
    foreach ($o in $inv.Other) { Write-VmmLog "Not recognised at the root: '$o' (OS images must be named like Win_Server_2019_EN_US.iso - Staging.OsMediaPattern)." -Level Warn }

    $need = @(try { Test-VmmStagingSource -PassThru -Quiet } catch { Write-VmmLog $_.Exception.Message -Level Error })
    $gates = @($need | Where-Object { $_.Gate })
    if ($gates) { Write-VmmLog 'Still needed for your fleet:' -Level Warn; foreach ($g in $gates) { Write-VmmLog "  $($g.Gate)$(if ($g.Hosts) { " [hosts: $($g.Hosts)]" })" -Level Error } }
    elseif ($need) { Write-VmmLog "Everything your workable hosts need is on the share ($($need.Count) file(s))." -Level Success }
    foreach ($n in @($need | Where-Object { $_.Note })) { Write-VmmLog "  $($n.Name): $($n.Note)" -Level Warn }
    Write-VmmLog 'SQL Server updates per host (download once, copy to the host folders): vmm fetch -Preview, or F on the staging screen.' -Level Muted
    if ($PassThru) { [pscustomobject]@{ Inventory = $inv; Folders = @($fold); Needed = $need } }
}
