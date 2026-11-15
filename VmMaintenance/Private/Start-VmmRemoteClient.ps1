function Start-VmmRemoteClient {
    # Launches one remote desktop client (a Get-VmmRemoteClient row) for one address. Nothing about the
    # sign-in is passed: the client asks for the account. Files it needs (.rdp / .rdg) are written to the
    # local handoff folder with a random name and removed after an hour (or by Remove-VmmHandoffFile).
    #   Rdp    : mstsc with a one-off .rdp file (clipboard on, only -Drive letters shared as \\tsclient\X)
    #   Rdm    : RemoteDesktopManager.exe /Template:<Handoff.RdmTemplate> /Host:<address> [/DataSource:<Handoff.RdmDataSource>]
    #   RdcMan : RDCMan.exe with a one-off .rdg file holding the server
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$Address, [string]$DisplayName, [string[]]$Drive = @())
    if ($Address -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-]*(:\d{1,5})?$') {
        throw (New-VmmErrorRecord -Activity "'$Address' is not a host name, FQDN or IP." -Category InvalidArgument -ErrorId 'VmmRdpAddress')
    }
    $dir = Get-VmmPath -Name Handoff
    Get-ChildItem -LiteralPath $dir -File -Filter 'vmm_*' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } | Remove-Item -Force -ErrorAction SilentlyContinue
    $file = $null; $argList = @(); $note = ''
    switch ($Client.Name) {
        'Rdp' {
            $file = Join-Path $dir ('vmm_{0}.rdp' -f [guid]::NewGuid().ToString('N').Substring(0, 12))
            [IO.File]::WriteAllText($file, (Get-VmmRdpFileText -Address $Address -Drive $Drive), [Text.Encoding]::Unicode)
            $argList = @('"' + $file + '"')
            $note = if ($Drive) { "drive(s) $((@($Drive) | ForEach-Object { "$_".Substring(0, 1).ToUpper() + ':' }) -join ', ') shared as \\tsclient" } else { 'no drives shared' }
        }
        'Rdm' {
            $ds = "$(Get-VmmSetting 'Handoff.RdmDataSource' -Default '')"
            if ($ds) { $argList += "/DataSource:$ds" }
            $argList += "/Template:$(Get-VmmSetting 'Handoff.RdmTemplate' -Default 'RDP')"
            $argList += "/Host:$Address"
            $note = 'drive sharing follows the RDM template (Local resources)'
        }
        'RdcMan' {
            $file = Join-Path $dir ('vmm_{0}.rdg' -f [guid]::NewGuid().ToString('N').Substring(0, 12))
            [IO.File]::WriteAllText($file, (Get-VmmRdgFileText -Address $Address -DisplayName $DisplayName), (New-Object Text.UTF8Encoding($false)))
            $argList = @('"' + $file + '"')
            $note = 'drive sharing: server Properties > Local resources in RDCMan'
        }
        default { throw (New-VmmErrorRecord -Activity "Unknown remote client '$($Client.Name)'." -Category InvalidArgument) }
    }
    if ($PSCmdlet.ShouldProcess($Address, "Open $($Client.Name)")) {
        try { Start-Process -FilePath $Client.Path -ArgumentList $argList -ErrorAction Stop }
        catch {
            throw (New-VmmErrorRecord -Activity "Could not start $($Client.Label)." -Target $Client.Path -Exception $_.Exception `
                -Fix 'Start it by hand and connect to the host; vmm still shows the steps and verifies.' -Category OpenError -ErrorId 'VmmRemoteClientStart')
        }
        Write-VmmLog "$($Client.Name) started for $Address ($note). Sign in with your admin account: vmm keeps no password." -Level Info
    }
    [pscustomobject]@{ Client = $Client.Name; Address = $Address; File = $file; Note = $note }
}
