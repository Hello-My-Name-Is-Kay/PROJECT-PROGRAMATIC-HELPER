function New-VmmDiskFromSnapshot {
    <#
    .SYNOPSIS
        Rollback helper: creates managed disks from a VM's <VM>_OsDisk_snap / <VM>_DataDisk_<n>_snap
        snapshots (the newest one of each, when stamped copies exist).
    .DESCRIPTION
        Disks are named <VM>-OSDisk and <VM>-DataDisk-<n>. An existing disk with that name is never
        touched. The disks are created only; swap them onto the VM yourself (portal: Disks > Swap
        OS disk, or Set-AzVMOSDisk) once you have checked them.
    .EXAMPLE
        New-VmmDiskFromSnapshot -VMName vm01 -WhatIf
    .EXAMPLE
        New-VmmDiskFromSnapshot -VMName vm01 -ResourceGroup rg-x -SkuName Premium_LRS
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string[]]$VMName,
        [string]$ResourceGroup,
        [string]$Subscription,
        [string]$TenantId,
        [string]$Location,
        [string]$SkuName = 'Standard_LRS',
        [switch]$PassThru
    )
    if (-not $PSBoundParameters.ContainsKey('ResourceGroup')) { $ResourceGroup = Get-VmmSetting 'Azure.ResourceGroup' -Required }
    if (-not $PSBoundParameters.ContainsKey('Subscription'))  { $Subscription  = Get-VmmSetting 'Azure.Subscription' -Required }
    if (-not $PSBoundParameters.ContainsKey('TenantId'))      { $TenantId      = Get-VmmSetting 'Azure.TenantId' }

    $names = @(Read-VmmServerList -Name $VMName -ListKey 'Snapshot' -Case Keep -KeepDomain)
    Assert-VmmModule -Name 'Az.Accounts', 'Az.Compute'
    Connect-VmmAzure -TenantId $TenantId -Subscription $Subscription

    try { $snaps = @(Get-AzSnapshot -ResourceGroupName $ResourceGroup -ErrorAction Stop) }
    catch { throw (New-VmmErrorRecord -Activity 'Could not list snapshots.' -Target "resource group $ResourceGroup" -Exception $_.Exception -Category ReadError) }

    $stampRx = '(_\d{8}-\d{6})?$'
    $results = foreach ($vm in $names) {
        Write-VmmLog "`n=== $vm ===" -Level Info
        $esc  = [regex]::Escape($vm)
        $jobs = @()

        $os = $snaps | Where-Object { $_.Name -match "^${esc}_OsDisk_snap$stampRx" } |
              Sort-Object TimeCreated -Descending | Select-Object -First 1
        if ($os) { $jobs += [pscustomobject]@{ Snapshot = $os; DiskName = "$vm-OSDisk" } }

        $snaps | Where-Object { $_.Name -match "^${esc}_DataDisk_(\d+)_snap$stampRx" } |
            Group-Object { [int]([regex]::Match($_.Name, '_DataDisk_(\d+)_snap').Groups[1].Value) } |
            Sort-Object { [int]$_.Name } |
            ForEach-Object {
                $newest = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
                $jobs  += [pscustomobject]@{ Snapshot = $newest; DiskName = "$vm-DataDisk-$($_.Name)" }
            }

        if (-not $jobs) {
            Write-VmmLog "No snapshots named ${vm}_OsDisk_snap or ${vm}_DataDisk_<n>_snap in $ResourceGroup - nothing to restore." -Level Error
            [pscustomobject][ordered]@{ VMName = $vm; Snapshot = ''; Disk = ''; Result = 'Failed: no snapshot found' }
            continue
        }

        foreach ($j in $jobs) {
            $row = [ordered]@{ VMName = $vm; Snapshot = $j.Snapshot.Name; Disk = $j.DiskName; Result = $null }
            if (Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $j.DiskName -ErrorAction SilentlyContinue) {
                $row.Result = 'Skipped: disk exists'
                Write-VmmLog "$($j.DiskName) already exists in $ResourceGroup - skipped. Delete or rename it first if you need a fresh copy." -Level Warn
                [pscustomobject]$row; continue
            }
            $loc = if ($Location) { $Location } else { $j.Snapshot.Location }
            if (-not $PSCmdlet.ShouldProcess($j.DiskName, "Create $SkuName disk from $($j.Snapshot.Name)")) {
                $row.Result = 'WhatIf'; [pscustomobject]$row; continue
            }
            try {
                $cfg = New-AzDiskConfig -Location $loc -CreateOption Copy -SourceResourceId $j.Snapshot.Id -SkuName $SkuName
                New-AzDisk -ResourceGroupName $ResourceGroup -DiskName $j.DiskName -Disk $cfg -ErrorAction Stop | Out-Null
                $row.Result = 'Created'
                Write-VmmLog "$($j.DiskName) created from $($j.Snapshot.Name)" -Level Success
            } catch {
                $row.Result = 'Failed'
                Write-VmmLog (ConvertTo-VmmNote -Activity "Disk $($j.DiskName) from $($j.Snapshot.Name)" -ErrorRecord $_) -Level Error
            }
            [pscustomobject]$row
        }
    }
    $results = @($results)
    if ($results) { $results | Format-Table -AutoSize | Out-VmmHost }
    if ($PassThru) { $results }
    $failedRows = @($results | Where-Object { "$($_.Result)" -like 'Failed*' })
    if ($failedRows) {
        throw (New-VmmErrorRecord -Activity "$($failedRows.Count) disk(s) not created from snapshots." -Target (@($failedRows | ForEach-Object { if ($_.Disk) { $_.Disk } else { "$($_.VMName) (no snapshot)" } }) -join ', ') `
            -Fix 'See the errors above, then run it again (disks that exist are skipped).' -Category InvalidResult -ErrorId 'VmmRestoreDiskIncomplete')
    }
}
