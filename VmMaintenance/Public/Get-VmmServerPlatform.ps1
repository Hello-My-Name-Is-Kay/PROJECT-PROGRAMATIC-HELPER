function Get-VmmServerPlatform {
    <#
    .SYNOPSIS
        Asks each server over WMI whether it is VMware, Azure VM, Hyper-V VM or physical, plus its OS.
    .DESCRIPTION
        Uses CIM over DCOM (same transport as the old Get-WmiObject), so it works in Windows
        PowerShell 5.1 and PowerShell 7 and needs no WinRM. An Azure VM is a Microsoft "Virtual
        Machine" that runs the WindowsAzureGuestAgent service.
        Columns: Name, Platform, OS, Status, Detail (why it failed, when it did).
    .EXAMPLE
        Get-VmmServerPlatform
    .EXAMPLE
        Get-VmmServerPlatform -ComputerName srv01, srv02 -Credential (Get-Credential)
    #>
    [CmdletBinding()]
    param(
        [string[]]$ComputerName,
        [string]$ServerList,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$OutCsv,
        [switch]$PassThru
    )
    $servers = @(Read-VmmServerList -Name $ComputerName -Path $ServerList -ListKey 'Platform' -Case Keep -KeepDomain)
    $opt = New-CimSessionOption -Protocol Dcom

    $results = foreach ($server in $servers) {
        $row = [ordered]@{ Name = $server; Platform = 'Unknown'; OS = 'N/A'; Status = 'OK'; Detail = $null }
        $session = $null
        try {
            $sp = @{ ComputerName = $server; SessionOption = $opt; ErrorAction = 'Stop' }
            if ($Credential) { $sp.Credential = $Credential }
            $session = New-CimSession @sp
            $cs = Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem -ErrorAction Stop
            $row.OS = (Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption

            if ($cs.Manufacturer -like '*VMware*') {
                $row.Platform = 'VMware'
            } elseif ($cs.Model -like '*Virtual Machine*' -and $cs.Manufacturer -like '*Microsoft*') {
                # Azure and Hyper-V look the same here; the Azure guest agent tells them apart
                try {
                    $svc = Get-CimInstance -CimSession $session -ClassName Win32_Service -Filter "Name='WindowsAzureGuestAgent'" -ErrorAction Stop
                    $row.Platform = if ($svc) { 'Azure VM' } else { 'Hyper-V VM' }
                } catch {
                    $row.Platform = 'Hyper-V or Azure'
                    $row.Detail   = ConvertTo-VmmNote -Activity 'Azure agent service check' -ErrorRecord $_
                }
            } else {
                $row.Platform = 'Physical'
            }
            Write-VmmLog ('{0,-24} {1,-16} {2}' -f $server, $row.Platform, $row.OS)
        } catch {
            $row.Status = 'WMI Unreachable'
            $row.Detail = ConvertTo-VmmNote -Activity 'WMI (DCOM) query' -ErrorRecord $_
            Write-VmmLog "$server : WMI unreachable - $($_.Exception.Message)" -Level Warn
        } finally {
            if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
        }
        [pscustomobject]$row
    }

    $results = @($results)
    Export-VmmCsv -InputObject $results -Path (Resolve-VmmOutputPath -Path $OutCsv -BaseName 'ServerPlatform')
    $down = @($results | Where-Object Status -ne 'OK')
    if ($down) { Write-VmmLog "$($down.Count) of $($results.Count) server(s) unreachable - see the Detail column" -Level Warn }
    else { Write-VmmLog "All $($results.Count) server(s) answered" -Level Success }
    if ($PassThru) { $results }
}
