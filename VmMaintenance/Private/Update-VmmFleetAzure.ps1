function Update-VmmFleetAzure {
    # One Resource Graph query for the batch: maps host names (VM name or Windows computer name) to
    # subscription, resource group, VM name and power state. Leaves non-Azure hosts untouched.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string[]]$Name)
    try {
        Assert-VmmModule -Name 'Az.Accounts', 'Az.ResourceGraph'
        Connect-VmmAzure -TenantId (Get-VmmSetting 'Azure.TenantId') -Subscription (Get-VmmSetting 'Azure.Subscription')
    } catch { Write-VmmLog "Azure details skipped: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -Level Warn; return }

    $inList = ($Name | ForEach-Object { "'$($_.ToLower())'" }) -join ','
    $rows = Invoke-VmmResourceGraph -Activity 'Fleet Azure lookup' -Query @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend cn = tolower(tostring(properties.extended.instanceView.computerName)), osn = tolower(tostring(properties.osProfile.computerName)), vn = tolower(name)
| where cn in ($inList) or osn in ($inList) or vn in ($inList)
| project name, resourceGroup, subscriptionId, cn, osn, vn, power = tostring(properties.extended.instanceView.powerState.code)
"@
    foreach ($n in $Name) {
        $l = $n.ToLower()
        $m = @($rows | Where-Object { $_.cn -eq $l -or $_.osn -eq $l -or $_.vn -eq $l })
        $rec = $Store.Hosts | Where-Object { $_.Name -eq $n.ToUpper() } | Select-Object -First 1
        if (-not $rec -or $m.Count -ne 1) { continue }
        $rec.Azure = [pscustomobject]@{
            SubscriptionId = $m[0].subscriptionId; ResourceGroup = $m[0].resourceGroup
            VMName = $m[0].name; PowerState = ($m[0].power -replace '^PowerState/', '')
        }
        $rec.Platform = 'Azure'
    }
}
