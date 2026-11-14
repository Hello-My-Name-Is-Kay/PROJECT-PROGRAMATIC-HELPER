function Get-VmmInventoryServiceMap {
    # Agent columns -> service wildcards, from the inventory field list. Used by the fleet check, the host
    # agent plan (Svc.<Key>= lines) and the RDP collector.
    [CmdletBinding()]
    param()
    $m = [ordered]@{}
    foreach ($f in (Get-VmmInventoryCatalog)) { if ($f.Services.Count) { $m[$f.Key] = @($f.Services) } }
    $m
}
