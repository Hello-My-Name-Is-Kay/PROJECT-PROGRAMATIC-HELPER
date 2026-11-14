<#
.SYNOPSIS
    Installs the VmMaintenance fleet console for the current Windows user (no admin rights needed).
.DESCRIPTION
    - Checks Windows + PowerShell 5.1/7, unblocks the downloaded files.
    - Copies the module to your user module folders (Windows PowerShell 5.1 and PowerShell 7).
    - Creates the 'vmm' command (%LOCALAPPDATA%\VmMaintenance\bin, added to your user PATH).
    - Creates 'VM Maintenance' shortcuts on your desktop and in the Start menu (they open the installed
      copy, so this folder can be moved or deleted afterwards).
    - Runs the setup wizard: important warnings (type YES) and every option, page by page
      (change any of them later with 'vmm setup' or vmm > Settings).
    - Creates your local config (%APPDATA%\VmMaintenance\config.psd1) and the encrypted data store.
    - Optional: installs missing Az modules, registers a daily report task (runs only while you are
      logged on, so no password is stored).
    Nothing here stores a username or password.
.EXAMPLE
    .\Install.ps1
.EXAMPLE
    .\Install.ps1 -AcceptDefaults      # no questions; set everything later in vmm > Settings
.EXAMPLE
    .\Install.ps1 -Update              # what 'vmm update' runs after the smoke test passed
#>
[CmdletBinding()]
param(
    [switch]$AcceptDefaults,
    [switch]$Update          # used by 'vmm update': copy module + launcher only, no questions, settings untouched
)
if ($Update) { $AcceptDefaults = $true }

$ErrorActionPreference = 'Stop'
function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Ask($q, $def) {
    if ($AcceptDefaults) { return $def }
    $a = Read-Host "$q [$def]"
    if ([string]::IsNullOrWhiteSpace($a)) { $def } else { $a.Trim() }
}
function AskYes($q, $def = 'Y') { (Ask "$q (Y/N)" $def) -match '^[yY]' }

# --- 1. Platform checks
if ($env:OS -ne 'Windows_NT') { Say 'ERROR: Windows only. This tool uses DPAPI, CIM/DCOM and the Windows console.' Red; exit 1 }
if ($PSVersionTable.PSVersion -lt [version]'5.1') { Say "ERROR: PowerShell 5.1 or later required (this is $($PSVersionTable.PSVersion)). Install WMF 5.1." Red; exit 1 }
$repo = $PSScriptRoot
$src  = Join-Path $repo 'VmMaintenance'
if (-not (Test-Path (Join-Path $src 'VmMaintenance.psd1'))) { Say "ERROR: run Install.ps1 from the repository root (VmMaintenance\ folder not found next to it)." Red; exit 1 }
Get-ChildItem -LiteralPath $repo -Recurse -File | Unblock-File
$ver = (Import-PowerShellDataFile (Join-Path $src 'VmMaintenance.psd1')).ModuleVersion

Say "`n VmMaintenance $ver - installer" Cyan
Say ' ------------------------------------------------------------' DarkGray

# --- 2. Installer-only options (everything else is asked by the setup wizard after the copy)
$wantTask = if ($Update) { $false } else { AskYes ' Export the daily report automatically every day (scheduled task, runs while you are logged on)' 'Y' }
$linkName = 'VM Maintenance.lnk'
$linkDirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) | Where-Object { $_ }
# Update: (re)create them unless you said no at install time (marker file no-shortcuts)
$noLinks = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'VmMaintenance\no-shortcuts'
$wantLinks = if ($Update) { -not (Test-Path -LiteralPath $noLinks) } else { AskYes ' Create desktop and Start menu shortcuts' 'Y' }
$taskAt   = if ($wantTask) { Ask ' Time for the daily export (laptop clock, HH:mm)' '17:15' } else { $null }
if ($taskAt -and $taskAt -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Say " '$taskAt' is not HH:mm - using 17:15." Yellow; $taskAt = '17:15' }

# --- 3. Prerequisite modules
$az = 'Az.Accounts', 'Az.Compute', 'Az.ResourceGraph'
$missing = @($az | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
if ($missing -and -not $Update) {
    Say "`n Missing modules: $($missing -join ', ') (needed for Azure steps only)" Yellow
    if (AskYes ' Install them now for your user (Install-Module -Scope CurrentUser)' 'Y') {
        try { Install-Module $missing -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop; Say ' Az modules installed.' Green }
        catch { Say " WARNING: Install-Module failed: $($_.Exception.Message). Azure steps will ask again; install later with: Install-Module $($missing -join ', ') -Scope CurrentUser" Yellow }
    }
}

# --- 4. Copy the module (both PowerShell editions)
$docs = [Environment]::GetFolderPath('MyDocuments')
$targets = @((Join-Path $docs "WindowsPowerShell\Modules\VmMaintenance\$ver"), (Join-Path $docs "PowerShell\Modules\VmMaintenance\$ver"))
foreach ($t in $targets) {
    if (Test-Path $t) { Remove-Item $t -Recurse -Force }
    New-Item -ItemType Directory -Path $t -Force | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $t -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $repo 'config\config.example.psd1') -Destination (Join-Path $t 'Resources\config.example.psd1') -Force
    Say " Module -> $t" Green
}

# --- 5. vmm command
$app = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'VmMaintenance'
$bin = Join-Path $app 'bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'Scripts\vmm.ps1') -Destination $bin -Force
@'
@echo off
rem vmm launcher: PowerShell 7 when installed, else Windows PowerShell 5.1
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0vmm.ps1" %*
) else (
  powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0vmm.ps1" %*
)
'@ | Set-Content -LiteralPath (Join-Path $bin 'vmm.cmd') -Encoding ASCII
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $bin) {
    [Environment]::SetEnvironmentVariable('Path', ($(if ($userPath) { "$userPath;" }) + $bin), 'User')
    Say " Added $bin to your user PATH (open a new terminal to use 'vmm')" Green
}
$env:Path = "$env:Path;$bin"

# Shortcuts: target the installed launcher, never the folder this installer runs from
if (-not $Update) { if ($wantLinks) { Remove-Item -LiteralPath $noLinks -Force -ErrorAction SilentlyContinue } else { Set-Content -LiteralPath $noLinks -Value 'shortcuts declined at install' -Encoding ASCII } }
if ($wantLinks) {
    try {
        $ws = New-Object -ComObject WScript.Shell
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        foreach ($d in $linkDirs) {
            $lnk = $ws.CreateShortcut((Join-Path $d $linkName))
            $lnk.TargetPath = Join-Path $bin 'vmm.cmd'
            $lnk.WorkingDirectory = $env:USERPROFILE
            $lnk.Description = 'VmMaintenance fleet console (vmm)'
            $lnk.IconLocation = "$ps,0"
            $lnk.Save()
        }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ws)
        Say " Shortcuts: $($linkDirs -join ', ') -> $linkName" Green
    } catch { Say " WARNING: could not create shortcuts: $($_.Exception.Message). Start it with: vmm" Yellow }
}

# --- 6. Config + encrypted store
Import-Module (Join-Path $targets[0] 'VmMaintenance.psd1') -Force
Initialize-VmmConfig
Import-VmmConfig | Out-Null
if ($Update) {
    Say " Updated to $ver. Settings, encrypted data and reports were not touched." Green
    exit 0
}
# First-run UI: warnings (type YES) + every option page by page (incl. GitHub), validated, saved at the end
& (Get-Module VmMaintenance) { param($p) $script:VmmInstallSource = $p } $repo
Start-VmmSetupWizard -AcceptDefaults:$AcceptDefaults
$m = Get-Module VmMaintenance
& $m { Save-VmmStore -Store (Read-VmmStore); $s = Read-VmmStore; if ($null -eq $s) { throw 'store self-test failed' } }
Say ' Encrypted store ready and self-tested (write + read back).' Green

# --- 7. Daily report task (no stored password: runs only while you are logged on)
if ($wantTask) {
    try {
        $act = New-ScheduledTaskAction -Execute (Join-Path $bin 'vmm.cmd') -Argument 'report'
        $trg = New-ScheduledTaskTrigger -Daily -At $taskAt
        $pri = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName 'VmMaintenance daily report' -Action $act -Trigger $trg -Principal $pri -Force | Out-Null
        Say " Daily report task registered at $taskAt (laptop time)." Green
    } catch { Say " WARNING: could not register the scheduled task: $($_.Exception.Message). Export by hand: vmm report" Yellow }
}

# --- 8. Smoke test
if (AskYes "`n Run the smoke test now (read-only, about 10 seconds)" 'Y') {
    & (Join-Path $repo 'Tools\Invoke-SmokeTest.ps1')
}

Say "`n Done. Open a NEW terminal and run:  vmm" Cyan
Say ' First steps: vmm > 0 Import hosts, V VPN, 3 Check fleet now, 1 Plan today. Host agent: open a host, X.' Gray
Say " Your settings: $env:APPDATA\VmMaintenance\config.psd1   Data (encrypted): $app\data" DarkGray
