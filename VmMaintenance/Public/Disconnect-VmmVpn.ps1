function Disconnect-VmmVpn {
    <#
    .SYNOPSIS
        Disconnects the VPN with the configured provider.
    .EXAMPLE
        Disconnect-VmmVpn
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $p = Get-VmmVpnProvider
    if (-not $PSCmdlet.ShouldProcess("$($p.Provider) VPN", 'Disconnect')) { return }
    switch ($p.Provider) {
        'None'              { Write-VmmLog 'No VPN provider configured.' -Level Muted }
        'CiscoSecureClient' { & $p.Client disconnect | Out-Null; Write-VmmLog 'Cisco Secure Client disconnected.' -Level Success }
        'Windows'           { & rasdial.exe "$($p.Profile)" /disconnect | Out-Null; Write-VmmLog "VPN '$($p.Profile)' disconnected." -Level Success }
        'Probe'             { Write-VmmLog 'Disconnect in your VPN client (Probe provider cannot control it).' -Level Info }
    }
}
