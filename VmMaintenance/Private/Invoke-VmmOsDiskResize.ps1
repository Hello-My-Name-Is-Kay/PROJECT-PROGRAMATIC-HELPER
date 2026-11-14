function Invoke-VmmOsDiskResize {
    # Snapshot (rollback copy, tagged) then resize one deallocated VM's OS disk. SKU is not changed.
    # Sets Status = Resized, or Failed with the failing stage in Notes.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][hashtable]$Tags,
        [Parameter(Mandatory)][string]$Stamp,
        [string]$SkuName = 'Standard_LRS'
    )
    $p = $Item
    $stage = 'read OS disk'
    try {
        Set-VmmSubscription -Subscription $p.SubscriptionId
        $disk = Get-AzDisk -ResourceGroupName $p.DiskRG -DiskName $p.DiskName -ErrorAction Stop

        # Never overwrite an existing snapshot
        $stage = 'snapshot OS disk'
        $snap  = Get-VmmUniqueSnapshotName -ResourceGroup $p.DiskRG -BaseName "$($p.VMName)_OsDisk_snap" -Stamp $Stamp
        if ($snap.Renamed) { $p.Notes += "Existing snapshot found, used $($snap.Name); " }
        Write-VmmLog "[Snapshot] $($snap.Name)" -Level Info
        $cfg = New-AzSnapshotConfig -SourceUri $disk.Id -Location $disk.Location -CreateOption Copy -SkuName $SkuName -Tag $Tags
        New-AzSnapshot -ResourceGroupName $p.DiskRG -SnapshotName $snap.Name -Snapshot $cfg -ErrorAction Stop | Out-Null
        $p.Snapshot = $snap.Name

        # Only the size changes; the SKU stays as it was
        $stage = 'resize OS disk'
        Write-VmmLog "[Resize]   $($p.DiskName): $($p.CurrentGB) -> $($p.NewGB) GB ($($disk.Sku.Name))" -Level Info
        $disk.DiskSizeGB = $p.NewGB
        Update-AzDisk -ResourceGroupName $p.DiskRG -DiskName $p.DiskName -Disk $disk -ErrorAction Stop | Out-Null
        $p.Status = 'Resized'
    } catch {
        $p.Status = 'Failed'
        $p.Notes += (ConvertTo-VmmNote -Activity "$stage ($($p.DiskRG)/$($p.DiskName))" -ErrorRecord $_) + '; '
        Write-VmmLog "$($p.VMName): could not $stage $($p.DiskRG)/$($p.DiskName) - $($_.Exception.Message)" -Level Error
    }
}
