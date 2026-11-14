function New-VmmSnapshot {
    <#
    .SYNOPSIS
        Pre-upgrade rollback copies: snapshots the OS disk and every data disk of each VM, tagged.
    .DESCRIPTION
        Each VM's resource group is looked up in the selected subscription. Snapshots go to the VM's
        resource group as <VM>_OsDisk_snap and <VM>_DataDisk_<n>_snap (n = position in the VM's data
        disk list). An existing snapshot is never overwritten: the run stamp is appended instead.
        The VM's current tags are saved to <WorkDir>\Snapshots\<VM>_tags_preupgrade_<time>.json.
        A manifest CSV lists every snapshot created (VM, disk, LUN, snapshot name).
        Tip: snapshot while VMs are deallocated for clean copies, then start them.
    .EXAMPLE
        New-VmmSnapshot -WhatIf
    .EXAMPLE
        New-VmmSnapshot -VMName vm01, vm02
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$VMName,
        [string]$ServerList,
        [string]$Subscription,
        [string]$TenantId,
        [hashtable]$Tags,
        [string]$SkuName,
        [string]$OutCsv,
        [string]$Label,          # e.g. 'pre' or 'cp-ExpandDisk' -> <VM>_<Label>_OsDisk_snap
        [hashtable]$ExtraTags,   # merged over Snapshots.Tags (e.g. Checkpoint, RetentionDays)
        [switch]$PassThru
    )
    if (-not $PSBoundParameters.ContainsKey('Subscription')) { $Subscription = Get-VmmSetting 'Azure.Subscription' -Required }
    if (-not $PSBoundParameters.ContainsKey('TenantId'))     { $TenantId     = Get-VmmSetting 'Azure.TenantId' }
    if (-not $PSBoundParameters.ContainsKey('Tags'))         { $Tags         = Get-VmmSetting 'Snapshots.Tags' -Required }
    if (-not $PSBoundParameters.ContainsKey('SkuName'))      { $SkuName      = Get-VmmSetting 'Snapshots.SkuName' -Default 'Standard_LRS' }

    $Tags = $Tags.Clone()
    if ($ExtraTags) { foreach ($k in $ExtraTags.Keys) { $Tags[$k] = [string]$ExtraTags[$k] } }
    $mid = if ($Label) { "_$Label" } else { '' }

    $names = @(Read-VmmServerList -Name $VMName -Path $ServerList -ListKey 'Snapshot' -Case Keep -KeepDomain)
    Assert-VmmModule -Name 'Az.Accounts', 'Az.Compute'
    Connect-VmmAzure -TenantId $TenantId -Subscription $Subscription

    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $workDir = Resolve-VmmWorkDir -SubFolder 'Snapshots'
    $created = New-Object System.Collections.Generic.List[object]
    $failed  = 0

    foreach ($n in $names) {
        Write-VmmLog "`n=== $n ===" -Level Info

        try { $found = @(Get-AzVM -Name $n -ErrorAction Stop) }
        catch { Write-VmmLog (ConvertTo-VmmNote -Activity "VM lookup of $n" -ErrorRecord $_) -Level Error; $failed++; continue }
        if ($found.Count -eq 0) {
            Write-VmmLog "$n not found in subscription '$((Get-AzContext).Subscription.Name)' - skipped. Check the name or Azure.Subscription." -Level Warn
            continue
        }
        if ($found.Count -gt 1) {
            Write-VmmLog "$n exists in several resource groups ($(($found.ResourceGroupName) -join ', ')) - skipped. Snapshot it by hand." -Level Warn
            continue
        }

        try {
            $vm    = Get-AzVM -ResourceGroupName $found[0].ResourceGroupName -Name $found[0].Name -ErrorAction Stop
            $state = Get-VmmPowerState -ResourceGroup $vm.ResourceGroupName -VMName $vm.Name
        } catch { Write-VmmLog (ConvertTo-VmmNote -Activity "Read of VM $n" -ErrorRecord $_) -Level Error; $failed++; continue }

        $rg = $vm.ResourceGroupName
        Write-VmmLog "Resource group: $rg | Power state: $state"
        if ($state -eq 'running') { Write-VmmLog "$($vm.Name) is running - snapshots are crash-consistent only. Deallocate first for clean copies." -Level Warn }

        # Save current tags
        $tagFile = Join-Path $workDir "$($vm.Name)_tags_preupgrade_$stamp.json"
        try { $vm.Tags | ConvertTo-Json | Out-File -LiteralPath $tagFile -Encoding UTF8 -ErrorAction Stop }
        catch { Write-VmmLog "Could not save tags to $tagFile - $($_.Exception.Message)" -Level Warn }

        # OS disk first, then data disks in the VM's list order
        $targets = @([pscustomobject]@{ Kind = 'OS'; Ref = $vm.StorageProfile.OsDisk; Base = "$($vm.Name)$($mid)_OsDisk_snap"; Lun = $null })
        $i = 0
        foreach ($dd in $vm.StorageProfile.DataDisks) {
            $targets += [pscustomobject]@{ Kind = "Data disk $i"; Ref = $dd; Base = "$($vm.Name)$($mid)_DataDisk_$($i)_snap"; Lun = $dd.Lun }
            $i++
        }

        foreach ($t in $targets) {
            if (-not ($t.Ref.ManagedDisk -and $t.Ref.ManagedDisk.Id)) {
                Write-VmmLog "$($vm.Name): $($t.Kind) '$($t.Ref.Name)' is unmanaged (VHD) - cannot be snapshotted here. Copy the VHD blob by hand." -Level Error
                $failed++; continue
            }
            $diskName = ($t.Ref.ManagedDisk.Id -split '/')[8]
            try {
                $snap = Get-VmmUniqueSnapshotName -ResourceGroup $rg -BaseName $t.Base -Stamp $stamp
                if (-not $PSCmdlet.ShouldProcess($diskName, "Snapshot to $rg/$($snap.Name)")) { continue }
                $cfg = New-AzSnapshotConfig -SourceUri $t.Ref.ManagedDisk.Id -Location $vm.Location -CreateOption Copy -SkuName $SkuName -Tag $Tags
                New-AzSnapshot -ResourceGroupName $rg -SnapshotName $snap.Name -Snapshot $cfg -ErrorAction Stop | Out-Null
                $msg = "$($t.Kind) snapshot created: $($snap.Name) ($diskName)"
                if ($snap.Renamed) { $msg += ' - base name was taken, stamp appended' }
                Write-VmmLog $msg -Level Success
                $created.Add([pscustomobject]@{
                    VMName = $vm.Name; ResourceGroup = $rg; Kind = $t.Kind; Lun = $t.Lun; Disk = $diskName
                    Snapshot = $snap.Name; PowerState = $state; Created = (Get-Date -Format 's')
                })
            } catch {
                $failed++
                Write-VmmLog ("$($vm.Name): " + (ConvertTo-VmmNote -Activity "Snapshot of $($t.Kind) $diskName" -ErrorRecord $_)) -Level Error
            }
        }
    }

    # Verify
    Write-VmmLog "`n=== Snapshot verification ===" -Level Info
    try {
        $allSnaps = @(Get-AzSnapshot -ErrorAction Stop)
        $(foreach ($n in $names) {
            $allSnaps | Where-Object { $_.Name -like "${n}_*" } |
                Select-Object Name, ResourceGroupName, DiskSizeGB, ProvisioningState, TimeCreated
        }) | Format-Table -AutoSize | Out-Host
    } catch { Write-VmmLog (ConvertTo-VmmNote -Activity 'Snapshot listing' -ErrorRecord $_) -Level Warn }

    if ($created.Count) { Export-VmmCsv -InputObject $created.ToArray() -Path (Resolve-VmmOutputPath -Path $OutCsv -BaseName 'SnapshotManifest') }
    if ($failed) { Write-VmmLog "$failed disk/VM step(s) failed - see errors above." -Level Error }
    else { Write-VmmLog "$($created.Count) snapshot(s) created." -Level Success }
    if ($PassThru) { $created.ToArray() }
}
