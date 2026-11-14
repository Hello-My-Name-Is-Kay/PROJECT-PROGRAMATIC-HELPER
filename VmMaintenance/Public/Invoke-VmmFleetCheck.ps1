function Invoke-VmmFleetCheck {
    <#
    .SYNOPSIS
        Read-only health check of many hosts in parallel; updates the encrypted fleet store.
    .DESCRIPTION
        Per host: DNS, ping, TCP ports (Fleet.Ports), then over WMI/DCOM: OS/SP/build, model and
        platform, C: size/free, SQL instances and version, pending reboot, watched software.
        Allowed any time (business hours included). Optional -Azure adds subscription, resource
        group and power state from Resource Graph (needs an Azure sign-in).
    .EXAMPLE
        Invoke-VmmFleetCheck                     # all hosts not on hold
    .EXAMPLE
        Invoke-VmmFleetCheck -Name srv01, srv02 -Azure
    #>
    [CmdletBinding()]
    param([string[]]$Name, [switch]$Azure, [switch]$PassThru, [switch]$Quiet)
    Assert-VmmVpn -Activity 'fleet check'

    $store = Read-VmmStore
    if (-not @($store.Hosts).Count) {
        throw (New-VmmErrorRecord -Activity 'The fleet is empty.' -Fix 'Import hosts first: vmm import -Path <list.txt>  (or Import-VmmFleet)' -Category ObjectNotFound)
    }
    $targets = if ($Name) { @($Name | ForEach-Object { (Get-VmmHostRecord -Store $store -Name $_).Name }) }
               else { @($store.Hosts | Where-Object { -not $_.Hold } | ForEach-Object { $_.Name }) }

    $addr = @{}; $ipMap = @{}
    foreach ($h in @($store.Hosts | Where-Object { $targets -contains $_.Name })) {
        if ($h.PSObject.Properties['Fqdn'] -and $h.Fqdn) { $addr[$h.Name] = $h.Fqdn }
        if ($h.IPv4) { $ipMap[$h.Name] = $h.IPv4 }
    }
    $checkArgs = @{
        Addr       = $addr
        IpMap      = $ipMap
        TimeoutMs  = [int](Get-VmmSetting 'Fleet.TimeoutMs' -Default 1500)
        Ports      = @(Get-VmmSetting 'Fleet.Ports' -Default @(135, 445, 3389, 5985))
        Watch      = @(Get-VmmSetting 'Fleet.SoftwareWatch' -Default @('Microsoft SQL Server*'))
        Services   = $(try { Get-VmmInventoryServiceMap } catch { @{} })
        Agents     = $(try { Get-VmmAgentCheckMap } catch { @{} })
        Credential = Get-VmmSessionCredential -Purpose Windows
    }
    $throttle = [int](Get-VmmSetting 'Fleet.Throttle' -Default 16)
    if (-not $Quiet) { Write-VmmLog "Checking $($targets.Count) host(s), $throttle at a time (read-only)..." -Level Info }

    $results = @(Invoke-VmmParallel -InputObject $targets -ScriptText (Get-VmmHostCheckScript) -Arguments $checkArgs -Throttle $throttle -Activity 'Fleet check')

    foreach ($res in $results) {
        $rec = $store.Hosts | Where-Object { $_.Name -eq "$($res.Name)".ToUpper() } | Select-Object -First 1
        if (-not $rec) { continue }
        $rec.Check  = $res
        $rec.Health = Get-VmmHostHealth -Check $res
        if ($res.IPv4) { $rec.IPv4 = $res.IPv4 }
        if ($res.Platform) { $rec.Platform = $res.Platform }
        if ($res.PSObject.Properties['Inv']) { Update-VmmInventoryAuto -Record $rec -Values $res.Inv -Via 'check' }
    }
    if ($Azure) { Update-VmmFleetAzure -Store $store -Name $targets }
    Save-VmmStore -Store $store

    $rows = @($results | Sort-Object Name | Select-Object Name, Reachable, Platform, OS, CFreeGB, Sql, PendingReboot, @{ n = 'Agents'; e = { $_.AgentSummary } }, Error)
    if (-not $Quiet) {
        $rows | Format-Table -AutoSize | Out-Host
        $bad = @($results | Where-Object { $_.Reachable -ne 'Yes' })
        if ($bad) { Write-VmmLog "$($bad.Count) host(s) not fully reachable. Use RDP guide (collector) for those, or check firewall/rights." -Level Warn }
        else { Write-VmmLog "All $($results.Count) host(s) answered." -Level Success }
        try {
            $gaps = @(foreach ($h in @($store.Hosts | Where-Object { $targets -contains $_.Name })) { $m = @(Get-VmmInventoryRow -Record $h | Where-Object Missing); if ($m) { $h.Name } })
            if ($gaps) { Write-VmmLog "Inventory: $($gaps.Count) host(s) still miss columns - open a host and press I, or: vmm inventory -Missing" -Level Info }
        } catch { }
    }
    if ($PassThru) { $results }
}
