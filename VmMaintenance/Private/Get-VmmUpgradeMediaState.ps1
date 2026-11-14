function Get-VmmUpgradeMediaState {
    # Verification view after mount/unmount: which VMs have a *<DiskSuffix>* data disk attached,
    # plus every *<DiskSuffix>* disk left in the resource group.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string[]]$VMName,
        [Parameter(Mandatory)][string]$DiskSuffix
    )
    Write-VmmLog "`n=== Verification ===" -Level Info
    $rows = foreach ($n in $VMName) {
        try {
            $v = Get-AzVM -ResourceGroupName $ResourceGroup -Name $n -ErrorAction Stop
            $d = @($v.StorageProfile.DataDisks | Where-Object Name -like "*$DiskSuffix*")
            [pscustomobject]@{ VMName = $n; AttachedDisk = ($d.Name -join ', '); Lun = ($d.Lun -join ', ') }
        } catch {
            [pscustomobject]@{ VMName = $n; AttachedDisk = '(VM read failed)'; Lun = $null }
        }
    }
    $rows | Format-Table -AutoSize | Out-Host

    try {
        $left = @(Get-AzDisk -ResourceGroupName $ResourceGroup -ErrorAction Stop | Where-Object Name -like "*$DiskSuffix*")
        if ($left) { $left | Select-Object Name, DiskState, ManagedBy | Format-Table -AutoSize | Out-Host }
        else { Write-VmmLog "No *$DiskSuffix* disks in $ResourceGroup" -Level Muted }
    } catch {
        Write-VmmLog (ConvertTo-VmmNote -Activity "Disk listing of $ResourceGroup" -ErrorRecord $_) -Level Warn
    }
}
