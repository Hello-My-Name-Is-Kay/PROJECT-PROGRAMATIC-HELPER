function Resolve-VmmVmByIp {
    # Fallback for VMs whose Azure name differs from the server name: DNS A record -> private IP -> NIC -> VM.
    # Returns @{ Rows = <Resource Graph VM rows>; MatchedBy = 'IP x'; Note = <why it failed> }.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Projection
    )
    $result = @{ Rows = @(); MatchedBy = $null; Note = $null }

    try {
        $ip = (Resolve-DnsName -Name $Name -Type A -ErrorAction Stop |
               Where-Object Type -eq 'A' | Select-Object -First 1).IPAddress
    } catch {
        $result.Note = "No VM with this name in Azure, and DNS lookup failed ($($_.Exception.Message)). Check the name, or run from a machine that resolves it."
        return $result
    }
    if (-not $ip) { $result.Note = 'No VM with this name in Azure, and DNS has no A record for it.'; return $result }

    $nic = Invoke-VmmResourceGraph -Activity "NIC lookup for $Name" -Query @"
Resources
| where type =~ 'microsoft.network/networkinterfaces'
| mv-expand ipc = properties.ipConfigurations
| where tostring(ipc.properties.privateIPAddress) == '$ip'
| project vmId = tolower(tostring(properties.virtualMachine.id))
"@
    $vmId = @($nic | Where-Object { $_.vmId } | Select-Object -ExpandProperty vmId -Unique)

    if ($vmId.Count -eq 1) {
        $result.Rows = @(Invoke-VmmResourceGraph -Activity "VM lookup for $Name" -Query @"
Resources
| where type =~ 'microsoft.compute/virtualmachines' and tolower(id) == '$($vmId[0])'
$Projection
"@)
        if ($result.Rows.Count -ge 1) { $result.MatchedBy = "IP $ip" }
        else { $result.Note = "IP $ip is on a NIC whose VM you cannot read (missing Reader role?)" }
    } elseif ($vmId.Count -eq 0) {
        $result.Note = "IP $ip (from DNS) is on no Azure NIC you can see: on-prem server, stale DNS, or a subscription you lack access to."
    } else {
        $result.Note = "IP $ip matched $($vmId.Count) VM NICs - ambiguous, use the Azure VM name instead."
    }
    $result
}
