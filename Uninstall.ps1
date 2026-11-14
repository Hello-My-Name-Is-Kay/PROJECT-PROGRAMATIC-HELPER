<#
.SYNOPSIS
    Removes the VmMaintenance module, the vmm command, PATH entry and the daily task.
    Your config, encrypted data and reports are kept unless you choose to delete them.
.EXAMPLE
    .\Uninstall.ps1
.EXAMPLE
    .\Uninstall.ps1 -RemoveConfig -RemoveData -RemoveReports
#>
[CmdletBinding()]
param([switch]$RemoveConfig, [switch]$RemoveData, [switch]$RemoveReports)
function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }

$docs = [Environment]::GetFolderPath('MyDocuments')
foreach ($d in (Join-Path $docs 'WindowsPowerShell\Modules\VmMaintenance'), (Join-Path $docs 'PowerShell\Modules\VmMaintenance')) {
    if (Test-Path $d) { Remove-Module VmMaintenance -ErrorAction SilentlyContinue; Remove-Item $d -Recurse -Force; Say " Removed $d" Green }
}
$app = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'VmMaintenance'
$bin = Join-Path $app 'bin'
if (Test-Path $bin) { Remove-Item $bin -Recurse -Force; Say " Removed $bin" Green }
$p = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($p) { [Environment]::SetEnvironmentVariable('Path', (($p -split ';' | Where-Object { $_ -and $_ -ne $bin }) -join ';'), 'User') }
try { Unregister-ScheduledTask -TaskName 'VmMaintenance daily report' -Confirm:$false -ErrorAction Stop; Say ' Removed daily report task' Green } catch { }

$cfg = Join-Path $env:APPDATA 'VmMaintenance'
if (-not $RemoveConfig -and (Test-Path $cfg)) { $RemoveConfig = (Read-Host " Delete your settings and server lists in $cfg ? (y/N)") -match '^[yY]' }
if ($RemoveConfig -and (Test-Path $cfg)) { Remove-Item $cfg -Recurse -Force; Say " Removed $cfg" Green }

$data = Join-Path $app 'data'
if (-not $RemoveData -and (Test-Path $data)) {
    Say ' IMPORTANT: deleting the data folder destroys the encrypted fleet store and its key. It cannot be undone.' Red
    $RemoveData = (Read-Host ' Type DELETE to remove it, anything else to keep it') -ceq 'DELETE'
}
if ($RemoveData -and (Test-Path $data)) { Remove-Item $data -Recurse -Force; Say " Removed $data" Green }

# Built host agents and the sanitized error log: always removed (no long-term value, may name hosts)
foreach ($sub in 'agents', 'logs') { $p = Join-Path $app $sub; if (Test-Path $p) { Remove-Item $p -Recurse -Force; Say " Removed $p" Green } }

$rep = Join-Path $app 'Reports'
if (-not $RemoveReports -and (Test-Path $rep)) { $RemoveReports = (Read-Host " Delete reports in $rep ? (y/N)") -match '^[yY]' }
if ($RemoveReports -and (Test-Path $rep)) { Remove-Item $rep -Recurse -Force; Say " Removed $rep" Green }
Say ' Uninstall finished.' Cyan
