function Get-VmmVpnProvider {
    # Resolves the configured VPN provider and its client. Providers:
    #   None               no VPN handling (default)
    #   CiscoSecureClient  Cisco Secure Client / AnyConnect, via its command-line client vpncli.exe
    #   Windows            built-in Windows VPN profile (Get-VpnConnection / rasdial / rasphone)
    #   Probe              any other client (GlobalProtect, FortiClient, ...): status = TCP probe to an
    #                      internal host:port; connect = start the client you name in Vpn.ClientPath
    # [SEC] The tool never sees VPN credentials: sign-in happens in the VPN client's own prompt.
    [CmdletBinding()]
    param()
    $prov = Get-VmmSetting 'Vpn.Provider' -Default 'None'
    if ($prov -notin 'None', 'CiscoSecureClient', 'Windows', 'Probe') {
        throw (New-VmmErrorRecord -Activity "Unknown VPN provider '$prov'." -Fix "Set Vpn.Provider to None, CiscoSecureClient, Windows or Probe (Settings or: vmm set -Name Vpn.Provider -Value ...)." -Category InvalidData -ErrorId 'VmmVpnProvider')
    }
    $client = Get-VmmSetting 'Vpn.ClientPath' -Default ''
    if ($prov -eq 'CiscoSecureClient' -and -not $client) {
        $pf86 = ${env:ProgramFiles(x86)}; if (-not $pf86) { $pf86 = $env:ProgramFiles }
        foreach ($c in @(
                (Join-Path $pf86 'Cisco\Cisco Secure Client\vpncli.exe'),
                (Join-Path $pf86 'Cisco\Cisco AnyConnect Secure Mobility Client\vpncli.exe'),
                (Join-Path $env:ProgramFiles 'Cisco\Cisco Secure Client\vpncli.exe'))) {
            if (Test-Path -LiteralPath $c) { $client = $c; break }
        }
        if (-not $client) {
            throw (New-VmmErrorRecord -Activity 'Cisco Secure Client command-line client (vpncli.exe) not found.' `
                -Cause 'The client is not installed in the default folder, or only the GUI component was installed.' `
                -Fix 'Set Vpn.ClientPath to the full path of vpncli.exe, or set Vpn.Provider to Probe.' -Category ObjectNotFound -ErrorId 'VmmVpnClient')
        }
    }
    [pscustomobject]@{
        Provider  = $prov
        Client    = $client
        Profile   = Get-VmmSetting 'Vpn.Profile' -Default ''          # Cisco: host/group as shown in the client; Windows: connection name
        ProbeHost = Get-VmmSetting 'Vpn.ProbeHost' -Default ''        # internal name only reachable over the VPN
        ProbePort = [int](Get-VmmSetting 'Vpn.ProbePort' -Default 445)
    }
}
