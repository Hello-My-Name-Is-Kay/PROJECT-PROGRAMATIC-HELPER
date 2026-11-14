function Assert-VmmVpn {
    # Before network work (fleet checks, staging): when Vpn.RequireForHostWork is on and a provider is
    # configured, stop with a clear error if the VPN is down, instead of 50 timeouts.
    [CmdletBinding()]
    param([string]$Activity = 'host work')
    if (-not (Get-VmmSetting 'Features.Vpn' -Default $true)) { return }
    if ((Get-VmmSetting 'Vpn.Provider' -Default 'None') -eq 'None') { return }
    if (-not (Get-VmmSetting 'Vpn.RequireForHostWork' -Default $true)) { return }
    $s = Get-VmmVpnStatus
    if ($s.State -in 'Connected', 'Degraded') {
        if ($s.State -eq 'Degraded') { Write-VmmLog "VPN: $($s.Detail)" -Level Warn }
        return
    }
    throw (New-VmmErrorRecord -Activity "VPN is not connected - $Activity stopped." -Target "$($s.Provider): $($s.State)" `
        -Cause $(if ($s.Detail) { $s.Detail } else { 'The hosts are only reachable through the company VPN.' }) `
        -Fix 'Connect: vmm connect (or V in the console). To run anyway, set Vpn.RequireForHostWork = $false.' `
        -Category ConnectionError -ErrorId 'VmmVpnDown')
}
