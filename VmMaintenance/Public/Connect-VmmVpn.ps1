function Connect-VmmVpn {
    <#
    .SYNOPSIS
        Starts the VPN with the configured provider. You sign in in the VPN client's own prompt.
    .DESCRIPTION
        CiscoSecureClient: runs 'vpncli.exe connect <Vpn.Profile>' in this console; vpncli asks for the
        group, user name, password and MFA itself. The Secure Client window must be closed first
        (vpncli refuses to connect while it is open).
        Windows: 'rasphone -d <Vpn.Profile>' (Windows' own sign-in dialog).
        Probe: starts Vpn.ClientPath (for example the GlobalProtect or FortiClient app) and waits.
        [SEC] VPN credentials are typed into the VPN client only; this tool never reads, keeps or logs them.
    .EXAMPLE
        Connect-VmmVpn
    #>
    [CmdletBinding()]
    param([int]$WaitSeconds = 120)
    $p = Get-VmmVpnProvider
    if ($p.Provider -eq 'None') { Write-VmmLog 'No VPN provider configured (Vpn.Provider = None). Set one in Settings.' -Level Warn; return }
    $now = Get-VmmVpnStatus
    if ($now.State -eq 'Connected') { Write-VmmLog "VPN already connected ($($p.Provider))." -Level Success; return $now }

    Suspend-VmmConsoleInput
    try {
        switch ($p.Provider) {
            'CiscoSecureClient' {
                if (-not $p.Profile) { throw (New-VmmErrorRecord -Activity 'Vpn.Profile is empty.' -Fix 'Set Vpn.Profile to the VPN address/profile shown in Cisco Secure Client.' -Category InvalidData) }
                if (Get-Process -Name 'csc_ui', 'vpnui' -ErrorAction SilentlyContinue) {
                    Write-VmmLog 'The Cisco Secure Client window is open; vpncli cannot connect while it runs. Close it from the tray (Quit), or connect from the window yourself.' -Level Warn
                }
                Write-VmmLog "Starting Cisco Secure Client: answer its prompts below (credentials go to the VPN client only)." -Level Info
                & $p.Client connect $p.Profile
            }
            'Windows' {
                if (-not $p.Profile) { throw (New-VmmErrorRecord -Activity 'Vpn.Profile is empty.' -Fix 'Set Vpn.Profile to the Windows VPN connection name (Settings > Network > VPN).' -Category InvalidData) }
                Start-Process -FilePath 'rasphone.exe' -ArgumentList '-d', "`"$($p.Profile)`"" -Wait
            }
            'Probe' {
                if ($p.Client -and (Test-Path -LiteralPath $p.Client)) { Start-Process -FilePath $p.Client }
                else { Write-VmmLog 'Start your VPN client and sign in. Waiting for the probe host to answer...' -Level Info }
            }
        }
    } finally { Resume-VmmConsoleInput }

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $s = Get-VmmVpnStatus
        if ($s.State -eq 'Connected') { Write-VmmLog 'VPN connected.' -Level Success; return $s }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    Write-VmmLog "VPN not connected after $WaitSeconds s (state: $($s.State)). $($s.Detail)" -Level Warn
    $s
}
