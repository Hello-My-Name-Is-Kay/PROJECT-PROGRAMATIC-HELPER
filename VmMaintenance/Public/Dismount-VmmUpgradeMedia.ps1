function Dismount-VmmUpgradeMedia {
    <#
    .SYNOPSIS
        Detaches the <VM>-<DiskSuffix> upgrade-media disk from each VM and deletes it.
    .DESCRIPTION
        A disk still attached to another VM is never deleted. Ends with a verification view:
        both lists should come back empty.
    .EXAMPLE
        Dismount-VmmUpgradeMedia -WhatIf
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
        [string]$DiskSuffix
    )
    if (-not $PSBoundParameters.ContainsKey('ResourceGroup')) { $ResourceGroup = Get-VmmSetting 'Azure.ResourceGroup' -Required }
    if (-not $PSBoundParameters.ContainsKey('Subscription'))  { $Subscription  = Get-VmmSetting 'Azure.Subscription' }
    if (-not $PSBoundParameters.ContainsKey('TenantId'))      { $TenantId      = Get-VmmSetting 'Azure.TenantId' }
    if (-not $PSBoundParameters.ContainsKey('DiskSuffix'))    { $DiskSuffix    = Get-VmmSetting 'UpgradeMedia.DiskSuffix' -Default 'Upgrade2019' }

    $names = @(Read-VmmServerList -Name $VMName -Path $ServerList -ListKey 'UpgradeMedia' -Case Keep -KeepDomain)
    if (-not $WhatIfPreference) { Assert-VmmWindow -Class Change -Target "upgrade media on $($names -join ', ')" -Override:$Override -OverrideReason $OverrideReason }
    Assert-VmmModule -Name 'Az.Accounts', 'Az.Compute'
    Connect-VmmAzure -TenantId $TenantId -Subscription $Subscription

    $bad = New-Object System.Collections.Generic.List[string]   # VMs whose media disk is still there
    foreach ($n in $names) {
        $diskName = "$n-$DiskSuffix"

        try {
            $vm = Get-AzVM -ResourceGroupName $ResourceGroup -Name $n -ErrorAction Stop
            if ($vm.StorageProfile.DataDisks | Where-Object Name -eq $diskName) {
                if ($PSCmdlet.ShouldProcess($n, "Detach $diskName")) {
                    Remove-AzVMDataDisk -VM $vm -DataDiskNames $diskName | Out-Null
                    Update-AzVM -ResourceGroupName $ResourceGroup -VM $vm -ErrorAction Stop | Out-Null
                    Write-VmmLog "$n : $diskName detached" -Level Success
                }
            } else {
                Write-VmmLog "$n : $diskName not attached" -Level Muted
            }
        } catch {
            Write-VmmLog ("$n : " + (ConvertTo-VmmNote -Activity "Detach of $diskName" -ErrorRecord $_)) -Level Error
            $bad.Add("$($n): detach failed")
            continue   # never delete a disk we could not confirm as detached
        }

        $disk = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $diskName -ErrorAction SilentlyContinue
        if ($disk -and -not $disk.ManagedBy) {
            if ($PSCmdlet.ShouldProcess($diskName, 'Delete disk')) {
                try {
                    Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $diskName -Force -ErrorAction Stop | Out-Null
                    Write-VmmLog "$n : $diskName deleted" -Level Success
                } catch {
                    Write-VmmLog ("$n : " + (ConvertTo-VmmNote -Activity "Delete of $diskName" -ErrorRecord $_)) -Level Error
                    $bad.Add("$($n): delete of $diskName failed")
                }
            }
        } elseif ($disk) {
            Write-VmmLog "$n : $diskName still attached to $(($disk.ManagedBy -split '/')[-1]) - skipped" -Level Error
            $bad.Add("$($n): $diskName attached to another VM")
        }
    }

    # Verify: both lists should come back empty
    Get-VmmUpgradeMediaState -ResourceGroup $ResourceGroup -VMName $names -DiskSuffix $DiskSuffix
    if ($bad.Count) {
        throw (New-VmmErrorRecord -Activity "Upgrade media not removed on $($bad.Count) of $($names.Count) VM(s)." -Target ($bad -join ' | ') `
            -Fix 'See the errors above; fix them and run it again (it only removes what is still there).' -Category InvalidResult -ErrorId 'VmmMediaIncomplete')
    }
}
