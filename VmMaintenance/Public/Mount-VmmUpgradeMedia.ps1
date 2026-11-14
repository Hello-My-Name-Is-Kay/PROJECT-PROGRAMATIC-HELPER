function Mount-VmmUpgradeMedia {
    <#
    .SYNOPSIS
        Creates a Windows Server upgrade-media disk from the Azure marketplace image and attaches it
        to each VM as a data disk (the "mount ISO" step of an in-place upgrade).
    .DESCRIPTION
        Disk name: <VM>-<DiskSuffix>, at LUN UpgradeMedia.Lun. Image: UpgradeMedia.Publisher /
        Offer / Sku, latest version, looked up once per region. Skips a VM when the disk is already
        attached or the LUN is taken; reuses an existing unattached disk of the same name.
    .EXAMPLE
        Mount-VmmUpgradeMedia -WhatIf
    .EXAMPLE
        Mount-VmmUpgradeMedia -VMName vm01, vm02
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$VMName,
        [string]$ServerList,
        [string]$ResourceGroup,
        [string]$Subscription,
        [string]$TenantId,
        [switch]$Override,
        [string]$OverrideReason,
        [string]$Publisher,
        [string]$Offer,
        [string]$Sku,
        [string]$DiskSuffix,
        [int]$Lun,
        [string]$SkuName
    )
    if (-not $PSBoundParameters.ContainsKey('ResourceGroup')) { $ResourceGroup = Get-VmmSetting 'Azure.ResourceGroup' -Required }
    if (-not $PSBoundParameters.ContainsKey('Subscription'))  { $Subscription  = Get-VmmSetting 'Azure.Subscription' }
    if (-not $PSBoundParameters.ContainsKey('TenantId'))      { $TenantId      = Get-VmmSetting 'Azure.TenantId' }
    if (-not $PSBoundParameters.ContainsKey('Publisher'))     { $Publisher     = Get-VmmSetting 'UpgradeMedia.Publisher'  -Default 'MicrosoftWindowsServer' }
    if (-not $PSBoundParameters.ContainsKey('Offer'))         { $Offer         = Get-VmmSetting 'UpgradeMedia.Offer'      -Default 'WindowsServerUpgrade' }
    if (-not $PSBoundParameters.ContainsKey('Sku'))           { $Sku           = Get-VmmSetting 'UpgradeMedia.Sku'        -Default 'server2019Upgrade' }
    if (-not $PSBoundParameters.ContainsKey('DiskSuffix'))    { $DiskSuffix    = Get-VmmSetting 'UpgradeMedia.DiskSuffix' -Default 'Upgrade2019' }
    if (-not $PSBoundParameters.ContainsKey('Lun'))           { $Lun           = Get-VmmSetting 'UpgradeMedia.Lun'        -Default 10 }
    if (-not $PSBoundParameters.ContainsKey('SkuName'))       { $SkuName       = Get-VmmSetting 'UpgradeMedia.SkuName'    -Default 'Standard_LRS' }

    $names = @(Read-VmmServerList -Name $VMName -Path $ServerList -ListKey 'UpgradeMedia' -Case Keep -KeepDomain)
    if (-not $WhatIfPreference) { Assert-VmmWindow -Class Change -Target "upgrade media on $($names -join ', ')" -Override:$Override -OverrideReason $OverrideReason }
    Assert-VmmModule -Name 'Az.Accounts', 'Az.Compute'
    Connect-VmmAzure -TenantId $TenantId -Subscription $Subscription

    $imageCache = @{}
    foreach ($n in $names) {
        $diskName = "$n-$DiskSuffix"
        try { $vm = Get-AzVM -ResourceGroupName $ResourceGroup -Name $n -ErrorAction Stop }
        catch { Write-VmmLog ("$n : " + (ConvertTo-VmmNote -Activity "VM lookup in $ResourceGroup" -ErrorRecord $_)) -Level Error; continue }

        $attached = $vm.StorageProfile.DataDisks | Where-Object Name -eq $diskName
        if ($attached) { Write-VmmLog "$n : $diskName already attached at LUN $($attached.Lun) - skipped" -Level Muted; continue }

        $lunUser = $vm.StorageProfile.DataDisks | Where-Object Lun -eq $Lun
        if ($lunUser) {
            Write-VmmLog "$n : LUN $Lun is already used by '$($lunUser.Name)' - skipped. Pick a free LUN with -Lun or UpgradeMedia.Lun." -Level Error
            continue
        }

        try { $img = Get-VmmUpgradeImage -Location $vm.Location -Publisher $Publisher -Offer $Offer -Sku $Sku -Cache $imageCache }
        catch { Write-VmmLog "$n : $($_.Exception.Message)" -Level Error; continue }

        if (-not $PSCmdlet.ShouldProcess($n, "Create $diskName from $Sku image and attach at LUN $Lun")) { continue }

        $stage = 'check existing disk'
        try {
            $disk = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $diskName -ErrorAction SilentlyContinue
            if ($disk -and $disk.ManagedBy) {
                Write-VmmLog "$n : $diskName exists and is attached to $(($disk.ManagedBy -split '/')[-1]) - skipped. Detach it there first." -Level Error
                continue
            }
            if (-not $disk) {
                $stage = 'create disk from image'
                $cfg  = New-AzDiskConfig -SkuName $SkuName -CreateOption FromImage -Location $vm.Location
                $cfg  = Set-AzDiskImageReference -Disk $cfg -Id $img.Id -Lun 0
                $disk = New-AzDisk -ResourceGroupName $ResourceGroup -DiskName $diskName -Disk $cfg -ErrorAction Stop
            } else {
                Write-VmmLog "$n : reusing existing unattached $diskName" -Level Muted
            }
            $stage = 'attach disk to VM'
            Add-AzVMDataDisk -VM $vm -Name $disk.Name -ManagedDiskId $disk.Id -Lun $Lun -CreateOption Attach | Out-Null
            Update-AzVM -ResourceGroupName $ResourceGroup -VM $vm -ErrorAction Stop | Out-Null
            Write-VmmLog "$n : $($disk.Name) attached" -Level Success
        } catch {
            Write-VmmLog ("$n : " + (ConvertTo-VmmNote -Activity $stage -ErrorRecord $_)) -Level Error
        }
    }

    Get-VmmUpgradeMediaState -ResourceGroup $ResourceGroup -VMName $names -DiskSuffix $DiskSuffix
}
