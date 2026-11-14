function Get-VmmAzureVmDisk {
    <#
    .SYNOPSIS
        Lists the subscription and up to four disks (storage type and size) for a list of Azure VMs.
    .DESCRIPTION
        Read-only. Searches every enabled subscription you can see (or only -SubscriptionId /
        Azure.SubscriptionIds) for the VMs in your list. A VM matches on its Azure resource name or
        its Windows computer name. Columns:
            ComputerName, AzureVMName, Subscription,
            Disk1Type, Disk1GB, ... Disk4Type, Disk4GB, TotalDisks, Note
        Disk1 is always the OS disk; Disk2-4 are data disks in LUN order. More than four disks:
        TotalDisks shows the real count and Note flags it.

        Names come from -ComputerName, -ServerList, ServerLists.AzureVms, or the Lansweeper results
        CSV (rows whose VMPlatform mentions Azure) with -LansweeperCsv.
    .EXAMPLE
        Get-VmmAzureVmDisk
    .EXAMPLE
        Get-VmmAzureVmDisk -LansweeperCsv 'C:\Temp\VmMaintenance\LansweeperDiskSpace_20260101-090000.csv'
    #>
    [CmdletBinding()]
    param(
        [string[]]$ComputerName,
        [string]$ServerList,
        [string]$LansweeperCsv,
        [string[]]$SubscriptionId,
        [string]$TenantId,
        [string]$OutCsv,
        [switch]$PassThru
    )
    if (-not $PSBoundParameters.ContainsKey('TenantId'))       { $TenantId       = Get-VmmSetting 'Azure.TenantId' }
    if (-not $PSBoundParameters.ContainsKey('SubscriptionId')) { $SubscriptionId = @(Get-VmmSetting 'Azure.SubscriptionIds' -Default @()) }

    # --- Names to look for
    if ($LansweeperCsv) {
        if (-not (Test-Path -LiteralPath $LansweeperCsv -PathType Leaf)) {
            throw (New-VmmErrorRecord -Activity 'Lansweeper results CSV not found.' -Target $LansweeperCsv `
                -Fix 'Run Get-VmmLansweeperDiskSpace first, or pass the path of its output CSV.' -Category ObjectNotFound)
        }
        $ComputerName = @(Import-Csv -LiteralPath $LansweeperCsv | Where-Object { $_.VMPlatform -like '*Azure*' } | ForEach-Object { $_.ComputerName })
        if (-not $ComputerName) {
            throw (New-VmmErrorRecord -Activity 'No Azure rows in the Lansweeper CSV.' -Target $LansweeperCsv `
                -Cause "No row has 'Azure' in the VMPlatform column (Lansweeper may report them as 'Hyper-V or Azure')." `
                -Fix 'Pass the names with -ComputerName or a list file instead.' -Category InvalidData)
        }
    }
    $servers = @(Read-VmmServerList -Name $ComputerName -Path $ServerList -ListKey 'AzureVms' -Case Upper)

    Assert-VmmModule -Name 'Az.Accounts', 'Az.Compute'
    Connect-VmmAzure -TenantId $TenantId

    # --- Subscriptions to search
    try {
        $subs = if ($TenantId) { Get-AzSubscription -TenantId $TenantId -ErrorAction Stop } else { Get-AzSubscription -ErrorAction Stop }
    } catch {
        throw (New-VmmErrorRecord -Activity 'Could not list subscriptions.' -Target "tenant $TenantId" -Exception $_.Exception -Category ReadError)
    }
    $subs = @($subs | Where-Object { $_.State -eq 'Enabled' })
    if ($SubscriptionId) { $subs = @($subs | Where-Object { $SubscriptionId -contains $_.Id -or $SubscriptionId -contains $_.Name }) }
    if (-not $subs) {
        throw (New-VmmErrorRecord -Activity 'No enabled subscriptions to search.' -Target "tenant $TenantId" `
            -Cause 'Your account sees no enabled subscription, or -SubscriptionId / Azure.SubscriptionIds matches none of them.' `
            -Fix 'Get-AzSubscription | Format-Table Name, Id, State  - then fix the id list.' -Category ObjectNotFound)
    }

    $wanted   = [System.Collections.Generic.HashSet[string]]::new([string[]]$servers, [StringComparer]::OrdinalIgnoreCase)
    $matched  = @{}   # computer name (upper) -> output row
    $failSubs = @()

    foreach ($sub in $subs) {
        Write-VmmLog "Searching subscription: $($sub.Name)" -Level Info
        try {
            Set-VmmSubscription -Subscription $sub.Id
            $vms  = @(Get-AzVM -ErrorAction Stop)
            $hits = @($vms | Where-Object {
                $wanted.Contains($_.Name) -or
                ($_.OSProfile -and $_.OSProfile.ComputerName -and $wanted.Contains($_.OSProfile.ComputerName))
            })
            if (-not $hits) { continue }

            # Index this subscription's managed disks by resource ID (one call instead of one per disk)
            $diskById = @{}
            foreach ($d in Get-AzDisk -ErrorAction Stop) { $diskById[$d.Id.ToLower()] = $d }
        } catch {
            $failSubs += $sub.Name
            Write-VmmLog ("Skipped subscription '$($sub.Name)': " + (ConvertTo-VmmNote -Activity 'VM/disk listing' -ErrorRecord $_)) -Level Warn
            continue
        }

        foreach ($vm in $hits) {
            $disks  = @(Get-VmmDiskDescriptor -DiskRef $vm.StorageProfile.OsDisk -DiskById $diskById)
            $disks += @($vm.StorageProfile.DataDisks | Sort-Object Lun | ForEach-Object { Get-VmmDiskDescriptor -DiskRef $_ -DiskById $diskById })

            $computerName = if ($vm.OSProfile -and $vm.OSProfile.ComputerName) { $vm.OSProfile.ComputerName } else { $vm.Name }
            $key = if ($wanted.Contains($vm.Name)) { $vm.Name.ToUpper() } else { $computerName.ToUpper() }

            $row = [ordered]@{
                ComputerName = $computerName.ToUpper()
                AzureVMName  = $vm.Name
                Subscription = $sub.Name
            }
            for ($i = 0; $i -lt 4; $i++) {
                $row["Disk$($i + 1)Type"] = if ($i -lt $disks.Count) { $disks[$i].Type } else { $null }
                $row["Disk$($i + 1)GB"]   = if ($i -lt $disks.Count) { $disks[$i].GB }   else { $null }
            }
            $row['TotalDisks'] = $disks.Count
            $row['Note']       = if ($disks.Count -gt 4) { "$($disks.Count - 4) more disk(s) not shown" } else { $null }

            if ($matched.ContainsKey($key)) {
                # Same name in more than one subscription: keep both, and say so
                $row['Note'] = (@($row['Note'], 'Name also found in another subscription') | Where-Object { $_ }) -join '; '
                $matched["$key|$($sub.Id)"] = [pscustomobject]$row
            } else {
                $matched[$key] = [pscustomobject]$row
            }
        }
    }

    # --- One row per requested server (plus duplicates), unmatched names flagged
    $notFoundNote = if ($failSubs) { "Not found (subscriptions not searched: $($failSubs -join ', '))" } else { 'Not found in searched subscriptions' }
    $results = foreach ($name in $servers) {
        $rows = $matched.GetEnumerator() | Where-Object { ($_.Key -split '\|')[0] -eq $name } | ForEach-Object { $_.Value }
        if ($rows) { $rows }
        else {
            $row = [ordered]@{ ComputerName = $name; AzureVMName = $null; Subscription = $null }
            1..4 | ForEach-Object { $row["Disk${_}Type"] = $null; $row["Disk${_}GB"] = $null }
            $row['TotalDisks'] = $null
            $row['Note']       = $notFoundNote
            [pscustomobject]$row
        }
    }

    $results = @($results | Sort-Object Subscription, ComputerName)
    $results | Format-Table -AutoSize | Out-VmmHost
    Export-VmmCsv -InputObject $results -Path (Resolve-VmmOutputPath -Path $OutCsv -BaseName 'AzureVmDisks')

    $missing = @($results | Where-Object { -not $_.AzureVMName })
    if ($missing) { Write-VmmLog "$($missing.Count) name(s) not found: $(($missing.ComputerName) -join ', ')" -Level Warn }
    if ($failSubs) { Write-VmmLog "$($failSubs.Count) subscription(s) could not be searched - see warnings above." -Level Warn }
    if ($PassThru) { $results }
}
