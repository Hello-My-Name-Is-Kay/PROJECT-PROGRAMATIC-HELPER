function New-VmmExpandPlan {
    # Resolves each name to exactly one Azure VM and works out the action. One row per name;
    # the row is also the result line written to CSV at the end of the run.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [Parameter(Mandatory)][int[]]$TierSizes,
        [Parameter(Mandatory)][int]$MaxCurrentGB,
        [switch]$ExtendOnly
    )

    # Columns pulled from Resource Graph for each VM
    $projection = @"
| extend cn  = tolower(tostring(properties.extended.instanceView.computerName)),
         osn = tolower(tostring(properties.osProfile.computerName)),
         vn  = tolower(name)
| project id, name, resourceGroup, subscriptionId, cn, osn, vn,
          osDiskId = tostring(properties.storageProfile.osDisk.managedDisk.id)
"@

    # One query for the whole batch: match Windows computer name or Azure VM name.
    # Names are already restricted to [a-z0-9_-] by Read-VmmServerList, so quoting is safe.
    $inList = ($Name | ForEach-Object { "'$_'" }) -join ','
    $vmRows = Invoke-VmmResourceGraph -Activity 'VM lookup by name' -Query @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
$projection
| where cn in ($inList) or osn in ($inList) or vn in ($inList)
"@

    foreach ($n in $Name) {
        $p = [pscustomobject]@{
            ComputerName = $n;      VMName = $null;    MatchedBy = $null;  ResourceGroup = $null
            SubscriptionId = $null; InitialState = $null
            DiskRG = $null;         DiskName = $null;  Sku = $null;        CurrentGB = $null; NewGB = $null
            Action = $null;         Snapshot = $null;  CBeforeGB = $null;  CAfterGB = $null
            FinalState = $null;     Status = 'Pending'; Notes = '';        Started = $false;  Job = $null
        }

        $match = @($vmRows | Where-Object { $_.cn -eq $n -or $_.osn -eq $n -or $_.vn -eq $n })
        if ($match.Count -ge 1) { $p.MatchedBy = 'Name' }
        else {
            $byIp = Resolve-VmmVmByIp -Name $n -Projection $projection
            $match = @($byIp.Rows)
            $p.MatchedBy = $byIp.MatchedBy
            if ($byIp.Note) { $p.Notes = $byIp.Note }
        }

        # Exactly one VM, or skip
        if ($match.Count -ne 1) {
            $p.Status = 'Skipped'
            if (-not $p.Notes) {
                $p.Notes = if ($match.Count -eq 0) { 'VM not found in any subscription you can read' }
                           else { "Ambiguous - matches $($match.Count) VMs: $(($match | ForEach-Object { $_.name }) -join ', '). Use the Azure VM name." }
            }
            $p; continue
        }

        $vm = $match[0]
        $p.VMName = $vm.name; $p.ResourceGroup = $vm.resourceGroup; $p.SubscriptionId = $vm.subscriptionId

        if (-not $vm.osDiskId) { $p.Status = 'Skipped'; $p.Notes = 'No managed OS disk (unmanaged VHD) - not supported'; $p; continue }
        $idParts = $vm.osDiskId -split '/'
        $p.DiskRG = $idParts[4]; $p.DiskName = $idParts[8]

        try {
            # Live power state (Resource Graph can lag several minutes behind)
            $p.InitialState = Get-VmmPowerState -SubscriptionId $p.SubscriptionId -ResourceGroup $p.ResourceGroup -VMName $p.VMName
            if ($p.InitialState -notin 'running', 'deallocated', 'stopped') {
                $p.Status = 'Skipped'; $p.Notes = "VM is '$($p.InitialState)' - re-run when it settles"; $p; continue
            }

            $disk = Get-AzDisk -ResourceGroupName $p.DiskRG -DiskName $p.DiskName -ErrorAction Stop
            $p.Sku = $disk.Sku.Name; $p.CurrentGB = $disk.DiskSizeGB
            $returnTo = if ($p.InitialState -eq 'running') { '' } else { ", return to $($p.InitialState)" }

            if ($ExtendOnly) {
                $p.Action = "Extend C:$returnTo"
                $p.Status = 'Ready'
            } elseif ($disk.DiskSizeGB -gt $MaxCurrentGB) {
                $p.Status = 'Skipped'; $p.Notes = "Disk is $($disk.DiskSizeGB) GB (> $MaxCurrentGB GB guard, OsDiskExpand.MaxCurrentGB)"
            } else {
                $p.NewGB = Get-VmmNextDiskTier -SizeGB $disk.DiskSizeGB -TierSizes $TierSizes
                if ($null -eq $p.NewGB) {
                    $p.Status = 'Skipped'; $p.Notes = "No tier larger than $($disk.DiskSizeGB) GB in OsDiskExpand.TierSizes"
                } else {
                    $p.Action = "Resize $($p.CurrentGB)->$($p.NewGB) GB, extend C:$returnTo"
                    $p.Status = 'Ready'
                }
            }
        } catch {
            $p.Status = 'Skipped'
            $p.Notes  = ConvertTo-VmmNote -Activity "Read of VM/disk $($p.DiskRG)/$($p.DiskName)" -ErrorRecord $_
        }
        $p
    }
}
