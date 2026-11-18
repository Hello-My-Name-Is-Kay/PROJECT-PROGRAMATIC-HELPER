function Get-VmmFleetName {
    # Every host name, FQDN and IPv4 in the fleet store: removed from text before it is shared (known fixes,
    # library export).
    [CmdletBinding()]
    param($Store)
    if (-not $Store) { $Store = Read-VmmStore }
    @(foreach ($h in $Store.Hosts) { $h.Name; if ($h.PSObject.Properties['Fqdn']) { $h.Fqdn }; if ($h.PSObject.Properties['IPv4']) { $h.IPv4 } }) | Where-Object { $_ } | Select-Object -Unique
}
