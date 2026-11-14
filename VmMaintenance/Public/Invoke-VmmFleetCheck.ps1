function Invoke-VmmFleetCheck {
    <#
    .SYNOPSIS
        Read-only snapshot of many hosts in parallel, from this terminal; updates the encrypted fleet store.
    .DESCRIPTION
        Per host: DNS, ping, TCP ports (Fleet.Ports), then the first terminal route that answers
        (Fleet.Routes: DCOM on TCP 135, WinRM on 5985, WinRM-SSL on 5986): OS/SP/build, model and
        platform, C: size/free, SQL instances and version, pending reboot, agents, watched software.
        Nothing is written or changed on a host, and nothing is reconfigured on this laptop.
        Allowed any time (business hours included). Optional -Azure adds subscription, resource
        group and power state from Resource Graph (needs an Azure sign-in).
        Hosts with no working route are listed at the end: only those need hands-on (the Extractor).
    .PARAMETER AccessOnly
        Only test which terminal route works per host (fast): no facts are read, the last check is kept.
    .EXAMPLE
        Invoke-VmmFleetCheck                     # all hosts not on hold
    .EXAMPLE
        Invoke-VmmFleetCheck -Name srv01, srv02 -Azure
    #>
    [CmdletBinding()]
    param([string[]]$Name, [switch]$Azure, [switch]$AccessOnly, [switch]$PassThru, [switch]$Quiet)
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
        Routes     = @(Get-VmmSetting 'Fleet.Routes' -Default @('DCOM', 'WinRM', 'WinRM-SSL'))
        Licence    = [bool](Get-VmmSetting 'Fleet.WindowsLicence' -Default $true)
        AccessOnly = [bool]$AccessOnly
        Watch      = @(Get-VmmSetting 'Fleet.SoftwareWatch' -Default @('Microsoft SQL Server*'))
        Services   = $(try { Get-VmmInventoryServiceMap } catch { @{} })
        Agents     = $(try { Get-VmmAgentCheckMap } catch { @{} })
        Credential = Get-VmmSessionCredential -Purpose Windows
    }
    $throttle = [int](Get-VmmSetting 'Fleet.Throttle' -Default 16)
    $what = if ($AccessOnly) { 'Testing terminal access to' } else { 'Reading' }
    if (-not $Quiet) { Write-VmmLog "$what $($targets.Count) host(s) from this terminal, $throttle at a time (read-only)..." -Level Info }

    $results = @(Invoke-VmmParallel -InputObject $targets -ScriptText (Get-VmmHostCheckScript) -Arguments $checkArgs -Throttle $throttle -Activity $(if ($AccessOnly) { 'Access test' } else { 'Fleet check' }))

    # The run can take minutes: load the store again so results land on its current state
    # (an Extractor result imported meanwhile, or another vmm window, is not overwritten)
    $store = Read-VmmStore
    foreach ($res in $results) {
        $rec = $store.Hosts | Where-Object { $_.Name -eq "$($res.Name)".ToUpper() } | Select-Object -First 1
        if (-not $rec) { continue }
        # Which terminal route works for this host (or why none does): decides whether hands-on is needed
        $route = if ($res.PSObject.Properties['Route'] -and $res.Route) { "$($res.Route)" } else { 'None' }
        $access = [pscustomobject]@{ At = (Get-Date).ToUniversalTime().ToString('o'); Route = $route; Ports = "$($res.Ports)"; Why = $(if ($route -eq 'None') { "$($res.Error)" } else { '' }); Tried = "$($res.Tried)" }
        $rec | Add-Member -NotePropertyName Access -NotePropertyValue $access -Force
        if ($res.IPv4) { $rec.IPv4 = $res.IPv4 }
        if ($AccessOnly) { continue }
        # A failed terminal read never erases facts that an Extractor result brought in earlier
        $manual = $rec.Check -and $rec.Check.PSObject.Properties['Via'] -and $rec.Check.Via -and $rec.Check.Reachable -eq 'Yes'
        if ($route -eq 'None' -and $manual) { continue }
        $rec.Check  = $res
        $rec.Health = Get-VmmHostHealth -Check $res
        if ($res.Platform) { $rec.Platform = $res.Platform }
        if ($res.PSObject.Properties['Inv']) { Update-VmmInventoryAuto -Record $rec -Values $res.Inv -Via 'check' }
    }
    if ($Azure -and -not $AccessOnly) { Update-VmmFleetAzure -Store $store -Name $targets }
    Save-VmmStore -Store $store

    if (-not $Quiet) {
        if ($AccessOnly) {
            $results | Sort-Object Name | Select-Object Name, Route, Ports, @{ n = 'HandsOn'; e = { if ($_.Route -and $_.Route -ne 'None') { 'no' } else { 'YES' } } }, @{ n = 'Why'; e = { $_.Error } } | Format-Table -AutoSize -Wrap | Out-Host
        } else {
            $results | Sort-Object Name | Select-Object Name, Route, Platform, OS, CFreeGB, Sql, PendingReboot, @{ n = 'Agents'; e = { $_.AgentSummary } }, Error | Format-Table -AutoSize | Out-Host
        }
        $ok = @($results | Where-Object { $_.Route -and $_.Route -ne 'None' })
        $bad = @($results | Where-Object { -not $_.Route -or $_.Route -eq 'None' })
        if ($ok) { Write-VmmLog "$($ok.Count) host(s) answered over the terminal ($((@($ok | Group-Object Route | ForEach-Object { "$($_.Name) $($_.Count)" })) -join ', ')): no hands-on needed for them." -Level Success }
        if ($bad) {
            Write-VmmLog "$($bad.Count) host(s) have no working terminal route: $((@($bad | Sort-Object Name | ForEach-Object Name)) -join ', ')" -Level Warn
            Write-VmmLog 'Hands-on is needed only for those: vmm snapshot builds the Extractor and lists the steps (or S on a host).' -Level Info
        }
        if (-not $AccessOnly) {
            try {
                $gaps = @(foreach ($h in @($store.Hosts | Where-Object { $targets -contains $_.Name })) { $m = @(Get-VmmInventoryRow -Record $h | Where-Object Missing); if ($m) { $h.Name } })
                if ($gaps) { Write-VmmLog "Inventory: $($gaps.Count) host(s) still miss columns - open a host and press I, or: vmm inventory -Missing" -Level Info }
            } catch { }
        }
    }
    if ($PassThru) { $results }
}
