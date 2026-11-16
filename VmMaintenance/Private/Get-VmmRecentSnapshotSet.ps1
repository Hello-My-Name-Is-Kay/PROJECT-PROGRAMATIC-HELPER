function Get-VmmRecentSnapshotSet {
    # Is there a full, recent snapshot set of this Azure VM? Counts every snapshot whose source is one of the
    # VM's managed disks (taken by vmm, a script or by hand in the portal) and created within -MaxAgeMinutes.
    # Complete = every managed disk (OS + data) has one. Read-only: lists, never creates or deletes.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$Subscription,
        [int]$MaxAgeMinutes = 60,
        [datetime]$Now = (Get-Date)
    )
    if ($Subscription) { Set-VmmSubscription -Subscription $Subscription }
    $found = @(Get-AzVM -Name $VMName -ErrorAction Stop)
    if ($found.Count -ne 1) {
        throw (New-VmmErrorRecord -Activity "Cannot check recent snapshots of $VMName." -Target $VMName `
            -Cause $(if ($found.Count) { "Found in $($found.Count) resource groups." } else { 'VM not found in the selected subscription.' }) `
            -Fix 'Check the Azure mapping of this host (vmm azure) and Azure.Subscription.' -Category ObjectNotFound -ErrorId 'VmmSnapshotCheck')
    }
    $vm = Get-AzVM -ResourceGroupName $found[0].ResourceGroupName -Name $found[0].Name -ErrorAction Stop
    $disks = @(@($vm.StorageProfile.OsDisk) + @($vm.StorageProfile.DataDisks) | Where-Object { $_ -and $_.ManagedDisk -and $_.ManagedDisk.Id })
    $since = $Now.ToUniversalTime().AddMinutes(-$MaxAgeMinutes)
    $snaps = @(Get-AzSnapshot -ErrorAction Stop | Where-Object {
        $_.CreationData -and $_.CreationData.SourceResourceId -and $_.TimeCreated -and ([datetime]$_.TimeCreated).ToUniversalTime() -ge $since
    })
    $newest = $null; $missing = @(); $used = @()
    foreach ($d in $disks) {
        $id = "$($d.ManagedDisk.Id)"
        $hit = @($snaps | Where-Object { "$($_.CreationData.SourceResourceId)" -eq $id } | Sort-Object { ([datetime]$_.TimeCreated).ToUniversalTime() } -Descending | Select-Object -First 1)
        if (-not $hit) { $missing += ($id -split '/')[-1]; continue }
        $used += $hit[0].Name
        $t = ([datetime]$hit[0].TimeCreated).ToUniversalTime()
        if (-not $newest -or $t -gt $newest) { $newest = $t }
    }
    $unmanaged = @(@($vm.StorageProfile.OsDisk) + @($vm.StorageProfile.DataDisks) | Where-Object { $_ -and -not ($_.ManagedDisk -and $_.ManagedDisk.Id) }).Count
    [pscustomobject]@{
        VMName        = $vm.Name
        Disks         = $disks.Count
        Complete      = ($disks.Count -gt 0 -and -not $missing -and -not $unmanaged)
        Missing       = $missing
        Snapshots     = $used
        Newest        = $newest
        MaxAgeMinutes = $MaxAgeMinutes
    }
}
