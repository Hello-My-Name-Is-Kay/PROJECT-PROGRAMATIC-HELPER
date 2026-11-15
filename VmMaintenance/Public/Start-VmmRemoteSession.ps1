function Start-VmmRemoteSession {
    <#
    .SYNOPSIS
        Opens a remote desktop session to one host with RDP (mstsc), RDM (Devolutions Remote Desktop
        Manager) or RDCMan (Sysinternals), whichever you pick or set in Handoff.Client.
    .DESCRIPTION
        Nothing about the sign-in is passed or stored: the client asks for the account. RDP gets a one-off
        .rdp file (clipboard on, only the drives in -ShareDrive shared as \\tsclient\X). RDM opens a quick
        connect with /Template:<Handoff.RdmTemplate> /Host:<host>. RDCMan opens a one-off .rdg file.
        Client OS hosts (Windows 10/11) are refused unless they carry an order (vmm order).
    .EXAMPLE
        Start-VmmRemoteSession -HostName srv01
    .EXAMPLE
        Start-VmmRemoteSession -HostName srv01 -Client Rdm
    .EXAMPLE
        Start-VmmRemoteSession -List      # which clients this laptop has, and why one is missing
    #>
    [CmdletBinding(DefaultParameterSetName = 'Open')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Open')][string]$HostName,
        [Parameter(ParameterSetName = 'Open')][ValidateSet('Default', 'Ask', 'Rdp', 'Rdm', 'RdcMan')][string]$Client = 'Default',
        [Parameter(ParameterSetName = 'Open')][string[]]$ShareDrive = @(),
        [Parameter(Mandatory, ParameterSetName = 'List')][switch]$List
    )
    if ($List) { return (Get-VmmRemoteClient | Select-Object Name, Available, Label, Path, Why) }
    $rec = try { Get-VmmHostRecord -Store (Read-VmmStore) -Name $HostName } catch { $null }
    $name = if ($rec) { $rec.Name } else { $HostName.ToUpper() }
    $addr = if ($rec -and $rec.PSObject.Properties['Fqdn'] -and $rec.Fqdn) { $rec.Fqdn } elseif ($rec) { $rec.Name } else { $HostName }
    if ($rec) {
        $pol = Get-VmmHostPolicy -Record $rec
        if ($pol.Scope -eq 'ClientOs') {
            throw (New-VmmErrorRecord -Activity "Policy: no remote session to $name." -Target "$name ($($pol.Os))" -Cause $pol.Why `
                -Fix "Only with orders: vmm order -HostName $name -Reason '<ticket / who approved>'" -Category PermissionDenied -ErrorId 'VmmPolicy')
        }
        foreach ($w in $pol.Warnings) { Write-VmmLog "[$name] $w" -Level Warn }
    }
    Assert-VmmVpn -Activity 'remote desktop'
    $c = Select-VmmRemoteClient -Client $Client -For $name
    if (-not $c) { Write-VmmLog "Open the session yourself: $addr" -Level Info; return }
    Start-VmmRemoteClient -Client $c -Address $addr -DisplayName $name -Drive $ShareDrive
}
