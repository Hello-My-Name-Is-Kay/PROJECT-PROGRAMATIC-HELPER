function Get-VmmCollectorScript {
    # Paste-in script for an RDP/RDM session when the tool cannot reach the host over WMI.
    # PowerShell 2.0 compatible (Server 2008 R2+). Read-only. Prints one line "VMM1|<base64>" and puts it
    # on the clipboard; paste it back into vmm (P key, or: vmm collect -Line '<line>').
    [CmdletBinding()]
    param()
    $text = @'
$ErrorActionPreference = 'SilentlyContinue'
$os = Get-WmiObject Win32_OperatingSystem; $cs = Get-WmiObject Win32_ComputerSystem
$c  = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
$sql = @(); $k = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
if (Test-Path $k) { $p = Get-ItemProperty $k; foreach ($n in ($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
    $s = Get-ItemProperty ("HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\" + $n.Value + "\Setup"); $sql += ($n.Name + ' ' + $s.PatchLevel + ' ' + $s.Edition) } }
$pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
$lang = ''; try { $lang = (New-Object Globalization.CultureInfo([int]$os.OSLanguage)).Name } catch { }
$plat = 'Physical'; if ($cs.Manufacturer -like '*VMware*') { $plat = 'VMware' } elseif ($cs.Model -like '*Virtual Machine*') { if (Get-Service WindowsAzureGuestAgent) { $plat = 'Azure' } else { $plat = 'Hyper-V' } }
$f = @('Name=' + $env:COMPUTERNAME, 'OS=' + $os.Caption, 'Lang=' + $lang, 'Version=' + $os.Version, 'Build=' + $os.BuildNumber, 'SP=' + $os.ServicePackMajorVersion,
  'Manufacturer=' + $cs.Manufacturer, 'Model=' + $cs.Model, 'Platform=' + $plat, 'CTotalGB=' + ([math]::Round($c.Size / 1GB, 1)).ToString([Globalization.CultureInfo]::InvariantCulture),
  'CFreeGB=' + ([math]::Round($c.FreeSpace / 1GB, 1)).ToString([Globalization.CultureInfo]::InvariantCulture), 'PendingReboot=' + $(if ($pend) { 'Yes' } else { 'No' }), 'Sql=' + ($sql -join '; '),
  'TempExists=' + (Test-Path 'C:\Temp'))
# VMM-INVPROBE
$line = 'VMM1|' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($f -join "`n")))
$line | clip.exe
$desk = [Environment]::GetFolderPath('Desktop')
Get-ChildItem -LiteralPath $desk -Filter ('VMM_' + $env:COMPUTERNAME + '_*.vmm') | Remove-Item -Force
$file = Join-Path $desk ('VMM_' + $env:COMPUTERNAME + '_' + (Get-Date).ToString('yyyyMMdd_HHmm') + '.vmm')
[IO.File]::WriteAllText($file, $line, [Text.Encoding]::ASCII)
Write-Host ('Saved on the desktop: ' + [IO.Path]::GetFileName($file) + ' - copy it to your laptop''s Desktop or Downloads (vmm imports it).') -ForegroundColor Green
Write-Host 'Also on the clipboard: P on the host screen in vmm. Delete the .vmm file from this desktop afterwards.' -ForegroundColor Green
'@
    # Inventory columns: reuse the host agent's Get-InvProbe (one implementation, PowerShell 2.0 compatible)
    $probe = ''
    try {
        $agent = Join-Path $script:ModuleRoot 'Resources\VmmHostAgent.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($agent, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-InvProbe' }, $true) | Select-Object -First 1
        $svc = Get-VmmInventoryServiceMap
        $map = (@(foreach ($k in $svc.Keys) { "'$k' = @(" + ((@($svc[$k]) | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ') + ')' }) -join '; ')
        if ($fn) { $probe = $fn.Extent.Text + "`r`n`$InvServices = @{ $map }`r`ntry { `$f += @(Get-InvProbe `$InvServices) } catch { }" }
    } catch { }
    $text.Replace('# VMM-INVPROBE', $probe)
}
