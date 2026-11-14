function Get-VmmDiskDescriptor {
    # Type + GB for one VM disk reference; handles managed and legacy unmanaged (VHD) disks.
    # -DiskById: the subscription's managed disks indexed by lower-case resource id.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DiskRef,
        [Parameter(Mandatory)][hashtable]$DiskById
    )
    if ($DiskRef.ManagedDisk -and $DiskRef.ManagedDisk.Id) {
        $md = $DiskById[$DiskRef.ManagedDisk.Id.ToLower()]
        if ($md) { return @{ Type = Get-VmmDiskTypeName $md.Sku.Name; GB = $md.DiskSizeGB } }
        return @{ Type = Get-VmmDiskTypeName $DiskRef.ManagedDisk.StorageAccountType; GB = $DiskRef.DiskSizeGB }
    }
    @{ Type = 'Unmanaged (VHD)'; GB = $DiskRef.DiskSizeGB }
}
