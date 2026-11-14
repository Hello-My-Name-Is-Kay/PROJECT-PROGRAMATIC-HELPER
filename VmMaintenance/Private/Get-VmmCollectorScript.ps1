function Get-VmmCollectorScript {
    # Paste-in script for an RDP/RDM session when the tool cannot reach the host over WMI.
    # PowerShell 2.0 compatible (Server 2008 R2+). Read-only. Prints one line "VMM1|<base64>" and puts it
    # on the clipboard; paste it back into vmm (P key, or: vmm collect -Line '<line>').
    [CmdletBinding()]
    param()
    @'
$ErrorActionPreference = 'SilentlyContinue'
$os = Get-WmiObject Win32_OperatingSystem; $cs = Get-WmiObject Win32_ComputerSystem
$c  = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
$sql = @(); $k = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
if (Test-Path $k) { $p = Get-ItemProperty $k; foreach ($n in ($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
    $s = Get-ItemProperty ("HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\" + $n.Value + "\Setup"); $sql += ($n.Name + ' ' + $s.PatchLevel + ' ' + $s.Edition) } }
$pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
$plat = 'Physical'; if ($cs.Manufacturer -like '*VMware*') { $plat = 'VMware' } elseif ($cs.Model -like '*Virtual Machine*') { if (Get-Service WindowsAzureGuestAgent) { $plat = 'Azure' } else { $plat = 'Hyper-V' } }
$f = @('Name=' + $env:COMPUTERNAME, 'OS=' + $os.Caption, 'Version=' + $os.Version, 'Build=' + $os.BuildNumber, 'SP=' + $os.ServicePackMajorVersion,
  'Manufacturer=' + $cs.Manufacturer, 'Model=' + $cs.Model, 'Platform=' + $plat, 'CTotalGB=' + ([math]::Round($c.Size / 1GB, 1)).ToString([Globalization.CultureInfo]::InvariantCulture),
  'CFreeGB=' + ([math]::Round($c.FreeSpace / 1GB, 1)).ToString([Globalization.CultureInfo]::InvariantCulture), 'PendingReboot=' + $(if ($pend) { 'Yes' } else { 'No' }), 'Sql=' + ($sql -join '; '),
  'TempExists=' + (Test-Path 'C:\Temp'))
$line = 'VMM1|' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($f -join "`n")))
$line | clip.exe
Write-Host $line
Write-Host 'Copied to clipboard. Paste it into vmm on your laptop (P on the host screen).' -ForegroundColor Green
'@
}
