function Get-VmmVpnStatus {
    <#
    .SYNOPSIS
        VPN state from the configured provider: Connected, Disconnected, Unknown or NotConfigured.
    .DESCRIPTION
        CiscoSecureClient: 'vpncli.exe state'. Windows: Get-VpnConnection. Probe: TCP connect to
        Vpn.ProbeHost:Vpn.ProbePort. When Vpn.ProbeHost is set it is also tested for the other providers,
        so "connected but cannot reach the servers" is reported as Degraded.
    .EXAMPLE
        Get-VmmVpnStatus
    .EXAMPLE
        vmm vpn
    #>
    [CmdletBinding()]
    param()
    $p = Get-VmmVpnProvider
    $state = 'Unknown'; $detail = ''
    switch ($p.Provider) {
        'None' { return [pscustomobject]@{ Provider = 'None'; State = 'NotConfigured'; Detail = 'Vpn.Provider = None'; Reachable = $null } }
        'CiscoSecureClient' {
            try {
                $out = (& $p.Client state 2>&1 | Out-String)
                if ($out -match '(?im)state:\s*Connected\s*$') { $state = 'Connected' }
                elseif ($out -match '(?im)state:\s*(Disconnected|Connecting|Reconnecting)') { $state = $Matches[1] }
                if ($out -match 'Another .* application is running|not available') { $detail = 'The Secure Client window is open; status from vpncli may be limited.' }
            } catch { $detail = 'vpncli.exe failed: ' + (Protect-VmmLogText $_.Exception.Message) }
        }
        'Windows' {
            if (-not (Get-Command Get-VpnConnection -ErrorAction SilentlyContinue)) { $detail = 'Get-VpnConnection not available on this Windows edition.' }
            elseif (-not $p.Profile) { $detail = 'Set Vpn.Profile to the VPN connection name.' }
            else {
                try { $c = Get-VpnConnection -Name $p.Profile -ErrorAction Stop; $state = "$($c.ConnectionStatus)" }
                catch { try { $c = Get-VpnConnection -Name $p.Profile -AllUserConnection -ErrorAction Stop; $state = "$($c.ConnectionStatus)" } catch { $detail = "VPN connection '$($p.Profile)' not found." } }
            }
        }
        'Probe' { if (-not $p.ProbeHost) { $detail = 'Set Vpn.ProbeHost to an internal host only reachable over the VPN.' } }
    }
    $reach = $null
    if ($p.ProbeHost) {
        $reach = Test-VmmTcpPort -ComputerName $p.ProbeHost -Port $p.ProbePort -TimeoutMs 2000
        if ($p.Provider -eq 'Probe') { $state = if ($reach) { 'Connected' } else { 'Disconnected' } }
        elseif ($state -eq 'Connected' -and -not $reach) { $state = 'Degraded'; $detail = 'VPN up but the probe host does not answer (DNS, split tunnel or firewall).' }
    }
    [pscustomobject]@{ Provider = $p.Provider; State = $state; Detail = $detail; Reachable = $reach }
}
