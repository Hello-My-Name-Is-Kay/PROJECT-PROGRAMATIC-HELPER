<#
.SYNOPSIS
    VmMaintenance EXTRACTOR - takes a read-only snapshot of THIS host and saves it as one encrypted file.
    (The Manager is vmm on your laptop; it builds this file and reads what it extracts.)
.DESCRIPTION
    Use it only for hosts the laptop cannot read over its own terminal (vmm snapshot tries that first).

    1. Paste this file on the host's desktop (the Manager put it on your clipboard).
    2. Right-click it > Run with PowerShell. (Or: powershell.exe -NoProfile -ExecutionPolicy Bypass -File <file>.
       Bypass applies to this one process only; nothing on the host is reconfigured.)
    3. It reads the host and saves VMM_<HOST>_<time>.vmm on this desktop. Copy that file to your laptop's
       Desktop or Downloads: the Manager imports it by itself.

    SNAPSHOT (the default, and the only thing a snapshot extractor can do):
      - Reads: OS, language, build, platform, C: size and free space, pending reboot, SQL instances, domain,
        Windows licence state, security/monitoring agents (state, version), legacy TLS, staged file names.
      - Writes exactly ONE thing on the host: the result file on this desktop (and the same text on the
        clipboard, unless -NoClipboard). No folder, no log, no registry change, no service change, no install,
        no network connection. Needs no administrator rights.
      - Each read is independent: one that fails is listed in the result (Problem=...) and the rest still go.
      - The result is ENCRYPTED for your laptop only (RSA-OAEP + AES-256 + HMAC-SHA256).
      - "Finish" deletes this file and its result files from the host.

    STEPS (second priority; only in a per-host extractor built with Extractor.AllowSteps = true):
      the code between VMM-STEPS-BEGIN and VMM-STEPS-END. It adds the workflow steps (check, stage, extend C:,
      start the upgrade, verify) with the same time and override rules as the laptop, and keeps a sanitized
      log in C:\Temp\VmmAgent. A snapshot extractor is built WITHOUT that block: it holds no code that can
      change a host.

    Compatible with Windows PowerShell 2.0 to 5.1.

    [SEC] Treat everything shown here as business data carried over the VPN: do not copy it anywhere
    other than the vmm Manager on your laptop.
.PARAMETER Extract
    No menu: take the snapshot, save the result file on the desktop, exit.
.PARAMETER Finish
    No menu: delete this file and its result files from the host.
.PARAMETER NoClipboard
    Leave the host's clipboard alone (the result file is still saved).
.PARAMETER NoColor
    Plain output (for consoles that render colours badly).
.PARAMETER WorkDir
    Steps mode only: work folder (default C:\Temp\VmmAgent). Removed by Finish.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VmmExtractor.ps1
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VmmExtractor.ps1 -Extract -NoClipboard
#>
param(
    [switch]$Extract,
    [switch]$Finish,
    [switch]$NoClipboard,
    [switch]$NoColor,
    [string]$WorkDir = 'C:\Temp\VmmAgent'
)

$AgentVersion = '2.14.0'
$CardText = ''   # VMM-CARD (filled in by Export-VmmHostAgent on the laptop; empty = generic agent)

$ErrorActionPreference = 'Stop'
$Script:SelfPath = $MyInvocation.MyCommand.Path
$Script:Inv = [Globalization.CultureInfo]::InvariantCulture
$Script:Problems = @()   # reads that failed during the snapshot (sent to the laptop as Problem= lines)

# ============================================================== output
function Say([string]$Text, [string]$Color) {
    if ($NoColor -or -not $Color) { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
}
function Info([string]$t) { Say $t 'DarkCyan' }   # the one accent (titles); green/orange/red are for statuses
function Good([string]$t) { Say $t 'Green' }
function Warn([string]$t) { Say $t 'DarkYellow' }
function Bad([string]$t)  { Say $t 'Red' }
function Mute([string]$t) { Say $t 'DarkGray' }

# ============================================================== sanitizing
# [SEC] Everything shown in an error, sent as a Problem line or written to the steps log passes through here.
function Protect-Text([string]$Text) {
    if (-not $Text) { return '' }
    $t = $Text
    $t = $t -replace '(?i)(password|pwd|passwd|secret|token|apikey|api_key|client_secret)\s*[=:]\s*[^;\s]+', '$1=***'
    $t = $t -replace '\\\\[^\\\s]+\\[^\s''"]*', '\\<share>\...'
    $t = $t -replace '\b(?:\d{1,3}\.){3}\d{1,3}\b', '<ip>'
    $t = $t -replace '\b[\w\.-]+@[\w\.-]+\.\w+\b', '<email>'
    if ($env:USERNAME) { $t = $t -replace [regex]::Escape($env:USERNAME), '<user>' }
    if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME) { $t = $t -replace [regex]::Escape($env:USERDOMAIN), '<domain>' }
    $t = $t -replace '[\r\n\t|]+', ' '
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300) + '...' }
    $t
}
function Add-Problem([string]$What, $Err) {
    # A read that failed: remembered for the result, the snapshot carries on.
    $m = ''
    if ($Err) { try { $m = $Err.Exception.Message } catch { $m = "$Err" } }
    $t = Protect-Text ($What + ': ' + $m)
    if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
    $Script:Problems += $t
}
function Num($v) { if ($null -eq $v) { '' } else { ([double]$v).ToString($Script:Inv) } }

# ============================================================== card (settings from the laptop)
function Read-Card {
    $c = @{
        Host = ''; Generated = ''; ValidHours = '48'; TimeZoneId = 'GMT Standard Time'
        BusinessDays = 'Monday,Tuesday,Wednesday,Thursday,Friday'; BusinessStart = '08:00'; BusinessEnd = '17:00'
        OffHoursWeekdays = 'True'; Holidays = ''; OkGB = '40'; CriticalGB = '32'; TargetFolder = 'C:\Temp'
        ExpectedOs = '*Server 2019*'; UpgradeCommand = ''; Share = ''; PublicKey = ''; Platform = ''; AzureVm = 'No'
        TargetOs = '*Server 2019*'; PolicyScope = ''; PolicyWhy = ''; PolicyWarnings = ''
        Steps = @{}; Packages = @()
        Mode = 'Snapshot'   # 'Steps' only in a per-host extractor built with Extractor.AllowSteps
        Licence = 'True'    # 'False' = skip the Windows licence query (it wakes the Software Protection service)
        # Inventory agent columns: service Name/DisplayName wildcards (the plan replaces these with the laptop's list)
        Services = @{ Qualys = @('QualysAgent', 'Qualys*'); CrowdStrike = @('CSFalconService', 'CrowdStrike*'); Zabbix = @('Zabbix Agent*', 'Zabbix*')
                      Ivanti = @('*Ivanti*', '*LANDesk*'); LansweeperAgent = @('LansweeperAgentService', 'Lansweeper*Agent*') }
        # Agent health checks (the plan replaces these with the laptop's InventoryFields.psd1 + Agents settings)
        Agents = @{
            Qualys          = @{ Services = @('QualysAgent', 'Qualys*'); Products = @('Qualys Cloud Security Agent*', 'Qualys*Agent*'); Drivers = @(); Ports = @(); Log = 'C:\ProgramData\Qualys\QualysAgent\Log.txt'; LogMaxAgeHours = '48'; MinVersion = '' }
            CrowdStrike     = @{ Services = @('CSFalconService', 'CrowdStrike*'); Products = @('CrowdStrike Windows Sensor*', 'CrowdStrike*Sensor*'); Drivers = @('CSAgent'); Ports = @(); Log = ''; LogMaxAgeHours = '48'; MinVersion = '' }
            Zabbix          = @{ Services = @('Zabbix Agent*', 'Zabbix*'); Products = @('Zabbix Agent*'); Drivers = @(); Ports = @('10050'); Log = ''; LogMaxAgeHours = '48'; MinVersion = '' }
            Ivanti          = @{ Services = @('*Ivanti*', '*LANDesk*'); Products = @('*Ivanti*Agent*', '*LANDesk*Agent*'); Drivers = @(); Ports = @(); Log = ''; LogMaxAgeHours = '48'; MinVersion = '' }
            LansweeperAgent = @{ Services = @('LansweeperAgentService', 'Lansweeper*Agent*'); Products = @('LsAgent*', 'Lansweeper*Agent*'); Drivers = @(); Ports = @(); Log = ''; LogMaxAgeHours = '48'; MinVersion = '' }
        }
    }
    if (-not $CardText) { return $c }
    try {
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CardText))
    } catch {
        Bad 'The embedded plan is damaged. Running as a generic agent. Export the agent again from the laptop.'
        return $c
    }
    foreach ($line in ($text -split "`n")) {
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $line.Substring(0, $i); $v = $line.Substring($i + 1).TrimEnd("`r")
        if ($k -like 'Step.*') { $c.Steps[$k.Substring(5)] = $v }
        elseif ($k -eq 'Package') { $c.Packages += $v }
        elseif ($k -like 'Svc.*') {
            if (-not $svcSeen) { $c.Services = @{}; $svcSeen = $true }
            $c.Services[$k.Substring(4)] = @($v -split ';' | Where-Object { $_ })
        }
        elseif ($k -match '^Agt\.([A-Za-z0-9]+)\.([A-Za-z]+)$') {
            # Agt.<Key>.<Field>=value (lists separated by ;)
            if (-not $agtSeen) { $c.Agents = @{}; $agtSeen = $true }
            $ak = $Matches[1]; $af = $Matches[2]
            if (-not $c.Agents.ContainsKey($ak)) { $c.Agents[$ak] = @{ Services = @(); Products = @(); Drivers = @(); Ports = @(); Log = ''; LogMaxAgeHours = '48'; MinVersion = '' } }
            if ($af -eq 'Services' -or $af -eq 'Products' -or $af -eq 'Drivers' -or $af -eq 'Ports') { $c.Agents[$ak][$af] = @($v -split ';' | Where-Object { $_ }) }
            else { $c.Agents[$ak][$af] = $v }
        }
        else { $c[$k] = $v }
    }
    $c
}
$Card = Read-Card

# ============================================================== reads (all read-only)
function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-FileSha256([string]$Path) {
    $sha = New-Object Security.Cryptography.SHA256Managed
    $fs = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '') }
    finally { $fs.Close(); $sha.Clear() }
}
function Get-PackageState {
    $res = @()
    foreach ($p in $Card.Packages) {
        $f = $p -split '\|'
        if ($f.Count -lt 4) { continue }
        $file = Join-Path $Card.TargetFolder $f[1]
        $state = 'Missing'
        if (Test-Path -LiteralPath $file) {
            $state = 'Present'
            # Hashing a multi-GB image is heavy disk work: only in steps mode, never for a snapshot
            if ($f[2] -and $Script:StepsMode) {
                try { if ((Get-FileSha256 $file) -eq $f[2].ToUpper()) { $state = 'Verified' } else { $state = 'HashMismatch' } }
                catch { $state = 'Unreadable' }
            }
        }
        $res += New-Object PSObject -Property @{ Name = $f[0]; File = $file; Sha256 = $f[2]; Rel = $f[3]; State = $state }
    }
    $res
}
function Read-Events {
    # The steps log, when a steps extractor ran here before. Read only.
    $out = @()
    try {
        $f = Join-Path $WorkDir 'agent.log'
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        foreach ($l in (Get-Content -LiteralPath $f)) {
            $p = $l -split '\|', 4
            if ($p.Count -eq 4) { $out += New-Object PSObject -Property @{ At = $p[0]; Step = $p[1]; Status = $p[2]; Note = $p[3] } }
        }
    } catch { }
    $out
}
function Get-AgentVerdict($Svc, $Version, $DriversDown, $PortsClosed, $LogAgeH, $Spec) {
    # OK / WARN / FAIL for one agent (Qualys, CrowdStrike...) from facts read on the host or over WMI.
    # PowerShell 2.0+, no WMI here: the laptop's fleet check uses this same function.
    #   FAIL: not installed, service not running, required driver not running
    #   WARN: start type not Automatic, port not listening/reachable, log not written for LogMaxAgeHours,
    #         version below MinVersion
    $issues = @(); $status = 'OK'
    if (-not $Svc) {
        return @{ Status = 'FAIL'; State = 'Not installed'; StartMode = ''; Version = "$Version"; Issues = 'service not found'; Text = 'FAIL - Not installed' }
    }
    if ("$($Svc.State)" -ne 'Running') { $status = 'FAIL'; $issues += ('service ' + $Svc.Name + ' is ' + $Svc.State) }
    if ($Svc.StartMode -and "$($Svc.StartMode)" -notmatch '^Auto') {
        if ($status -eq 'OK') { $status = 'WARN' }
        $issues += ('start type ' + $Svc.StartMode + ' (will not start after a reboot)')
    }
    foreach ($d in @($DriversDown)) { if ($d) { $status = 'FAIL'; $issues += ('driver ' + $d + ' not running') } }
    foreach ($p in @($PortsClosed)) { if ($p) { if ($status -eq 'OK') { $status = 'WARN' }; $issues += ('port ' + $p) } }
    $maxH = 48
    if ($Spec -and $Spec.LogMaxAgeHours) { try { $maxH = [double]$Spec.LogMaxAgeHours } catch { } }
    if ($null -ne $LogAgeH -and $LogAgeH -gt $maxH) {
        if ($status -eq 'OK') { $status = 'WARN' }
        $issues += ('log not written for ' + [int]$LogAgeH + ' h')
    }
    if ($Version -and $Spec -and $Spec.MinVersion) {
        $a = $null; $b = $null
        try { $a = New-Object Version (("$Version" -replace '[^\d\.].*$', '').Trim('.')); $b = New-Object Version ("$($Spec.MinVersion)") } catch { }
        if ($a -and $b -and $a -lt $b) {
            if ($status -eq 'OK') { $status = 'WARN' }
            $issues += ('version below ' + $Spec.MinVersion)
        }
    }
    $t = $status + ' - ' + $Svc.State
    if ($Version) { $t += ', v' + $Version } else { $t += ', version unknown' }
    if ($issues.Count) { $t += ': ' + ($issues -join '; ') }
    @{ Status = $status; State = "$($Svc.State)"; StartMode = "$($Svc.StartMode)"; Version = "$Version"; Issues = ($issues -join '; '); Text = $t }
}
function Get-InvProbe($Services, $Agents, $SkipLicence) {
    # Inventory columns readable on this host (PowerShell 2.0+, read-only). Returns 'Inv.<Key>=<value>' lines,
    # 'Agent.<Key>=Status|State|StartMode|Version|Issues' per agent when $Agents (health specs) is given, and a
    # 'Problem=<what>: <why>' line for each read that failed (the other reads still run).
    # Also pasted into the RDP collector by the laptop, so it must stay self-contained (with Get-AgentVerdict).
    $out = @()
    $why = { param($e) $m = ''; try { $m = "$($e.Exception.Message)" } catch { }; $m = $m -replace '[\r\n|]+', ' '; if ($m.Length -gt 100) { $m = $m.Substring(0, 100) }; $m }
    try {
        $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction Stop
        $dom = "$($cs.Domain)"
        if (-not $cs.PartOfDomain) { $dom = 'WORKGROUP (' + $dom + ')' }
        $out += 'Inv.Domain=' + $dom
        $dc = 'No'
        if ($cs.DomainRole -ge 4) { $dc = 'Yes' }
        $out += 'Inv.DomainController=' + $dc
    } catch { $out += 'Problem=Domain: ' + (& $why $_) }
    try {
        $ip = ''
        foreach ($a in @(Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop)) {
            foreach ($x in @($a.IPAddress)) { if (-not $ip -and "$x" -match '^\d{1,3}(\.\d{1,3}){3}$' -and "$x" -notmatch '^(127|169\.254)\.') { $ip = "$x" } }
        }
        $out += 'Inv.IPAddress=' + $ip
    } catch { $out += 'Problem=IP address: ' + (& $why $_) }
    if (-not $SkipLicence) {
        $lic = 'Unknown (run slmgr /dli)'
        $names = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'Grace period (OOB)'; 3 = 'Grace period (OOT)'; 4 = 'Grace period (non-genuine)'; 5 = 'Notification'; 6 = 'Grace period (extended)' }
        try {
            $p = @(Get-WmiObject SoftwareLicensingProduct -Filter "Name LIKE 'Windows%' AND PartialProductKey IS NOT NULL" -ErrorAction Stop)
            if ($p.Count) { $lic = $names[[int]$p[0].LicenseStatus] } else { $lic = 'No product key installed' }
        } catch { $out += 'Problem=Windows licence: ' + (& $why $_) }
        $out += 'Inv.WindowsLicense=' + $lic
    }
    $svc = $null
    try { $svc = @(Get-WmiObject Win32_Service -ErrorAction Stop) } catch { $out += 'Problem=Services (agent columns left empty): ' + (& $why $_) }
    if ($null -ne $svc -and $Agents -and $Agents.Count) {
        # Installed programs (name + version) from both Uninstall keys, read once (never the WMI product class: querying it starts MSI repairs)
        $apps = @()
        foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
            foreach ($i in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
                $pp = Get-ItemProperty $i.PSPath -ErrorAction SilentlyContinue
                if ($pp -and $pp.DisplayName) { $apps += New-Object PSObject -Property @{ Name = "$($pp.DisplayName)"; Version = "$($pp.DisplayVersion)" } }
            }
        }
        $listen = ''
        try { $listen = (& netstat.exe -an) -join "`n" } catch { }
        foreach ($k in $Agents.Keys) {
            try {
                $sp = $Agents[$k]
                $pats = @($sp.Services); if ($Services -and $Services[$k]) { $pats = @($Services[$k]) }
                $hit = $null
                foreach ($pat in $pats) { if (-not $hit -and $pat) { $hit = $svc | Where-Object { $_.Name -like $pat -or $_.DisplayName -like $pat } | Select-Object -First 1 } }
                $ver = ''; $dd = @(); $pc = @(); $age = $null
                if ($hit) {
                    foreach ($pat in @($sp.Products)) { if (-not $ver -and $pat) { $a = $apps | Where-Object { $_.Name -like $pat -and $_.Version } | Select-Object -First 1; if ($a) { $ver = $a.Version } } }
                    if (-not $ver -and $hit.PathName) {
                        $exe = ''
                        if ("$($hit.PathName)" -match '^\s*"([^"]+)"') { $exe = $Matches[1] } elseif ("$($hit.PathName)" -match '^\s*(\S+\.exe)') { $exe = $Matches[1] }
                        if ($exe -and (Test-Path -LiteralPath $exe)) { try { $ver = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } catch { } }
                    }
                    foreach ($d in @($sp.Drivers)) { if ($d) { $dr = Get-WmiObject Win32_SystemDriver -Filter ("Name='" + $d + "'") -ErrorAction SilentlyContinue; if (-not $dr -or $dr.State -ne 'Running') { $dd += $d } } }
                    # Listening on any address (language-neutral: the foreign address column is the any-address with port 0)
                    if ($listen) { foreach ($p in @($sp.Ports)) { if ($p -and $listen -notmatch (':' + $p + '\s+(0\.0\.0\.0|\[::\]):0\s')) { $pc += ("$p not listening") } } }
                    if ($sp.Log -and (Test-Path -LiteralPath $sp.Log)) { $age = ((Get-Date) - (Get-Item -LiteralPath $sp.Log).LastWriteTime).TotalHours }
                }
                $v = Get-AgentVerdict $hit $ver $dd $pc $age $sp
                $out += 'Inv.' + $k + '=' + $v.Text
                $out += 'Agent.' + $k + '=' + $v.Status + '|' + $v.State + '|' + $v.StartMode + '|' + $v.Version + '|' + $v.Issues
            } catch { $out += 'Problem=Agent ' + $k + ': ' + (& $why $_) }
        }
    } elseif ($null -ne $svc -and $Services) {
        foreach ($k in $Services.Keys) {
            $hit = $null
            foreach ($pat in @($Services[$k])) { if (-not $hit) { $hit = $svc | Where-Object { $_.Name -like $pat -or $_.DisplayName -like $pat } | Select-Object -First 1 } }
            $v = 'Not installed'
            if ($hit) { if ($hit.State -eq 'Running') { $v = 'Running' } else { $v = 'Installed (' + $hit.State + ')' } }
            $out += 'Inv.' + $k + '=' + $v
        }
    }
    $on = @()
    foreach ($t in '1.0', '1.1') {
        $e = $null
        try { $e = (Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS ' + $t + '\Server') -Name Enabled -ErrorAction Stop).Enabled } catch { }
        if ($e -ne 0) { $on += ('TLS ' + $t) }   # no key = Windows default = enabled
    }
    if ($on.Count) { $out += ('Inv.TlsLegacyDisabled=No (' + ($on -join ', ') + ' enabled)') } else { $out += 'Inv.TlsLegacyDisabled=Yes' }
    $out
}
function Get-Facts {
    # Each read stands alone: one that fails leaves its fields empty, is listed as a Problem, and the rest still run.
    $f = @{
        Name = $env:COMPUTERNAME; OS = ''; Lang = ''; Version = ''; Build = ''; SP = ''; Manufacturer = ''; Model = ''
        Platform = 'Unknown'; CTotalGB = $null; CFreeGB = $null; PendingReboot = $false; Sql = ''; LastBoot = ''
        TempExists = $false; PSVersion = "$($PSVersionTable.PSVersion)"; Admin = $false
    }
    try { $f.Admin = (Test-Admin) } catch { }
    try {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
        $f.OS = "$($os.Caption)".Trim(); $f.Version = $os.Version; $f.Build = $os.BuildNumber; $f.SP = $os.ServicePackMajorVersion
        try { $f.Lang = (New-Object Globalization.CultureInfo([int]$os.OSLanguage)).Name } catch { }
        try { $f.LastBoot = $os.ConvertToDateTime($os.LastBootUpTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { }
    } catch { Add-Problem 'Operating system' $_ }
    try {
        $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction Stop
        $f.Manufacturer = $cs.Manufacturer; $f.Model = $cs.Model
        $f.Platform = 'Physical'
        if ($cs.Manufacturer -like '*VMware*' -or $cs.Model -like '*VMware*') { $f.Platform = 'VMware' }
        elseif ($cs.Model -like '*Virtual Machine*') {
            $f.Platform = 'Hyper-V'
            if (Get-Service -Name WindowsAzureGuestAgent -ErrorAction SilentlyContinue) { $f.Platform = 'Azure' }
        }
    } catch { Add-Problem 'Computer model' $_ }
    try {
        $c = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $f.CTotalGB = [math]::Round($c.Size / 1GB, 1); $f.CFreeGB = [math]::Round($c.FreeSpace / 1GB, 1)
    } catch { Add-Problem 'C: drive' $_ }
    try {
        $sql = @()
        $k = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
        if (Test-Path $k) {
            $props = Get-ItemProperty $k
            foreach ($n in ($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
                try {
                    $s = Get-ItemProperty ('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\' + $n.Value + '\Setup')
                    $sql += ($n.Name + ' ' + $s.PatchLevel + ' ' + $s.Edition)
                } catch { $sql += ($n.Name + ' (setup key unreadable)') }
            }
        }
        $f.Sql = ($sql -join '; ')
    } catch { Add-Problem 'SQL instances' $_ }
    try {
        # Pending reboot: servicing, Windows Update, file renames queued for the next boot (same three as the laptop check)
        $pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        if (-not $pend) {
            $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
            if ($sm -and $sm.PendingFileRenameOperations) { $pend = $true }
        }
        $f.PendingReboot = $pend
    } catch { Add-Problem 'Pending reboot' $_ }
    try { $f.TempExists = (Test-Path $Card.TargetFolder) } catch { }
    New-Object PSObject -Property $f
}

# ============================================================== OS policy
# Goal: Windows Server 2019 everywhere. Client OS (Windows 10/11...) is not touched without orders.
# Management is warned about Windows Server 2008 (not R2) and physical machines.
function Get-Policy($Facts) {
    $scope = $Card.PolicyScope; $why = $Card.PolicyWhy
    if (-not $scope -or $scope -eq 'Unknown') {
        $scope = 'InScope'; $why = 'Upgrade to ' + $Card.TargetOs + '.'
        if ($Facts.OS -notlike '*Server*') { $scope = 'ClientOs'; $why = "Client OS ($($Facts.OS)): not touched without orders." }
        elseif ($Facts.OS -like $Card.TargetOs) { $scope = 'AtTarget'; $why = "Already on the target OS ($($Facts.OS))." }
        elseif ($Facts.OS -like '*Server 2022*' -or $Facts.OS -like '*Server 2025*') { $scope = 'NewerThanTarget'; $why = 'Newer than the target: never downgraded.' }
    }
    $warn = @()
    if ($Card.PolicyWarnings) { $warn = @($Card.PolicyWarnings -split ' / ') }
    else {
        if ($Facts.OS -like '*Server 2008*' -and $Facts.OS -notlike '*2008 R2*') { $warn += 'Windows Server 2008 (not R2): warn management before any change.' }
        if ($Facts.Platform -eq 'Physical') { $warn += 'Physical machine: warn management (no Azure snapshot or disk resize).' }
    }
    $ok = ($scope -eq 'InScope' -or $scope -eq 'ClientOsOrdered')
    New-Object PSObject -Property @{ Scope = $scope; Why = $why; Warnings = $warn; Workable = $ok }
}

# VMM-STEPS-BEGIN
# Everything down to VMM-STEPS-END is the STEPS code: the only part of this file that can change a host.
# A snapshot extractor is built without this block.

# ============================================================== steps: work folder and log
function Initialize-WorkDir {
    if (Test-Path -LiteralPath $WorkDir) { return }
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    # [SEC] Only Administrators, SYSTEM and the current user (by SID, no names) can read the folder.
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $null = & icacls.exe $WorkDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' "*${me}:(OI)(CI)F" 2>&1
    } catch { Warn 'Could not restrict the work folder permissions (icacls failed). Contents are sanitized anyway.' }
}
function Write-Event([string]$Step, [string]$Status, [string]$Note) {
    Initialize-WorkDir
    $line = '{0}|{1}|{2}|{3}' -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'), $Step, $Status, (Protect-Text $Note)
    Add-Content -LiteralPath (Join-Path $WorkDir 'agent.log') -Value $line -Encoding ASCII
}

# ============================================================== steps: time rules (Europe/Lisbon by default)
function Get-Window {
    $known = $true; $now = [DateTime]::UtcNow
    try {
        $tz = [TimeZoneInfo]::FindSystemTimeZoneById($Card.TimeZoneId)
        $now = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz)
    } catch { $known = $false }
    $days = $Card.BusinessDays -split ','
    $hol  = $Card.Holidays -split ','
    $start = [TimeSpan]::Parse($Card.BusinessStart); $end = [TimeSpan]::Parse($Card.BusinessEnd)
    $isBiz = ($days -contains $now.DayOfWeek.ToString()) -and -not ($hol -contains $now.ToString('yyyy-MM-dd'))
    $inHours = $isBiz -and $now.TimeOfDay -ge $start -and $now.TimeOfDay -lt $end
    $allowed = $true
    if ($inHours) { $allowed = $false }
    elseif ($isBiz -and $Card.OffHoursWeekdays -ne 'True') { $allowed = $false }
    $why = 'Maintenance window: changes allowed.'
    if (-not $known) { $allowed = $false; $why = "Time zone '$($Card.TimeZoneId)' unknown on this host: treated as business hours (changes need an override)." }
    elseif (-not $allowed) { $why = "Business hours ($($Card.BusinessStart)-$($Card.BusinessEnd) $($Card.TimeZoneId)): only checks and staging to $($Card.TargetFolder)." }
    New-Object PSObject -Property @{ Now = $now; Known = $known; ChangesAllowed = $allowed; Why = $why }
}

# ============================================================== steps: plan
$StepNames = @('Precheck', 'Stage', 'PreSnapshot', 'ExpandDisk', 'Upgrade', 'Verify')
function Get-LastStatus([string]$Step) {
    $ev = @(Read-Events | Where-Object { $_.Step -eq $Step })
    if ($ev.Count) { return $ev[$ev.Count - 1].Status + ' (here)' }
    if ($Card.Steps.ContainsKey($Step)) { return (($Card.Steps[$Step] -split '\|')[0]) + ' (laptop)' }
    '-'
}
function Test-Done([string]$Step) { (Get-LastStatus $Step) -match '^(Success|NotNeeded|Launched)' }

function Get-Plan($Facts) {
    $w = Get-Window
    $pol = Get-Policy $Facts
    $admin = $Facts.Admin
    $pk = @(Get-PackageState)
    $staged = ($pk.Count -gt 0) -and -not ($pk | Where-Object { $_.State -ne 'Verified' -and $_.State -ne 'Present' })
    $okGB = [double]::Parse($Card.OkGB, $Script:Inv); $critGB = [double]::Parse($Card.CriticalGB, $Script:Inv)
    $plan = @()
    foreach ($s in $StepNames) {
        $can = $true; $why = ''; $class = 'ReadOnly'
        switch ($s) {
            'Precheck' { $why = 'Read-only. Allowed any time.' }
            'Stage' {
                $class = 'Staging'
                if (-not $Card.Packages.Count) { $can = $false; $why = 'No files in the plan. Check the media repository on the laptop (vmm media), run Check so the host language is known, then export the agent again.' }
                elseif ($staged) { $why = 'All packages already in ' + $Card.TargetFolder + '. Re-run only to re-verify.' }
                else { $why = 'Staging to ' + $Card.TargetFolder + ' is allowed any time (also in business hours).' }
            }
            'PreSnapshot' {
                $class = 'Change'
                if ($Card.AzureVm -eq 'Yes') { $can = $false; $why = 'Azure VM: the snapshot is taken from the laptop (vmm step -Step PreSnapshot), not from inside the host.' }
                else { $why = 'Not Azure: take the snapshot/backup in the platform console, then confirm here.' }
            }
            'ExpandDisk' {
                $class = 'Change'
                if ($Facts.CFreeGB -ge $okGB) { $can = $false; $why = "Not needed: C: has $($Facts.CFreeGB) GB free (target $okGB GB)." }
                elseif (-not (Test-Done 'PreSnapshot')) { $can = $false; $why = 'Needs a rollback snapshot first (PreSnapshot not done).' }
                elseif (-not $admin) { $can = $false; $why = 'Needs an elevated PowerShell (Run as administrator).' }
                else { $why = 'Extends C: into unallocated space. Grow the virtual disk first (laptop for Azure, platform console otherwise).' }
            }
            'Upgrade' {
                $class = 'Change'
                if (-not (Test-Done 'PreSnapshot')) { $can = $false; $why = 'Needs a rollback snapshot first (PreSnapshot not done).' }
                elseif ($Card.Packages.Count -and -not $staged) { $can = $false; $why = 'Install files not staged/verified in ' + $Card.TargetFolder + '.' }
                elseif ($Facts.CFreeGB -lt $critGB) { $can = $false; $why = "C: has $($Facts.CFreeGB) GB free, below the $critGB GB minimum. Run ExpandDisk first." }
                elseif ($Facts.PendingReboot) { $can = $false; $why = 'A reboot is pending. Reboot (in the window) and run Precheck again.' }
                elseif (-not $admin) { $can = $false; $why = 'Needs an elevated PowerShell (Run as administrator).' }
                elseif (-not $Card.UpgradeCommand) { $why = 'No upgrade command in the plan: start setup by hand, then confirm here.' }
                else { $why = 'Starts the upgrade command from the plan. The host will reboot.' }
            }
            'Verify' { $why = 'Read-only. Compares the OS with the expected result.' }
        }
        if ($class -ne 'ReadOnly' -and -not $pol.Workable) { $can = $false; $why = 'Policy: ' + $pol.Why }
        elseif ($can -and $s -eq 'ExpandDisk' -and -not $w.ChangesAllowed) { $can = $false; $why = $w.Why + ' Disk expansion is after hours only (the VM is shut down).' }
        elseif ($can -and $class -eq 'Change' -and -not $w.ChangesAllowed) { $can = $false; $why = $w.Why + ' (override possible)' }
        $plan += New-Object PSObject -Property @{ Step = $s; Class = $class; Status = (Get-LastStatus $s); Available = $can; Why = $why }
    }
    $plan
}

# ============================================================== steps: confirmations
function Confirm-Change([string]$Step) {
    $w = Get-Window
    if (-not $w.ChangesAllowed) {
        Warn $w.Why
        Warn 'Override only with your manager''s agreement. Type OVERRIDE to continue, anything else cancels.'
        if ((Read-Host ' >') -cne 'OVERRIDE') { Mute 'Cancelled.'; return $false }
        $r = Read-Host ' Reason (who approved, why; 10+ characters)'
        if (-not $r -or $r.Trim().Length -lt 10) { Bad 'Override refused: reason too short.'; return $false }
        Write-Event $Step 'Override' $r
    }
    Warn "Type the host name ($env:COMPUTERNAME) to run $Step, anything else cancels."
    if ((Read-Host ' >') -ne $env:COMPUTERNAME) { Mute 'Cancelled.'; return $false }
    $true
}

# ============================================================== steps: actions
function Invoke-Check([string]$Step) {
    $f = Get-Facts
    Show-Facts $f
    $status = 'Success'; $note = "$($f.OS) b$($f.Build), C: $($f.CFreeGB) GB free, reboot pending: $($f.PendingReboot)"
    if ($Step -eq 'Verify' -and $Card.ExpectedOs -and -not ($f.OS -like $Card.ExpectedOs)) { $status = 'Failed'; $note = "OS is '$($f.OS)', expected '$($Card.ExpectedOs)'" }
    Write-Event $Step $status $note
    if ($status -eq 'Success') { Good "$Step recorded: $note" } else { Bad "$Step FAILED: $note" }
}
function Invoke-Stage {
    if (-not $Card.Packages.Count) { Warn 'No packages in the plan.'; return }
    if (-not (Test-Path -LiteralPath $Card.TargetFolder)) { New-Item -ItemType Directory -Path $Card.TargetFolder -Force | Out-Null; Info "Created $($Card.TargetFolder)" }
    $bad = 0
    foreach ($p in (Get-PackageState)) {
        if ($p.State -eq 'Verified' -or ($p.State -eq 'Present' -and -not $p.Sha256)) { Good "  $($p.Name): $($p.State)"; continue }
        $src = ''
        if ($Card.Share) { $src = Join-Path $Card.Share $p.Rel }
        if ($src -and (Test-Path -LiteralPath $src)) {
            Info "  Copying $($p.Name) from the share..."
            try { Copy-Item -LiteralPath $src -Destination $p.File -Force }
            catch { Bad ('  Copy failed: ' + (Protect-Text $_.Exception.Message)); $bad++; continue }
            if ($p.Sha256 -and (Get-FileSha256 $p.File) -ne $p.Sha256.ToUpper()) { Bad "  $($p.Name): hash mismatch after copy - file deleted."; Remove-Item -LiteralPath $p.File -Force; $bad++ }
            else { Good "  $($p.Name): copied$(if ($p.Sha256) { ' and verified' })" }
        } else {
            Bad "  $($p.Name): missing in $($Card.TargetFolder) and the share is not reachable from this host."
            Warn '  Copy it via the RDP clipboard / RDM file transfer into the folder above, then run Stage again.'
            $bad++
        }
    }
    if ($bad) { Write-Event 'Stage' 'Failed' "$bad package(s) missing or invalid" } else { Write-Event 'Stage' 'Success' 'all packages present and verified' }
}
function Invoke-PreSnapshotConfirm {
    if ($Card.AzureVm -eq 'Yes') { Warn 'Azure VM: take the snapshot from the laptop (vmm step -Step PreSnapshot).'; return }
    Info 'Take a snapshot/backup of this host in the platform console (vSphere, Hyper-V, backup tool).'
    Info "Name it $($env:COMPUTERNAME)_pre-upgrade_$((Get-Date).ToString('yyyyMMdd'))."
    Warn 'Type DONE only after the snapshot shows as completed.'
    if ((Read-Host ' >') -cne 'DONE') { Mute 'Not confirmed.'; return }
    Write-Event 'PreSnapshot' 'Success' 'operator confirmed snapshot/backup in the platform console'
    Good 'PreSnapshot recorded.'
}
function Invoke-Extend {
    if (-not (Confirm-Change 'ExpandDisk')) { return }
    $before = (Get-Facts).CTotalGB
    $tmp = Join-Path $WorkDir 'extend.txt'
    Initialize-WorkDir
    Set-Content -LiteralPath $tmp -Value @('rescan', 'select volume c', 'extend') -Encoding ASCII
    try { $out = & diskpart.exe /s $tmp 2>&1 | Out-String } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    $after = (Get-Facts).CTotalGB
    if ($after -gt $before) { Write-Event 'ExpandDisk' 'Success' "C: $before GB -> $after GB"; Good "C: extended: $before GB -> $after GB" }
    else {
        Write-Event 'ExpandDisk' 'Failed' 'C: did not grow (no unallocated space after C:, or a recovery partition is in the way)'
        Bad 'C: did not grow. Either the virtual disk was not enlarged yet, or a partition sits after C: (check diskmgmt.msc).'
        Mute (Protect-Text $out)
    }
}
function Invoke-Upgrade {
    if (-not (Confirm-Change 'Upgrade')) { return }
    if (-not $Card.UpgradeCommand) {
        Info 'Start setup from the staged files by hand now. Type STARTED once setup is running.'
        if ((Read-Host ' >') -ceq 'STARTED') { Write-Event 'Upgrade' 'Launched' 'started by operator' }
        return
    }
    Write-Event 'Upgrade' 'Launched' 'upgrade command started'
    Info 'Starting the upgrade command. The host will reboot during setup; run this agent again afterwards and choose Verify.'
    try { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $Card.UpgradeCommand -WorkingDirectory $Card.TargetFolder }
    catch { Write-Event 'Upgrade' 'Failed' $_.Exception.Message; Bad ('Could not start: ' + (Protect-Text $_.Exception.Message)) }
}

# ============================================================== steps: screens
function Show-Plan {
    $f = Get-Facts
    $plan = @(Get-Plan $f)
    $current = $null
    foreach ($p in $plan) { if (-not ($p.Status -match '^(Success|NotNeeded|Launched)')) { $current = $p.Step; break } }
    Info (' {0,-3} {1,-12} {2,-20} {3,-6} {4}' -f '', 'Step', 'Status', 'Now?', 'Why')
    $i = 1
    foreach ($p in $plan) {
        $mark = '   '; if ($p.Step -eq $current) { $mark = '>> ' }
        $now = 'no'; if ($p.Available) { $now = 'yes' }
        $col = 'Gray'
        if ($p.Status -match '^(Success|NotNeeded|Launched)') { $col = 'Green' } elseif ($p.Status -match '^(Failed|Blocked)') { $col = 'Red' } elseif (-not $p.Available) { $col = 'DarkGray' }
        Say (' {0}{1}. {2,-10} {3,-20} {4,-6} {5}' -f $mark, $i, $p.Step, $p.Status, $now, $p.Why) $col
        $i++
    }
    if ($current) { Info " Current step: $current. Steps below it are future steps." } else { Good ' All steps done. Export the result, then Finish.' }
    $plan
}
function Show-History {
    $ev = @(Read-Events)
    if (-not $ev.Count) { Mute ' Nothing logged on this host yet.'; return }
    Info (' {0,-21} {1,-12} {2,-10} {3}' -f 'UTC', 'Step', 'Status', 'Note')
    foreach ($e in $ev) {
        $c = 'Gray'; if ($e.Status -match 'Success|NotNeeded') { $c = 'Green' } elseif ($e.Status -match 'Failed') { $c = 'Red' } elseif ($e.Status -match 'Override') { $c = 'DarkYellow' }
        Say (' {0,-21} {1,-12} {2,-10} {3}' -f $e.At, $e.Step, $e.Status, $e.Note) $c
    }
    if ($Card.Steps.Count) {
        Info ' From the laptop (at export time)'
        foreach ($s in $StepNames) { if ($Card.Steps.ContainsKey($s)) { $p = $Card.Steps[$s] -split '\|', 3; Write-Host (' {0,-21} {1,-12} {2,-10} {3}' -f $p[1], $s, $p[0], $p[2]) } }
    }
}

function Invoke-RunMenu {
    $plan = @(Show-Plan)
    Write-Host ''
    $n = Read-Host ' Step number to run (Enter = back)'
    if (-not $n) { return }
    $idx = 0
    if (-not [int]::TryParse($n, [ref]$idx) -or $idx -lt 1 -or $idx -gt $plan.Count) { Bad ' Not a step number.'; return }
    $p = $plan[$idx - 1]
    if (-not $p.Available -and -not ($p.Why -like '*override possible*')) { Warn (' Not available: ' + $p.Why); return }
    switch ($p.Step) {
        'Precheck'    { Invoke-Check 'Precheck' }
        'Stage'       { Invoke-Stage }
        'PreSnapshot' { Invoke-PreSnapshotConfirm }
        'ExpandDisk'  { Invoke-Extend }
        'Upgrade'     { Invoke-Upgrade }
        'Verify'      { Invoke-Check 'Verify' }
    }
}
function Invoke-StepsMenu {
    while ($true) {
        Show-Header
        Write-Host ' 1 Status    live facts for this host'
        Write-Host ' 2 Steps     current and future steps, and why each is or is not available'
        Write-Host ' 3 Run       run a step from here'
        Write-Host ' 4 History   what this program did on this host'
        Write-Host ' 5 Export    save the result file on the desktop again'
        Write-Host ' 6 Finish    end of maintenance: remove the extractor and its files from this host'
        Write-Host ' Q Quit      keep files for the next session'
        $k = Read-Host ' Choice'
        Show-Header
        try {
            switch -Regex ($k) {
                '^1$' { Show-Facts (Get-Facts); Show-Inventory; Pause-Agent }
                '^2$' { [void](Show-Plan); Pause-Agent }
                '^3$' { Invoke-RunMenu; if ($Card.PublicKey) { Export-Result -Auto }; Pause-Agent }
                '^4$' { Show-History; Pause-Agent }
                '^5$' { Export-Result; Pause-Agent }
                '^6$' { if (Invoke-Finish) { return }; Pause-Agent }
                '^[qQ]$' { return }
            }
        } catch {
            # [SEC] Show the sanitized message only; no stack traces or paths with user names.
            Bad (' ERROR: ' + (Protect-Text $_.Exception.Message))
            try { Write-Event 'Agent' 'Error' $_.Exception.Message } catch { }
            Pause-Agent
        }
    }
}
# VMM-STEPS-END

# Steps run only when the block above is in this file AND the laptop built this extractor for steps.
$Script:StepsMode = ($Card.Mode -eq 'Steps') -and [bool](Get-Command Invoke-StepsMenu -ErrorAction SilentlyContinue)

# ============================================================== export (encrypted)
function Protect-Result([string]$Text) {
    # [SEC] Hybrid: random 64-byte key (AES-256 + HMAC-SHA256) wrapped with the laptop's RSA public key (OAEP).
    $plain = [Text.Encoding]::UTF8.GetBytes($Text)
    $keys = New-Object byte[] 64
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($keys)
    $ek = New-Object byte[] 32; $mk = New-Object byte[] 32
    [Array]::Copy($keys, 0, $ek, 0, 32); [Array]::Copy($keys, 32, $mk, 0, 32)
    $aes = New-Object Security.Cryptography.RijndaelManaged
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $aes.KeySize = 256; $aes.BlockSize = 128
        $aes.Mode = [Security.Cryptography.CipherMode]::CBC; $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $ek; $aes.GenerateIV()
        $ct = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString($Card.PublicKey)
        $wrapped = $rsa.Encrypt($keys, $true)
        $ms = New-Object IO.MemoryStream
        $hdr = [Text.Encoding]::ASCII.GetBytes('VMM2')
        $ms.Write($hdr, 0, 4)
        $ms.WriteByte([byte](($wrapped.Length -shr 8) -band 0xFF)); $ms.WriteByte([byte]($wrapped.Length -band 0xFF))
        $ms.Write($wrapped, 0, $wrapped.Length)
        $ms.Write($aes.IV, 0, 16)
        $ms.Write($ct, 0, $ct.Length)
        $body = $ms.ToArray()
        $h = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (, $mk)
        $mac = $h.ComputeHash($body)
        $all = New-Object byte[] ($body.Length + 32)
        [Array]::Copy($body, 0, $all, 0, $body.Length); [Array]::Copy($mac, 0, $all, $body.Length, 32)
        return ('VMM2|' + [Convert]::ToBase64String($all))
    } finally {
        [Array]::Clear($keys, 0, 64); [Array]::Clear($ek, 0, 32); [Array]::Clear($mk, 0, 32); [Array]::Clear($plain, 0, $plain.Length)
        $aes.Clear(); $rsa.Clear()
    }
}
function Save-ResultFile([string]$Line) {
    # Result file on this user's desktop, one per host: VMM_<HOST>_<yyyyMMdd_HHmm>.vmm (older ones replaced).
    $desk = [Environment]::GetFolderPath('Desktop')
    if (-not $desk -or -not (Test-Path -LiteralPath $desk)) { $desk = Join-Path $env:USERPROFILE 'Desktop' }
    Get-ChildItem -LiteralPath $desk -Filter ('VMM_' + $env:COMPUTERNAME + '_*.vmm') -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $file = Join-Path $desk ('VMM_' + $env:COMPUTERNAME + '_' + (Get-Date).ToString('yyyyMMdd_HHmm') + '.vmm')
    [IO.File]::WriteAllText($file, $Line, [Text.Encoding]::ASCII)
    $file
}
function Export-Result([switch]$Auto) {
    if ($Auto -and -not $Card.PublicKey) { Warn ' No laptop key in this file: nothing saved. Build the extractor on the laptop (vmm extractor).'; return }
    Info ' Reading this host (read-only)...'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $Script:Problems = @()
    $f = Get-Facts
    $Script:LastFacts = $f
    $mode = 'Snapshot'; if ($Script:StepsMode) { $mode = 'Steps' }
    $lines = @(
        'Name=' + $f.Name, 'OS=' + $f.OS, 'Lang=' + $f.Lang, 'Version=' + $f.Version, 'Build=' + $f.Build, 'SP=' + $f.SP,
        'Manufacturer=' + $f.Manufacturer, 'Model=' + $f.Model, 'Platform=' + $f.Platform,
        'CTotalGB=' + (Num $f.CTotalGB), 'CFreeGB=' + (Num $f.CFreeGB),
        'PendingReboot=' + $(if ($f.PendingReboot) { 'Yes' } else { 'No' }), 'Sql=' + $f.Sql, 'LastBoot=' + $f.LastBoot,
        'TempExists=' + $f.TempExists, 'PSVersion=' + $f.PSVersion, 'Elevated=' + $(if ($f.Admin) { 'Yes' } else { 'No' }),
        'Mode=' + $mode, 'AgentVersion=' + $AgentVersion, 'ExportedAt=' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    )
    $Script:LastInv = @()
    try {
        foreach ($l in @(Get-InvProbe $Card.Services $Card.Agents ($Card.Licence -eq 'False'))) {
            if ($l -like 'Problem=*') { $Script:Problems += (Protect-Text $l.Substring(8)) } else { $lines += $l; $Script:LastInv += $l }
        }
    } catch { Add-Problem 'Inventory columns' $_ }
    try { foreach ($p in (Get-PackageState)) { $lines += ('Package=' + $p.Name + '|' + $p.State) } } catch { Add-Problem 'Staged files' $_ }
    foreach ($e in (Read-Events)) { $lines += ('Event=' + $e.At + '|' + $e.Step + '|' + $e.Status + '|' + $e.Note) }
    foreach ($p in $Script:Problems) { $lines += ('Problem=' + $p) }
    $sw.Stop()
    $lines += ('Seconds=' + [int]$sw.Elapsed.TotalSeconds)
    $text = $lines -join "`n"
    if ($Card.PublicKey) {
        $out = Protect-Result $text
    } else {
        Warn 'This file has no laptop key: the result cannot be encrypted.'
        Warn 'Build the extractor on the laptop (vmm extractor) instead.'
        Warn 'Type PLAIN to produce an unencrypted line anyway (it carries host facts only), anything else cancels.'
        if ((Read-Host ' >') -cne 'PLAIN') { Mute 'Cancelled.'; return }
        $out = 'VMM1|' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
    }
    if ($Script:StepsMode) { try { Write-Event 'Export' 'Success' ('result exported (' + $out.Substring(0, 4) + ')') } catch { } }
    $file = $null
    try { $file = Save-ResultFile $out } catch { Warn (' Could not save the result file on the desktop: ' + (Protect-Text $_.Exception.Message)) }
    $clip = $false
    if (-not $NoClipboard) { try { $out | & clip.exe; $clip = $true } catch { } }
    Write-Host ''
    Show-Facts $f
    if ($Script:Problems.Count) {
        Warn (' {0} read(s) failed; the rest of the snapshot is complete:' -f $Script:Problems.Count)
        foreach ($p in $Script:Problems) { Warn ('   ' + $p) }
    }
    Write-Host ''
    if ($file) {
        Good (' SAVED ON THE DESKTOP: ' + [IO.Path]::GetFileName($file) + ('   ({0} s, encrypted)' -f [int]$sw.Elapsed.TotalSeconds))
        Write-Host ' Copy that file to your laptop''s Desktop or Downloads. The Manager imports it by itself.'
        if ($clip) { Mute ' Same text is on the clipboard (laptop: P on the host screen, or vmm collect).' }
    } elseif ($clip) { Good ' Result copied to the clipboard. On the laptop: P on the host screen, or vmm collect.' }
    else { Write-Host $out }
}

# ============================================================== finish
function Invoke-Finish([switch]$Force) {
    if (-not $Force) {
        Warn ' Deletes this extractor and its result files from this desktop, and clears the clipboard.'
        if (Test-Path -LiteralPath $WorkDir) { Warn " Also removes $WorkDir (steps log)." }
        Warn ' Staged install files are NOT touched. Type FINISH to continue.'
        if ((Read-Host ' >') -cne 'FINISH') { Mute 'Cancelled.'; return $false }
    }
    $ok = $true
    if (Test-Path -LiteralPath $WorkDir) {
        try { Remove-Item -LiteralPath $WorkDir -Recurse -Force; Good "Removed $WorkDir" }
        catch { $ok = $false; Bad ('Could not remove the work folder: ' + (Protect-Text $_.Exception.Message)) }
    }
    if (-not $NoClipboard) { try { & cmd.exe /c 'echo off | clip' } catch { } }
    $desk = [Environment]::GetFolderPath('Desktop')
    if ($desk) { Get-ChildItem -LiteralPath $desk -Filter ('VMM_' + $env:COMPUTERNAME + '_*.vmm') -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force; Good ('Removed ' + $_.Name) } catch { } } }
    if ($Script:SelfPath -and (Test-Path -LiteralPath $Script:SelfPath)) {
        try { Remove-Item -LiteralPath $Script:SelfPath -Force; Good 'Removed the extractor file.' }
        catch { $ok = $false; Bad 'Could not remove the extractor file; delete it from the desktop by hand.' }
    }
    if ($ok) { Good 'Host clean. Close this window and the RDP session.' }
    $ok
}

# ============================================================== screens
function Show-Header {
    Clear-Host
    $mode = 'snapshot (read-only)'; if ($Script:StepsMode) { $mode = 'steps' }
    Say (" VMM extractor $AgentVersion | $env:COMPUTERNAME | $mode | {0}" -f (Get-Date).ToString('ddd yyyy-MM-dd HH:mm')) 'White'
    if ($Script:StepsMode) {
        $w = Get-Window
        if ($w.ChangesAllowed) { Good (' ' + $w.Why) } else { Warn (' ' + $w.Why) }
        if (-not (Test-Admin)) { Warn ' Not elevated: checks and staging only. For changes, run PowerShell as administrator.' }
        if ($Card.Host -and $Card.Host -ne $env:COMPUTERNAME) { Bad " PLAN IS FOR $($Card.Host), NOT THIS HOST. Do not run change steps here." }
        elseif ($Card.Generated) {
            try {
                $age = ([DateTime]::UtcNow - [DateTime]::Parse($Card.Generated, $Script:Inv).ToUniversalTime()).TotalHours
                if ($age -gt [double]$Card.ValidHours) { Warn (" Plan is {0:N0} h old: build a fresh extractor on the laptop." -f $age) }
            } catch { }
        }
    }
    try {
        $pf = New-Object PSObject -Property @{ OS = "$((Get-WmiObject Win32_OperatingSystem).Caption)"; Platform = $Card.Platform }
        $pol = Get-Policy $pf
        if (-not $pol.Workable) { Warn (' POLICY: ' + $pol.Why) }
        foreach ($x in $pol.Warnings) { Bad (' WARN MANAGEMENT: ' + $x) }
    } catch { }
    if (-not $Card.PublicKey) { Warn ' No laptop key in this file: results cannot be encrypted. Build the extractor on the laptop (vmm extractor).' }
    Mute ' ---------------------------------------------------------------------------------------'
}
function Show-Facts($f) {
    Info ' This host'
    Write-Host ("  OS            {0} (build {1}, SP {2}, language {3})" -f $f.OS, $f.Build, $f.SP, $f.Lang)
    Write-Host ("  Platform      {0} ({1} / {2})" -f $f.Platform, $f.Manufacturer, $f.Model)
    if ($null -eq $f.CFreeGB) { Warn '  C:            not read' }
    else {
        $col = 'Green'; if ($f.CFreeGB -lt [double]::Parse($Card.OkGB, $Script:Inv)) { $col = 'DarkYellow' }; if ($f.CFreeGB -lt [double]::Parse($Card.CriticalGB, $Script:Inv)) { $col = 'Red' }
        Say ("  C:            {0} GB free of {1} GB" -f $f.CFreeGB, $f.CTotalGB) $col
    }
    if ($f.PendingReboot) { Warn '  Reboot        PENDING' } else { Write-Host '  Reboot        not pending' }
    Write-Host ("  SQL           {0}" -f $(if ($f.Sql) { $f.Sql } else { 'none' }))
    Write-Host ("  Last boot     {0} UTC   PowerShell {1}   Admin {2}" -f $f.LastBoot, $f.PSVersion, $f.Admin)
    $pk = @(); try { $pk = @(Get-PackageState) } catch { }
    if ($pk.Count) { Info ' Staged files'; foreach ($p in $pk) { $c = 'Red'; if ($p.State -eq 'Verified' -or $p.State -eq 'Present') { $c = 'Green' }; Say ("  {0,-24} {1}" -f $p.Name, $p.State) $c } }
}
function Show-Inventory {
    # Shows what the last snapshot read (no second read of the host)
    Info ' Inventory (in the result file)'
    $src = @($Script:LastInv)
    if (-not $src.Count) { $src = @(Get-InvProbe $Card.Services $Card.Agents ($Card.Licence -eq 'False')) }
    foreach ($l in $src) {
        if ($l -notlike 'Inv.*') { continue }
        $i = $l.IndexOf('='); $k = $l.Substring(4, $i - 4); $v = $l.Substring($i + 1)
        $col = 'Gray'; if ($v -match '^(Not installed|No |Unlicensed|Unknown|WARN)') { $col = 'DarkYellow' } elseif ($v -match '^FAIL') { $col = 'Red' } elseif ($v -match '^OK') { $col = 'Green' }
        Say ('  {0,-18} {1}' -f $k, $v) $col
    }
}
function Pause-Agent { Write-Host ''; Read-Host ' Enter to continue' | Out-Null }

# ============================================================== main
try {
    if ($Finish) { [void](Invoke-Finish -Force); return }
    if ($Extract) { Export-Result -Auto; return }

    # Snapshot straight away, so the result file is on the desktop before any key is pressed.
    Show-Header
    try { Export-Result -Auto } catch { Bad (' ERROR: ' + (Protect-Text $_.Exception.Message)) }
    if ($Script:StepsMode) { Pause-Agent; Invoke-StepsMenu; return }

    while ($true) {
        Write-Host ''
        Mute ' Enter = close (the result file stays)   I = inventory columns   R = read again   F = finish (delete this file and its results)'
        $k = Read-Host ' Choice'
        try {
            switch -Regex ($k) {
                '^[iI]$' { Show-Inventory }
                '^[rR]$' { Show-Header; Export-Result -Auto }
                '^[fF]$' { if (Invoke-Finish) { return } }
                default  { return }
            }
        } catch { Bad (' ERROR: ' + (Protect-Text $_.Exception.Message)) }
    }
} catch {
    Bad (' ERROR: ' + (Protect-Text $_.Exception.Message))
    exit 1
}
