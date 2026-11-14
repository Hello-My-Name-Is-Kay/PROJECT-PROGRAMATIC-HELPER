function Get-VmmAgentCheckMap {
    # Health check spec per agent column (Qualys, CrowdStrike, Zabbix, Ivanti, Lansweeper...):
    #   Services, Products, Drivers, Ports, Log   from Resources\InventoryFields.psd1
    #   LogMaxAgeHours                            setting Agents.LogMaxAgeHours (default 48)
    #   MinVersion                                setting Agents.MinVersion.<Key> (empty = any version)
    # Used by the fleet check, the Extractor plan (Agt.<Key>.<Field>= lines) and the RDP collector.
    [CmdletBinding()]
    param()
    $maxH = "$(Get-VmmSetting 'Agents.LogMaxAgeHours' -Default 48)"
    $m = [ordered]@{}
    foreach ($f in (Get-VmmInventoryCatalog)) {
        if (-not $f.Services.Count) { continue }
        $a = if ($f.Agent) { $f.Agent } else { @{} }
        $m[$f.Key] = @{
            Services = @($f.Services)
            Products = @($a['Products'] | Where-Object { $_ } | ForEach-Object { "$_" })
            Drivers  = @($a['Drivers'] | Where-Object { $_ } | ForEach-Object { "$_" })
            Ports    = @($a['Ports'] | Where-Object { $_ } | ForEach-Object { "$_" })
            Log      = "$($a['Log'])"
            LogMaxAgeHours = $maxH
            MinVersion = "$(Get-VmmSetting "Agents.MinVersion.$($f.Key)" -Default '')"
        }
    }
    $m
}
