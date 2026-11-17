<#
.SYNOPSIS
    VmMaintenance FALLBACK - the last fallback on a host: no vmm, no laptop, no network needed.
    Reads everything useful about THIS host and guides you through patching and upgrading Windows and SQL Server.
.DESCRIPTION
    Use it when nothing else works: vmm cannot reach the host and no Extractor was built for it.
    Copy this file and its companion VmmFallback.psd1 (same folder) to the host, then:

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VmmFallback.ps1

    (Bypass applies to this one process only; nothing on the host is reconfigured.)

    The companion file holds every setting, the OS upgrade path, the SQL support matrix, the steps and the
    advice text. The script checks it first and stops (exit 2) naming the bad entry when it is wrong.

    GUIDE (the default in a console): reads the host, then shows the steps
        Snapshot, Precheck, WindowsPatch, SqlPatch, SqlUpgrade, OsUpgrade, Disk, Postcheck, Finish
    Every step shows its advice first and offers:
        R  Run it (automated; after hours only, administrator, typed YES)
        G  Guidance only (the manual instructions and exact commands for this host, nothing is changed)
        T  Stage media (copy from the media folder into C:\Temp; allowed during business hours)

    SNAPSHOT (-Snapshot, the default without a console): read-only. Writes one result file
    VMMF_<HOST>_<time>.txt (Key=Value, NOT encrypted) and the log into the work folder (C:\Temp\VmmFallback).

    RULES (same as vmm): goal OS Windows Server 2019; a client OS (Windows 10/11) is never changed without
    -Order "<reason>"; warnings for Server 2008 (not R2), physical machines, domain controllers and clusters;
    Mon-Fri 08:00-17:00 Lisbon only reads and staging into C:\Temp; disk growth is done in Azure (VM
    deallocated, after a snapshot); patch and upgrade media come from a local folder only (nothing is ever
    downloaded); every change asks you to confirm the rollback snapshot/backup and, where management warnings
    apply, that management was informed; the script never reboots the host.

    Compatible with Windows PowerShell 2.0 to 5.1 and PowerShell 7.

    EXIT CODES
        0  done
        1  unexpected error (the message says where)
        2  usage error, or the companion file is missing or invalid
        3  blocked by the time window (business hours: reads and staging only)
        5  refused by policy or a safety check (client OS, no fresh SQL backup, pending reboot, ...)
        6  another copy of this script is running on this host
        7  snapshot saved, but some reads failed (listed as Problem= in the result)
        8  cancelled (YES not typed)
        9  done, a reboot is needed
       10  needs administrator rights (right-click > Run as administrator)
.PARAMETER Snapshot
    Read-only snapshot, save the result file, exit (0 or 7).
.PARAMETER Guide
    Interactive menu (the default when a console is available).
.PARAMETER Check
    Only validate the companion file and exit (0 valid, 2 invalid).
.PARAMETER Step
    Open one step directly: Snapshot, Precheck, WindowsPatch, SqlPatch, SqlUpgrade, OsUpgrade, Disk, Postcheck, Finish.
.PARAMETER Action
    With -Step: Guide (default; manual instructions only), Run (automated, asks for YES) or Stage (copy media).
.PARAMETER Instance
    With -Step SqlPatch/SqlUpgrade: the SQL instance name (MSSQLSERVER for the default instance).
.PARAMETER DataFile
    Companion file path (default: VmmFallback.psd1 next to this script).
.PARAMETER WorkDir
    Work folder override (must be under C:\Temp).
.PARAMETER MediaDir
    Media folder override (local folder or mounted ISO drive; nothing is downloaded).
.PARAMETER Order
    The order reason that allows changes on a client OS (Windows 10/11). At least 10 characters; logged.
.PARAMETER NoColor
    Plain output.
.PARAMETER Help
    Show this usage and exit 0.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VmmFallback.ps1
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VmmFallback.ps1 -Snapshot
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VmmFallback.ps1 -Step SqlPatch -Action Guide -Instance MSSQLSERVER
#>
param(
    [switch]$Snapshot,
    [switch]$Guide,
    [switch]$Check,
    [string]$Step,
    [string]$Action = 'Guide',
    [string]$Instance,
    [string]$DataFile,
    [string]$WorkDir,
    [string]$MediaDir,
    [string]$Order,
    [switch]$NoColor,
    [switch]$Help
)

$FallbackVersion = '2.17.1'
$ErrorActionPreference = 'Stop'
$Script:SelfPath = $MyInvocation.MyCommand.Path
$Script:Inv = [Globalization.CultureInfo]::InvariantCulture
$Script:Problems = @()
$Script:StepIds = @('Snapshot', 'Precheck', 'WindowsPatch', 'SqlPatch', 'SqlUpgrade', 'OsUpgrade', 'Disk', 'Postcheck', 'Finish')
$Script:Code = @{ Ok = 0; Error = 1; Usage = 2; Window = 3; Policy = 5; Locked = 6; Partial = 7; Cancelled = 8; Reboot = 9; Admin = 10 }

# ============================================================== output
function Say([string]$Text, [string]$Color) {
    if ($NoColor -or -not $Color) { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
}
function Info([string]$t) { Say $t 'Cyan' }        # titles
function Good([string]$t) { Say $t 'Green' }
function Warn([string]$t) { Say $t 'Yellow' }
function Bad([string]$t)  { Say $t 'Red' }
function Mute([string]$t) { Say $t 'DarkGray' }

# ============================================================== sanitizing (log and Problem lines)
function Protect-Text([string]$Text) {
    if (-not $Text) { return '' }
    $t = $Text
    $t = $t -replace '(?i)(password|pwd|passwd|secret|token|apikey|api_key|client_secret|/pid)\s*[=:]\s*[^;\s]+', '$1=***'
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
    $m = ''
    if ($Err) { try { $m = $Err.Exception.Message } catch { $m = "$Err" } }
    $t = Protect-Text ($What + ': ' + $m)
    if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
    $Script:Problems += $t
}
function Num($v) { if ($null -eq $v -or "$v" -eq '') { '' } else { ([double]$v).ToString($Script:Inv) } }
function ConvertTo-Ascii([string]$Text) { if (-not $Text) { return '' }; ($Text -replace '[^\x20-\x7E]', '').Trim() }

# ============================================================== companion file
function Get-DefaultDataFile {
    $dir = '.'
    if ($Script:SelfPath) { $dir = Split-Path -Parent $Script:SelfPath }
    Join-Path $dir 'VmmFallback.psd1'
}
function Read-Companion([string]$Path) {
    # Import-LocalizedData reads a .psd1 in restricted language mode (data only) and exists since PowerShell 2.0.
    if (-not (Test-Path -LiteralPath $Path)) { throw "Companion file not found: $Path (keep VmmFallback.psd1 next to the script, or pass -DataFile)." }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $data = $null
    Import-LocalizedData -BindingVariable data -BaseDirectory (Split-Path -Parent $full) -FileName (Split-Path -Leaf $full) -ErrorAction Stop
    if (-not ($data -is [hashtable])) { throw "Companion file $Path is not a PowerShell data file (@{ ... })." }
    $data
}
function Test-IsText($v) { $v -is [string] }
function Test-IsNumber($v) { $v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] }
function Test-IsList($v) { $v -is [array] -or $v -is [Collections.IList] }
function Test-Companion($Data) {
    # Returns one line per problem ('' list = valid). Each line names the key so the user can fix it.
    $p = @()
    if (-not ($Data -is [hashtable])) { return @('The file is not a hashtable (@{ ... }).') }
    if ($Data['SchemaVersion'] -ne 1) { $p += "SchemaVersion must be 1 (found '$($Data['SchemaVersion'])')." }
    $s = $Data['Settings']
    if (-not ($s -is [hashtable])) { $p += 'Settings is missing or not a hashtable.'; $s = @{} }
    foreach ($k in 'TargetOs', 'TargetOsMatch', 'TimeZoneId', 'BusinessStart', 'BusinessEnd', 'WorkDir', 'MediaDir') {
        if (-not (Test-IsText $s[$k]) -or -not $s[$k]) { $p += "Settings.$k is missing or not text." }
    }
    foreach ($k in 'MinFreeGBPatch', 'MinFreeGBSql', 'MinFreeGBOsUpgrade', 'SqlBackupMaxAgeHours', 'EventLogHours') {
        if (-not (Test-IsNumber $s[$k]) -or $s[$k] -le 0) { $p += "Settings.$k must be a number above 0." }
    }
    $days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
    if (-not (Test-IsList $s['BusinessDays']) -and -not (Test-IsText $s['BusinessDays'])) { $p += 'Settings.BusinessDays must be a list of day names.' }
    else { foreach ($d in @($s['BusinessDays'])) { if ($days -notcontains "$d") { $p += "Settings.BusinessDays: '$d' is not a day name (Monday..Sunday)." } } }
    if ($s.ContainsKey('Holidays')) {
        foreach ($h in @($s['Holidays'])) {
            if ($null -eq $h) { continue }
            $ok = $true; try { [void][DateTime]::ParseExact("$h", 'yyyy-MM-dd', $Script:Inv) } catch { $ok = $false }
            if (-not $ok) { $p += "Settings.Holidays: '$h' is not a yyyy-MM-dd date." }
        }
    }
    $st = $null; $en = $null
    try { $st = [TimeSpan]::Parse("$($s['BusinessStart'])") } catch { $p += "Settings.BusinessStart '$($s['BusinessStart'])' is not HH:mm." }
    try { $en = [TimeSpan]::Parse("$($s['BusinessEnd'])") } catch { $p += "Settings.BusinessEnd '$($s['BusinessEnd'])' is not HH:mm." }
    if ($null -ne $st -and $null -ne $en -and $st -ge $en) { $p += 'Settings.BusinessStart must be before Settings.BusinessEnd.' }
    if ((Test-IsText $s['WorkDir']) -and $s['WorkDir'] -and -not (Test-UnderTemp $s['WorkDir'])) { $p += "Settings.WorkDir must be a folder under C:\Temp (project rule), found '$($s['WorkDir'])'." }
    if ($s.ContainsKey('DiskTiersGB')) { foreach ($t in @($s['DiskTiersGB'])) { if (-not (Test-IsNumber $t)) { $p += "Settings.DiskTiersGB: '$t' is not a number." } } }

    if (-not (Test-IsList $Data['OsPath']) -or @($Data['OsPath']).Count -eq 0) { $p += 'OsPath is missing or empty.' }
    else {
        $i = 0
        foreach ($e in @($Data['OsPath'])) {
            $i++
            if (-not ($e -is [hashtable])) { $p += "OsPath entry $i is not a hashtable."; continue }
            foreach ($k in 'Match', 'Name', 'State') { if (-not (Test-IsText $e[$k]) -or -not $e[$k]) { $p += "OsPath entry ${i}: $k is missing." } }
            if (@('Upgrade', 'Target', 'Newer', 'Unsupported') -notcontains "$($e['State'])") { $p += "OsPath entry ${i}: State must be Upgrade, Target, Newer or Unsupported." }
            if ("$($e['State'])" -eq 'Upgrade' -and (-not $e['Next'] -or "$($e['NextBuild'])" -notmatch '^\d+$')) { $p += "OsPath entry ${i}: State Upgrade needs Next and a numeric NextBuild." }
        }
    }
    if (-not (Test-IsList $Data['SqlVersions']) -or @($Data['SqlVersions']).Count -eq 0) { $p += 'SqlVersions is missing or empty.' }
    else {
        $i = 0
        foreach ($e in @($Data['SqlVersions'])) {
            $i++
            if (-not ($e -is [hashtable])) { $p += "SqlVersions entry $i is not a hashtable."; continue }
            if (-not (Test-IsNumber $e['Major'])) { $p += "SqlVersions entry ${i}: Major must be a number (10.5 for 2008 R2)." }
            if (-not (Test-IsText $e['Name']) -or -not $e['Name']) { $p += "SqlVersions entry ${i}: Name is missing." }
            if (-not (Test-IsText $e['OnTarget']) -or ($e['OnTarget'] -and $e['OnTarget'] -notmatch '^(RTM|SP\d+)$')) { $p += "SqlVersions entry ${i}: OnTarget must be '', RTM or SPn." }
        }
    }
    if ($Data.ContainsKey('SqlUpgrade')) {
        $i = 0
        foreach ($e in @($Data['SqlUpgrade'])) {
            $i++
            if (-not ($e -is [hashtable])) { $p += "SqlUpgrade entry $i is not a hashtable."; continue }
            if (-not (Test-IsNumber $e['FromMajor'])) { $p += "SqlUpgrade entry ${i}: FromMajor must be a number." }
            if ("$($e['MinLevel'])" -notmatch '^(RTM|SP\d+)$') { $p += "SqlUpgrade entry ${i}: MinLevel must be RTM or SPn." }
            if (@($e['To']).Count -eq 0 -or -not @($e['To'])[0]) { $p += "SqlUpgrade entry ${i}: To must list at least one version name." }
        }
    }
    if ($Data.ContainsKey('Agents') -and -not ($Data['Agents'] -is [hashtable])) { $p += 'Agents must be a hashtable of name = service wildcards.' }

    if (-not (Test-IsList $Data['Steps']) -or @($Data['Steps']).Count -eq 0) { $p += 'Steps is missing or empty.' }
    else {
        $seen = @(); $i = 0
        foreach ($e in @($Data['Steps'])) {
            $i++
            if (-not ($e -is [hashtable])) { $p += "Steps entry $i is not a hashtable."; continue }
            $id = "$($e['Id'])"
            if ($Script:StepIds -notcontains $id) { $p += "Steps entry ${i}: Id '$id' is unknown (known: $($Script:StepIds -join ', '))." }
            elseif ($seen -contains $id) { $p += "Steps entry ${i}: Id '$id' is listed twice." }
            $seen += $id
            if (-not (Test-IsText $e['Title']) -or -not $e['Title']) { $p += "Steps.${id}: Title is missing." }
            foreach ($k in 'Advice', 'Manual') {
                if (-not $e.ContainsKey($k) -or @($e[$k]).Count -eq 0) { $p += "Steps.${id}: $k needs at least one line." }
                else { foreach ($l in @($e[$k])) { if (-not (Test-IsText $l)) { $p += "Steps.${id}: every $k line must be text." ; break } } }
            }
        }
        foreach ($must in 'Snapshot', 'Finish') { if ($seen -notcontains $must) { $p += "Steps must include $must." } }
    }
    $p
}
function Test-UnderTemp([string]$Path) {
    # A folder below C:\Temp (not C:\Temp itself), no '..' segment
    $p = "$Path".TrimEnd('\')
    ($p -match '^(?i)C:\\Temp(\\[^\\/:*?"<>|]+)+$') -and ($p -notmatch '\\\.\.?(\\|$)')
}
function Get-StepDef([string]$Id) { foreach ($e in @($Script:Data['Steps'])) { if ($e['Id'] -eq $Id) { return $e } }; $null }
function Expand-Text([string]$Line, $Map) {
    $t = $Line
    foreach ($k in $Map.Keys) { $t = $t.Replace('{' + $k + '}', "$($Map[$k])") }
    $t
}

# ============================================================== time window (Europe/Lisbon by default)
function Get-Window($S, [DateTime]$NowUtc) {
    $known = $true; $now = $NowUtc
    $tz = $null
    foreach ($id in @("$($S['TimeZoneId'])", 'Europe/Lisbon')) {
        if ($tz) { break }
        try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id) } catch { }
    }
    if ($tz) { $now = [TimeZoneInfo]::ConvertTimeFromUtc($NowUtc, $tz) } else { $known = $false }
    $days = @($S['BusinessDays']); $hol = @(); foreach ($h in @($S['Holidays'])) { if ($h) { $hol += "$h" } }
    $start = [TimeSpan]::Parse("$($S['BusinessStart'])"); $end = [TimeSpan]::Parse("$($S['BusinessEnd'])")
    $isBiz = ($days -contains $now.DayOfWeek.ToString()) -and -not ($hol -contains $now.ToString('yyyy-MM-dd'))
    $inHours = $isBiz -and $now.TimeOfDay -ge $start -and $now.TimeOfDay -lt $end
    $allowed = -not $inHours
    $why = 'Maintenance window: changes are allowed.'
    if (-not $known) { $allowed = $false; $why = "Time zone '$($S['TimeZoneId'])' is unknown on this host: treated as business hours." }
    elseif ($inHours) { $why = "Business hours ($($S['BusinessStart'])-$($S['BusinessEnd']) $($S['TimeZoneId'])): only reads and staging into C:\Temp." }
    New-Object PSObject -Property @{ Local = $now; Known = $known; InHours = $inHours; ChangesAllowed = $allowed; Why = $why }
}

# ============================================================== OS and SQL rules
function Get-OsEntry([string]$Caption, $OsPath) {
    foreach ($e in @($OsPath)) { if ($e -and $Caption -like $e['Match']) { return $e } }
    $null
}
function Get-Policy($Facts, $Data, [string]$OrderReason) {
    $os = "$($Facts.OS)"
    $entry = Get-OsEntry $os $Data['OsPath']
    $scope = 'Unknown'; $why = "OS '$os' is not in the companion file's OsPath: guidance only."
    if (-not $os) { $why = 'The OS could not be read: guidance only.' }
    elseif ($os -notlike '*Server*') {
        if ($OrderReason) { $scope = 'ClientOsOrdered'; $why = "Client OS ($os): changes allowed by order: $OrderReason" }
        else { $scope = 'ClientOs'; $why = "Client OS ($os): not touched without orders (use -Order ""<reason>"")." }
    } elseif ($entry) {
        switch ("$($entry['State'])") {
            'Upgrade'     { $scope = 'InScope'; $why = "Upgrade towards $($Data['Settings']['TargetOs']): next hop $($entry['Next'])." }
            'Target'      { $scope = 'AtTarget'; $why = "Already on the target OS ($os): patch only." }
            'Newer'       { $scope = 'NewerThanTarget'; $why = "Newer than the target ($os): never downgraded, patch only." }
            'Unsupported' { $scope = 'Unsupported'; $why = "$($entry['Name']): $($entry['Note'])" }
        }
    }
    $warn = @()
    if ($os -like '*Server 2008*' -and $os -notlike '*2008 R2*') { $warn += 'Windows Server 2008 (not R2): warn management before any change.' }
    if ($Facts.Platform -eq 'Physical') { $warn += 'Physical machine: warn management (no Azure snapshot or disk resize; make sure a full backup exists).' }
    if ($Facts.DomainController -eq 'Yes') { $warn += 'Domain controller: OS upgrade is guidance only (adprep, FSMO and replication checks first).' }
    if ($Facts.Cluster -eq 'Yes') { $warn += 'Failover cluster node: OS upgrade and SQL patching are guidance only (rolling procedure).' }
    if ($Facts.Exchange -eq 'Yes') { $warn += 'Exchange server: in-place OS upgrade is not supported, guidance only.' }
    $changeOk = @('InScope', 'AtTarget', 'NewerThanTarget', 'ClientOsOrdered') -contains $scope
    $osOk = ($scope -eq 'InScope') -and $Facts.DomainController -ne 'Yes' -and $Facts.Cluster -ne 'Yes' -and $Facts.Exchange -ne 'Yes'
    New-Object PSObject -Property @{ Scope = $scope; Why = $why; Warnings = $warn; ChangeOk = $changeOk; OsUpgradeOk = $osOk; Entry = $entry }
}
function Get-SqlMajor([string]$Version) {
    # 15.0.4355.3 -> 15; 10.50.6000.34 (2008 R2) -> 10.5
    if ("$Version" -notmatch '^(\d+)\.(\d+)') { return $null }
    $ma = [int]$Matches[1]; $mi = [int]$Matches[2]
    if ($ma -eq 10 -and $mi -ge 50) { return 10.5 }
    [double]$ma
}
function Get-LevelRank([string]$Level) {
    if ("$Level" -match '^SP(\d+)') { return [int]$Matches[1] }
    if ("$Level" -match '^RTM') { return 0 }
    -1
}
function Get-SqlVersionEntry($Major, $Data) {
    foreach ($e in @($Data['SqlVersions'])) { if ($null -ne $Major -and [double]$e['Major'] -eq [double]$Major) { return $e } }
    $null
}
function Get-SqlVerdict($Sql, $Data) {
    # OK / PatchFirst (supported on the target OS once patched) / UpgradeFirst (not supported there) / Unknown
    $e = Get-SqlVersionEntry (Get-SqlMajor $Sql.Version) $Data
    if (-not $e) { return New-Object PSObject -Property @{ Verdict = 'Unknown'; Why = "Version $($Sql.Version) is not in SqlVersions."; Name = '' } }
    if (-not $e['OnTarget']) { return New-Object PSObject -Property @{ Verdict = 'UpgradeFirst'; Why = "$($e['Name']) is not supported on $($Data['Settings']['TargetOs']). $($e['Note'])".Trim(); Name = $e['Name'] } }
    if ((Get-LevelRank $Sql.Level) -lt (Get-LevelRank $e['OnTarget'])) { return New-Object PSObject -Property @{ Verdict = 'PatchFirst'; Why = "$($e['Name']) $($Sql.Level) needs $($e['OnTarget']) or later on $($Data['Settings']['TargetOs'])."; Name = $e['Name'] } }
    New-Object PSObject -Property @{ Verdict = 'OK'; Why = "$($e['Name']) $($Sql.Level) is supported on $($Data['Settings']['TargetOs'])."; Name = $e['Name'] }
}
function Get-SqlUpgradeOption($Sql, $Data) {
    $major = Get-SqlMajor $Sql.Version
    foreach ($e in @($Data['SqlUpgrade'])) {
        if ($null -ne $major -and [double]$e['FromMajor'] -eq $major) {
            $ok = (Get-LevelRank $Sql.Level) -ge (Get-LevelRank $e['MinLevel'])
            return New-Object PSObject -Property @{ To = @($e['To']); MinLevel = "$($e['MinLevel'])"; LevelOk = $ok; Note = "$($e['Note'])" }
        }
    }
    $null
}
function Select-ImageIndex($Images, [string]$EditionId, [bool]$IsCore) {
    # The install.wim index with the same edition (Standard/Datacenter) and the same desktop/core form as this host.
    # 0 when none or more than one match (the user then picks it from dism /Get-WimInfo).
    $dc = $EditionId -match 'Datacenter'
    $hits = @()
    foreach ($i in @($Images)) {
        if (-not $i) { continue }
        $n = "$($i.Name)"
        if (($n -match '(?i)datacenter') -ne $dc) { continue }
        $desktop = ($n -match '(?i)Desktop Experience') -or ($n -cmatch 'SERVER(STANDARD|DATACENTER)$')
        if ($desktop -eq $IsCore) { continue }
        $hits += [int]$i.Index
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    0
}
function Get-NextDiskTier([double]$CurrentGB, $Tiers) {
    foreach ($t in @($Tiers)) { if ([double]$t -gt ($CurrentGB + 1)) { return [double]$t } }
    $null
}

# ============================================================== exit code helpers
function Get-NativeVerdict([string]$Tool, [int]$Exit) {
    # Exit codes of wusa / dism / SQL setup / Windows setup -> Ok | Reboot | Skip | Fail, with a plain message
    $r = 'Fail'; $m = ('exit code {0} (0x{1})' -f $Exit, $Exit.ToString('X8'))
    switch ($Exit) {
        0           { $r = 'Ok'; $m = 'done' }
        3010        { $r = 'Reboot'; $m = 'done, reboot needed' }
        1641        { $r = 'Reboot'; $m = 'done, reboot started by the installer' }
        2359302     { $r = 'Skip'; $m = 'already installed' }
        -2145124329 { $r = 'Skip'; $m = 'not applicable to this host' }
        -1047526896 { $r = 'Ok'; $m = 'compatibility scan: no issues' }
        -1047526904 { $r = 'Fail'; $m = 'compatibility scan: incompatible applications (see the setup logs)' }
        -1047526908 { $r = 'Fail'; $m = 'compatibility scan: edition or language cannot be kept with this media' }
        -1047526912 { $r = 'Fail'; $m = 'compatibility scan: this host is not eligible for the upgrade' }
        -1047526898 { $r = 'Fail'; $m = 'compatibility scan: not enough free disk space' }
    }
    New-Object PSObject -Property @{ Result = $r; Message = "${Tool}: $m"; Exit = $Exit }
}
function Get-SessionExitCode($Outcomes, [int]$ProblemCount) {
    # Guide session: 1 if a step failed, else 9 if a reboot is needed, else 7 if snapshot reads failed, else 0
    $o = @($Outcomes)
    if ($o -contains 1) { return 1 }
    if ($o -contains 9) { return 9 }
    if ($ProblemCount -gt 0) { return 7 }
    0
}

# ============================================================== reads (all read-only)
function Test-Admin {
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
function Get-Wmi([string]$Class, [string]$Filter) {
    $cim = $Script:WmiUseCim   # never set on a host; the tests set it to reach both branches
    if ($null -eq $cim) { $cim = -not (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) }
    if (-not $cim) {
        if ($Filter) { return Get-WmiObject -Class $Class -Filter $Filter -ErrorAction Stop }
        return Get-WmiObject -Class $Class -ErrorAction Stop
    }
    if ($Filter) { return Get-CimInstance -ClassName $Class -Filter $Filter -ErrorAction Stop }
    Get-CimInstance -ClassName $Class -ErrorAction Stop
}
function Get-PlatformName([string]$Manufacturer, [string]$Model, [bool]$AzureAgent) {
    # Physical only when no known hypervisor shows in the model or manufacturer (same list as the Extractor)
    if ($Manufacturer -like '*VMware*' -or $Model -like '*VMware*') { return 'VMware' }
    if ($Model -like '*Virtual Machine*') { if ($AzureAgent) { return 'Azure' }; return 'Hyper-V' }
    if ($Model -like '*KVM*' -or $Model -like '*VirtualBox*' -or $Model -like '*HVM domU*' -or $Model -like '*AHV*' -or $Model -like '*Standard PC*' -or
        $Manufacturer -like '*Xen*' -or $Manufacturer -like '*QEMU*' -or $Manufacturer -like '*Nutanix*' -or $Manufacturer -like '*innotek*' -or
        $Manufacturer -like '*Red Hat*' -or $Manufacturer -like '*oVirt*' -or $Manufacturer -like '*Amazon EC2*' -or $Manufacturer -like '*Google*') { return 'OtherVirtual' }
    'Physical'
}
function Get-RegValue([string]$Key, [string]$Name) {
    try { $p = Get-ItemProperty -LiteralPath $Key -Name $Name -ErrorAction Stop; return $p.$Name } catch { return $null }
}
function Get-SqlInstanceNames($Props) {
    $own = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
    foreach ($n in @($Props.PSObject.Properties)) { if ($own -notcontains $n.Name) { $n } }
}
function Get-SqlInstances {
    # Every SQL Server instance: 64-bit registry view first, then the 32-bit one (Wow6432Node). Registry + service only.
    $roots = @(@{ Path = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'; Bits = '64-bit' }, @{ Path = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server'; Bits = '32-bit' })
    $out = @(); $seen = @()
    foreach ($r in $roots) {
        $k = $r.Path + '\Instance Names\SQL'
        if (-not (Test-Path $k)) { continue }
        foreach ($n in @(Get-SqlInstanceNames (Get-ItemProperty $k))) {
            if (-not $n -or $seen -contains $n.Name) { continue }
            $seen += $n.Name
            $setup = $r.Path + '\' + $n.Value + '\Setup'
            $ver = "$(Get-RegValue $setup 'PatchLevel')"; if (-not $ver) { $ver = "$(Get-RegValue $setup 'Version')" }
            $sp = Get-RegValue $setup 'SP'
            $lvl = 'RTM'; if ($sp -and [int]$sp -gt 0) { $lvl = 'SP' + $sp }
            $svcName = 'MSSQL$' + $n.Name; if ($n.Name -eq 'MSSQLSERVER') { $svcName = 'MSSQLSERVER' }
            $svc = $null; try { $svc = Get-Service -Name $svcName -ErrorAction Stop } catch { }
            $state = 'NotFound'; if ($svc) { $state = "$($svc.Status)" }
            $clu = 'No'; if (Test-Path ($r.Path + '\' + $n.Value + '\Cluster')) { $clu = 'Yes' }
            $out += New-Object PSObject -Property @{
                Name = $n.Name; Id = "$($n.Value)"; Bits = $r.Bits; Version = $ver; Level = $lvl; Update = ''
                Edition = "$(Get-RegValue $setup 'Edition')"; Service = $state; Clustered = $clu; Hadr = ''
                Databases = ''; Stale = @(); Live = $false; LiveError = ''
            }
        }
    }
    $out
}
function Invoke-SqlQuery([string]$InstanceName, [string]$Query) {
    # Local shared-memory connection (lpc:), Windows authentication, no network. Returns rows as object arrays.
    $ds = 'lpc:.'; if ($InstanceName -ne 'MSSQLSERVER') { $ds = 'lpc:.\' + $InstanceName }
    $cn = New-Object Data.SqlClient.SqlConnection ('Data Source=' + $ds + ';Integrated Security=SSPI;Connect Timeout=5;Application Name=VmmFallback')
    try {
        $cn.Open()
        $cmd = $cn.CreateCommand(); $cmd.CommandText = $Query; $cmd.CommandTimeout = 30
        $rd = $cmd.ExecuteReader()
        $rows = @()
        while ($rd.Read()) { $v = New-Object object[] $rd.FieldCount; [void]$rd.GetValues($v); $rows += ,$v }
        $rd.Close()
        return ,$rows
    } finally { $cn.Close() }
}
function Update-SqlLive($Sql, [double]$MaxAgeHours) {
    # Live details when the service runs and this account may log in: level, CU, HADR, databases, backup age.
    if ($Sql.Service -ne 'Running') { return }
    try {
        $r = Invoke-SqlQuery $Sql.Name "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)), CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(64)), CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(64)), CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), CAST(SERVERPROPERTY('IsClustered') AS int), CAST(SERVERPROPERTY('IsHadrEnabled') AS int)"
        $row = $r[0]
        if ($row[0] -isnot [DBNull]) { $Sql.Version = "$($row[0])" }
        if ($row[1] -isnot [DBNull]) { $Sql.Level = "$($row[1])" }
        if ($row[2] -isnot [DBNull]) { $Sql.Update = "$($row[2])" }
        if ($row[3] -isnot [DBNull]) { $Sql.Edition = "$($row[3])" }
        if ($row[4] -isnot [DBNull] -and [int]$row[4] -eq 1) { $Sql.Clustered = 'Yes' }
        $Sql.Hadr = 'No'; if ($row[5] -isnot [DBNull] -and [int]$row[5] -eq 1) { $Sql.Hadr = 'Yes' }
        $db = Invoke-SqlQuery $Sql.Name "SELECT d.name, DATEDIFF(hour, MAX(b.backup_finish_date), GETDATE()) FROM sys.databases d LEFT JOIN msdb.dbo.backupset b ON b.database_name = d.name AND b.type = 'D' WHERE d.name <> 'tempdb' AND d.state = 0 GROUP BY d.name"
        $Sql.Databases = "$(@($db).Count)"
        $stale = @()
        foreach ($d in @($db)) {
            if (-not $d) { continue }
            if ($d[1] -is [DBNull]) { $stale += ("$($d[0])" + '|never') }
            elseif ([double]$d[1] -gt $MaxAgeHours) { $stale += ("$($d[0])" + '|' + $d[1] + 'h') }
        }
        $Sql.Stale = $stale
        $Sql.Live = $true
    } catch {
        $Sql.LiveError = Protect-Text $_.Exception.Message
        Add-Problem ('SQL ' + $Sql.Name + ' (login needed for level and backup checks)') $_
    }
}
function Get-PendingReboot {
    $why = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $why += 'servicing' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $why += 'Windows Update' }
    $sm = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
    if ($sm) { $why += 'file renames' }
    $why
}
function ConvertTo-Date($Text) {
    if ($Text -is [DateTime]) { return $Text }
    foreach ($f in 'M/d/yyyy', 'yyyyMMdd', 'yyyy-MM-dd') { try { return [DateTime]::ParseExact("$Text", $f, $Script:Inv) } catch { } }
    try { return [DateTime]::Parse("$Text", $Script:Inv) } catch { }
    $null
}
function Get-EventCount([string]$Log, [double]$Hours) {
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $Log; Level = 1, 2; StartTime = (Get-Date).AddHours(-$Hours) } -MaxEvents 1000 -ErrorAction Stop)
    } catch {
        if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return New-Object PSObject -Property @{ Count = 0; Top = '' } }
        throw
    }
    $top = @($ev | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { $_.Name + ' x' + $_.Count })
    New-Object PSObject -Property @{ Count = $ev.Count; Top = ($top -join ', ') }
}
function Get-Facts($Data) {
    # Each read stands alone: one that fails leaves its fields empty, is listed as a Problem, and the rest still run.
    $s = $Data['Settings']
    $f = @{
        Name = $env:COMPUTERNAME; OS = ''; Edition = ''; InstallType = ''; Lang = ''; Version = ''; Build = ''; UBR = ''; SP = ''; Arch = ''
        InstallDate = ''; LastBoot = ''; UptimeDays = ''; Manufacturer = ''; Model = ''; Platform = 'Unknown'; Cpus = ''; RamGB = ''
        Domain = ''; DomainController = ''; Cluster = 'No'; Iis = 'No'; Exchange = 'No'; CTotalGB = $null; CFreeGB = $null
        Disks = @(); PendingReboot = @(); Patches = @(); PatchCount = ''; LastPatch = ''; WuService = ''; Wsus = ''
        Features = @(); Software = @(); Sql = @(); Agents = @{}; TlsLegacy = ''; Licence = ''; DotNet = ''; TimeZone = ''
        EventsSystem = ''; EventsApplication = ''; PSVersion = "$($PSVersionTable.PSVersion)"; Admin = (Test-Admin)
    }
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    try {
        $os = Get-Wmi 'Win32_OperatingSystem'
        $f.OS = ConvertTo-Ascii "$($os.Caption)"; $f.Version = "$($os.Version)"; $f.Build = "$($os.BuildNumber)"; $f.SP = "$($os.ServicePackMajorVersion)"
        try { $f.Arch = "$($os.OSArchitecture)" } catch { }
        try { $f.Lang = (New-Object Globalization.CultureInfo([int]$os.OSLanguage)).Name } catch { }
        foreach ($pair in @(@('LastBoot', $os.LastBootUpTime), @('InstallDate', $os.InstallDate))) {
            try {
                $d = $pair[1]; if ($d -isnot [DateTime]) { $d = $os.ConvertToDateTime($d) }
                $f[$pair[0]] = $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                if ($pair[0] -eq 'LastBoot') { $f.UptimeDays = [math]::Round(((Get-Date) - $d).TotalDays, 1) }
            } catch { }
        }
        try { $f.RamGB = [math]::Round([double]$os.TotalVisibleMemorySize / 1MB, 1) } catch { }
    } catch { Add-Problem 'Operating system' $_ }
    $f.Edition = "$(Get-RegValue $cv 'EditionID')"; $f.InstallType = "$(Get-RegValue $cv 'InstallationType')"; $f.UBR = "$(Get-RegValue $cv 'UBR')"
    try { $f.TimeZone = [TimeZoneInfo]::Local.Id } catch { }
    try {
        $cs = Get-Wmi 'Win32_ComputerSystem'
        $f.Manufacturer = "$($cs.Manufacturer)"; $f.Model = "$($cs.Model)"
        $az = $false; try { $az = [bool](Get-Service -Name WindowsAzureGuestAgent -ErrorAction SilentlyContinue) } catch { }
        $f.Platform = Get-PlatformName "$($cs.Manufacturer)" "$($cs.Model)" $az
        $f.Domain = "$($cs.Domain)"; if (-not $cs.PartOfDomain) { $f.Domain = 'WORKGROUP (' + $cs.Domain + ')' }
        $f.DomainController = 'No'; if ([int]$cs.DomainRole -ge 4) { $f.DomainController = 'Yes' }
        try { $f.Cpus = "$($cs.NumberOfLogicalProcessors)" } catch { }
    } catch { Add-Problem 'Computer model and domain' $_ }
    try {
        foreach ($d in @(Get-Wmi 'Win32_LogicalDisk' 'DriveType=3')) {
            if (-not $d) { continue }
            $size = [math]::Round([double]$d.Size / 1GB, 1); $free = [math]::Round([double]$d.FreeSpace / 1GB, 1)
            $f.Disks += New-Object PSObject -Property @{ Drive = "$($d.DeviceID)"; FileSystem = "$($d.FileSystem)"; SizeGB = $size; FreeGB = $free }
            if ($d.DeviceID -eq 'C:') { $f.CTotalGB = $size; $f.CFreeGB = $free }
        }
    } catch { Add-Problem 'Disks' $_ }
    try { $f.PendingReboot = @(Get-PendingReboot) } catch { Add-Problem 'Pending reboot' $_ }
    try {
        $q = @(Get-Wmi 'Win32_QuickFixEngineering')
        $list = @()
        foreach ($h in $q) { if ($h -and $h.HotFixID) { $list += New-Object PSObject -Property @{ Id = "$($h.HotFixID)"; Date = (ConvertTo-Date $h.InstalledOn) } } }
        $f.PatchCount = "$($list.Count)"
        $dated = @($list | Where-Object { $_.Date } | Sort-Object Date)
        if ($dated.Count) { $f.LastPatch = $dated[$dated.Count - 1].Date.ToString('yyyy-MM-dd'); $f.Patches = @($dated | Select-Object -Last 10) }
    } catch { Add-Problem 'Installed patches' $_ }
    try {
        $wu = Get-Wmi 'Win32_Service' "Name='wuauserv'"
        if ($wu) { $f.WuService = "$($wu.State) ($($wu.StartMode))" } else { $f.WuService = 'Not found' }
        $f.Wsus = 'No'; if (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUServer') { $f.Wsus = 'Yes' }
    } catch { Add-Problem 'Windows Update service' $_ }
    if ($f.OS -like '*Server*') { try {
        $names = @()
        if (-not (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) { try { Import-Module ServerManager -ErrorAction Stop } catch { } }
        if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
            foreach ($x in @(Get-WindowsFeature -ErrorAction Stop)) { if ($x -and $x.Installed) { $names += "$($x.Name)" } }
        } else {
            foreach ($x in @(Get-Wmi 'Win32_ServerFeature')) { if ($x) { $names += "$($x.Name)" } }
        }
        $f.Features = $names
    } catch { Add-Problem 'Roles and features' $_ } }   # a client OS has no server roles to read
    try {
        $svc = @(Get-Wmi 'Win32_Service')
        foreach ($x in $svc) {
            if (-not $x) { continue }
            if ($x.Name -eq 'ClusSvc') { $f.Cluster = 'Yes' }
            if ($x.Name -eq 'W3SVC') { $f.Iis = 'Yes' }
            if ($x.Name -eq 'MSExchangeIS' -or $x.Name -eq 'MSExchangeServiceHost') { $f.Exchange = 'Yes' }
        }
        $ag = $Data['Agents']; if (-not $ag) { $ag = @{} }
        foreach ($k in $ag.Keys) {
            $hit = $null
            foreach ($pat in @($ag[$k])) { if (-not $hit -and $pat) { $hit = $svc | Where-Object { $_ -and ($_.Name -like $pat -or $_.DisplayName -like $pat) } | Select-Object -First 1 } }
            $v = 'Not installed'
            if ($hit) { if ($hit.State -eq 'Running') { $v = 'Running' } else { $v = 'Installed (' + $hit.State + ')' } }
            $f.Agents[$k] = $v
        }
    } catch { Add-Problem 'Services and agents' $_ }
    try {
        $apps = @(); $seenApp = @()
        foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
            foreach ($i in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
                if (-not $i) { continue }
                $pp = Get-ItemProperty $i.PSPath -ErrorAction SilentlyContinue
                if ($pp -and $pp.DisplayName -and -not $pp.SystemComponent) {
                    $line = (ConvertTo-Ascii "$($pp.DisplayName)") + '|' + (ConvertTo-Ascii "$($pp.DisplayVersion)")
                    if ($seenApp -notcontains $line) { $seenApp += $line; $apps += $line }
                }
            }
        }
        $f.Software = @($apps | Sort-Object)
    } catch { Add-Problem 'Installed software' $_ }
    try {
        $f.Sql = @(Get-SqlInstances)
        foreach ($i in $f.Sql) { if ($i) { Update-SqlLive $i ([double]$s['SqlBackupMaxAgeHours']) } }
    } catch { Add-Problem 'SQL instances' $_ }
    try {
        $on = @()
        foreach ($t in '1.0', '1.1') {
            $e = Get-RegValue ('HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS ' + $t + '\Server') 'Enabled'
            if ($null -eq $e -or $e -ne 0) { $on += ('TLS ' + $t) }   # no key = Windows default = enabled
        }
        if ($on.Count) { $f.TlsLegacy = 'No (' + ($on -join ', ') + ' enabled)' } else { $f.TlsLegacy = 'Yes' }
    } catch { Add-Problem 'Legacy TLS' $_ }
    try {
        $names = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'Grace period (OOB)'; 3 = 'Grace period (OOT)'; 4 = 'Grace period (non-genuine)'; 5 = 'Notification'; 6 = 'Grace period (extended)' }
        $p = @(Get-Wmi 'SoftwareLicensingProduct' "Name LIKE 'Windows%' AND PartialProductKey IS NOT NULL")
        if ($p.Count -and $p[0]) { $f.Licence = $names[[int]$p[0].LicenseStatus] } else { $f.Licence = 'No product key installed' }
    } catch { Add-Problem 'Windows licence' $_ }
    $rel = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' 'Release'
    if ($rel) { $f.DotNet = '4.x release ' + $rel } elseif (Test-Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v3.5') { $f.DotNet = '3.5' }
    foreach ($log in 'System', 'Application') {
        try { $e = Get-EventCount $log ([double]$s['EventLogHours']); $f['Events' + $log] = "$($e.Count)"; if ($e.Top) { $f['Events' + $log] += ' (' + $e.Top + ')' } }
        catch { Add-Problem ('Event log ' + $log) $_ }
    }
    New-Object PSObject -Property $f
}

# ============================================================== result file
function ConvertTo-ResultLines($Facts, $Policy, $Data, [string]$Kind) {
    $yn = { param($b) if ($b) { 'Yes' } else { 'No' } }
    $l = @(
        'Format=VMMF1', ('Kind=' + $Kind), ('FallbackVersion=' + $FallbackVersion), ('ExportedAt=' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')),
        ('Name=' + $Facts.Name), ('OS=' + $Facts.OS), ('Edition=' + $Facts.Edition), ('InstallType=' + $Facts.InstallType), ('Lang=' + $Facts.Lang),
        ('Version=' + $Facts.Version), ('Build=' + $Facts.Build), ('UBR=' + $Facts.UBR), ('SP=' + $Facts.SP), ('Arch=' + $Facts.Arch),
        ('InstallDate=' + $Facts.InstallDate), ('LastBoot=' + $Facts.LastBoot), ('UptimeDays=' + (Num $Facts.UptimeDays)),
        ('Manufacturer=' + $Facts.Manufacturer), ('Model=' + $Facts.Model), ('Platform=' + $Facts.Platform), ('Cpus=' + $Facts.Cpus), ('RamGB=' + (Num $Facts.RamGB)),
        ('CTotalGB=' + (Num $Facts.CTotalGB)), ('CFreeGB=' + (Num $Facts.CFreeGB)),
        ('PendingReboot=' + (& $yn (@($Facts.PendingReboot).Count -gt 0))), ('PendingRebootWhy=' + (@($Facts.PendingReboot) -join ', ')),
        ('PatchCount=' + $Facts.PatchCount), ('LastPatch=' + $Facts.LastPatch), ('WuService=' + $Facts.WuService), ('Wsus=' + $Facts.Wsus),
        ('Cluster=' + $Facts.Cluster), ('Iis=' + $Facts.Iis), ('Exchange=' + $Facts.Exchange), ('DotNet=' + $Facts.DotNet), ('TimeZone=' + $Facts.TimeZone),
        ('EventsSystem=' + $Facts.EventsSystem), ('EventsApplication=' + $Facts.EventsApplication),
        ('PSVersion=' + $Facts.PSVersion), ('Elevated=' + (& $yn $Facts.Admin)),
        ('Inv.Domain=' + $Facts.Domain), ('Inv.DomainController=' + $Facts.DomainController), ('Inv.WindowsLicense=' + $Facts.Licence),
        ('Inv.TlsLegacyDisabled=' + $Facts.TlsLegacy), ('Inv.SqlPresent=' + (& $yn (@($Facts.Sql).Count -gt 0)))
    )
    $sqlShort = @()
    foreach ($i in @($Facts.Sql)) {
        if (-not $i) { continue }
        $tag = ''; if ($i.Bits -eq '32-bit') { $tag = ' (32-bit)' }
        $sqlShort += ($i.Name + ' ' + $i.Version + ' ' + $i.Edition + $tag)
        $v = Get-SqlVerdict $i $Data
        $l += ('SqlInstance=' + (@($i.Name, $i.Bits, $i.Version, $i.Level, $i.Update, $i.Edition, $i.Service, $i.Clustered, $i.Hadr, $i.Databases, @($i.Stale).Count, $v.Verdict) -join '|'))
        # Database names stay on screen only: the result file is not encrypted (db1, db2... in the order read)
        $k = 0
        foreach ($st in @($i.Stale)) { if ($st) { $k++; $l += ('SqlStaleBackup=' + $i.Name + '|db' + $k + '|' + ("$st" -split '\|')[-1]) } }
    }
    $l += ('Sql=' + ($sqlShort -join '; '))
    foreach ($k in @($Facts.Agents.Keys | Sort-Object)) { $l += ('Inv.' + $k + '=' + $Facts.Agents[$k]) }
    foreach ($d in @($Facts.Disks)) { if ($d) { $l += ('Disk=' + $d.Drive + '|' + $d.FileSystem + '|' + (Num $d.SizeGB) + '|' + (Num $d.FreeGB)) } }
    foreach ($p in @($Facts.Patches)) { if ($p) { $l += ('Patch=' + $p.Id + '|' + $p.Date.ToString('yyyy-MM-dd')) } }
    foreach ($x in @($Facts.Features)) { if ($x) { $l += ('Feature=' + $x) } }
    foreach ($x in @($Facts.Software)) { if ($x) { $l += ('Software=' + $x) } }
    if ($Policy) {
        $l += ('Policy.Scope=' + $Policy.Scope); $l += ('Policy.Why=' + $Policy.Why)
        foreach ($w in @($Policy.Warnings)) { if ($w) { $l += ('Policy.Warning=' + $w) } }
        if ($Policy.Entry) { $l += ('Policy.NextOs=' + $Policy.Entry['Next']) }
    }
    foreach ($p in @($Script:Problems)) { if ($p) { $l += ('Problem=' + $p) } }
    $l
}
function Save-ResultFile($Lines, [string]$Dir, [string]$Kind) {
    Initialize-WorkDir $Dir
    $name = 'VMMF_{0}_{1}_{2}.txt' -f ($env:COMPUTERNAME -replace '[^A-Za-z0-9_-]', '_'), $Kind, (Get-Date).ToString('yyyyMMdd_HHmmss')
    $path = Join-Path $Dir $name
    [IO.File]::WriteAllText($path, (($Lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    $path
}

# ============================================================== work folder, log, lock
function Initialize-WorkDir([string]$Dir) {
    if (Test-Path -LiteralPath $Dir) { return }
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    # Only Administrators, SYSTEM and the current user (by SID, no names) can read the folder.
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $null = & icacls.exe $Dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' "*${me}:(OI)(CI)F" 2>&1
    } catch { Warn ' Could not restrict the work folder permissions (icacls failed).' }
}
function Write-Log([string]$StepId, [string]$Status, [string]$Note) {
    try {
        Initialize-WorkDir $Script:WorkRoot
        $line = '{0}|{1}|{2}|{3}' -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'), $StepId, $Status, (Protect-Text $Note)
        Add-Content -LiteralPath (Join-Path $Script:WorkRoot ('fallback_' + (Get-Date).ToString('yyyyMMdd') + '.log')) -Value $line -Encoding ASCII
    } catch { }
}
function Enter-Lock([string]$Dir) {
    # 0 = locked, 6 = another copy holds the lock, 1 = the work folder cannot be created
    try { Initialize-WorkDir $Dir } catch { Bad (' Cannot create the work folder ' + $Dir + ': ' + (Protect-Text $_.Exception.Message)); return 1 }
    try { $Script:Lock = [IO.File]::Open((Join-Path $Dir 'fallback.lock'), 'OpenOrCreate', 'ReadWrite', 'None'); return 0 }
    catch {
        # A sharing violation (another copy holds the file) arrives wrapped in a method invocation error
        $e = $_.Exception; if ($e.InnerException) { $e = $e.InnerException }
        if ($e -is [IO.IOException]) { return 6 }
        Bad (' Cannot open the lock file in ' + $Dir + ': ' + (Protect-Text $e.Message))
        return 1
    }
}
function Exit-Lock {
    if ($Script:Lock) {
        try { $Script:Lock.Close() } catch { }
        $Script:Lock = $null
        try { Remove-Item -LiteralPath (Join-Path $Script:WorkRoot 'fallback.lock') -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# ============================================================== prompts and gates
function Test-Interactive {
    if (-not [Environment]::UserInteractive) { return $false }
    foreach ($a in [Environment]::GetCommandLineArgs()) { if ($a -like '-NonI*') { return $false } }
    $true
}
function Wait-BeforeClose {
    # Started by right-click > Run with PowerShell (the script is on this process's command line), the window
    # closes at exit: keep the last message readable. A console you typed the command in stays open anyway.
    if (-not (Test-Interactive) -or -not $Script:SelfPath) { return }
    $leaf = Split-Path -Leaf $Script:SelfPath
    $mine = $false; foreach ($a in [Environment]::GetCommandLineArgs()) { if ($a -like ('*' + $leaf + '*')) { $mine = $true } }
    if (-not $mine) { return }
    try { Read-Host ' Enter to close this window' | Out-Null } catch { }
}
function Read-Answer([string]$Prompt) {
    if (-not (Test-Interactive)) { return $null }
    try { return (Read-Host $Prompt) } catch { return $null }
}
function Confirm-Yes([string]$What) {
    # 0 = confirmed, 8 = cancelled, 2 = no console to type YES
    Warn (' ' + $What)
    $a = Read-Answer ' Type YES to run it, anything else cancels'
    if ($null -eq $a) { Bad ' No console: a change needs a person to type YES. Run it in a console.'; return 2 }
    if ($a -ceq 'YES') { return 0 }
    Mute ' Cancelled.'
    8
}
function Test-WindowStill([string]$StepId) {
    # Prompts wait for a person: read the time window again right before the change runs. 0 = still open, 3 = closed.
    $w = Get-Window $Script:Data['Settings'] ([DateTime]::UtcNow)
    if ($w.ChangesAllowed) { return 0 }
    Bad (' ' + $w.Why + ' The window closed while waiting for your answer: nothing was run.')
    Write-Log $StepId 'Blocked' 'time window closed while waiting for confirmation'
    3
}
function Confirm-Rollback([string]$StepId) {
    # Before ANY change: a rollback point (Azure snapshot, or a backup elsewhere), and management informed when
    # warnings apply (Server 2008 non-R2, physical, DC, cluster, Exchange). 0 = confirmed, 8 = cancelled, 2 = no console.
    $f = $Script:Facts
    if ($f.Platform -eq 'Azure') { $c = Confirm-Phrase 'Azure VM: a snapshot of every disk (OS and SQL data) must exist in the portal before this change.' 'SNAPSHOT TAKEN' }
    else { $c = Confirm-Phrase ('Platform ' + $f.Platform + ': a full backup or platform snapshot of this host must exist before this change.') 'BACKUP CONFIRMED' }
    if ($c) { Write-Log $StepId 'Cancelled' 'rollback point not confirmed'; return $c }
    Write-Log $StepId 'Confirmed' 'rollback point confirmed by the operator'
    $warn = @(); foreach ($w in @($Script:Policy.Warnings)) { if ($w) { $warn += $w } }
    if ($warn.Count) {
        $c = Confirm-Phrase ('Management warnings apply: ' + ($warn -join ' ')) 'MANAGEMENT INFORMED'
        if ($c) { Write-Log $StepId 'Cancelled' 'management not informed'; return $c }
        Write-Log $StepId 'Confirmed' 'operator confirmed management was informed'
    }
    0
}
function Read-Secret([string]$Prompt) {
    # Typed without echo; the plain text lives only in this call's return value
    if (-not (Test-Interactive)) { return $null }
    $sec = $null; try { $sec = Read-Host $Prompt -AsSecureString } catch { return $null }
    if (-not $sec -or $sec.Length -eq 0) { return '' }
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Confirm-Phrase([string]$What, [string]$Phrase) {
    Warn (' ' + $What)
    $a = Read-Answer (' Type ' + $Phrase + ' to confirm')
    if ($null -eq $a) { return 2 }
    if ($a -ceq $Phrase) { return 0 }
    Mute ' Cancelled.'
    8
}
function Test-Gate([string]$StepId, [switch]$OsUpgrade, $Window, $IsAdmin) {
    # The checks every change goes through, in this order: policy (5), time window (3), administrator (10).
    # -Window / -IsAdmin are only passed by the tests; on a host both are read here.
    $pol = $Script:Policy
    if (-not $pol.ChangeOk) { return New-Object PSObject -Property @{ Code = 5; Why = $pol.Why } }
    if ($OsUpgrade -and -not $pol.OsUpgradeOk) {
        $w = $pol.Why; if ($pol.Scope -eq 'InScope') { $w = 'OS upgrade is guidance only on this host: ' + (@($pol.Warnings) -join ' ') }
        return New-Object PSObject -Property @{ Code = 5; Why = $w }
    }
    $w = $Window; if ($null -eq $w) { $w = Get-Window $Script:Data['Settings'] ([DateTime]::UtcNow) }
    if (-not $w.ChangesAllowed) { return New-Object PSObject -Property @{ Code = 3; Why = $w.Why } }
    $adm = $IsAdmin; if ($null -eq $adm) { $adm = Test-Admin }
    if (-not $adm) { return New-Object PSObject -Property @{ Code = 10; Why = 'Needs administrator rights: right-click PowerShell > Run as administrator.' } }
    New-Object PSObject -Property @{ Code = 0; Why = '' }
}
function Invoke-Native([string]$Exe, [string]$Arguments) {
    Mute (' > "' + $Exe + '" ' + (Protect-Text $Arguments))
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    [int]$p.ExitCode
}

# ============================================================== media (local only)
function Get-MediaRoot { $Script:MediaRoot }
function Get-WindowsMedia {
    $d = Join-Path (Get-MediaRoot) 'Windows'
    if (-not (Test-Path -LiteralPath $d)) { return @() }
    @(Get-ChildItem -LiteralPath $d | Where-Object { $_.Extension -eq '.msu' -or $_.Extension -eq '.cab' } | Sort-Object Name)
}
function Get-FileVersionText($File) { try { return "$((Get-Item -LiteralPath $File).VersionInfo.ProductVersion)".Trim() } catch { return '' } }
function Get-SqlPatchMedia($Sql) {
    # The newest SP/CU installer in Media\Sql for this instance's major version
    $d = Join-Path (Get-MediaRoot) 'Sql'
    if (-not (Test-Path -LiteralPath $d)) { return $null }
    $major = Get-SqlMajor $Sql.Version
    $best = $null; $bestV = $null
    foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.exe')) {
        if (-not $f) { continue }
        $v = Get-FileVersionText $f.FullName
        if ($null -eq $major -or (Get-SqlMajor $v) -ne $major) { continue }
        $vv = $null; try { $vv = New-Object Version ($v -replace '[^\d\.].*$', '') } catch { continue }
        if (-not $bestV -or $vv -gt $bestV) { $best = $f.FullName; $bestV = $vv }
    }
    if ($best) { return New-Object PSObject -Property @{ Path = $best; Version = "$bestV" } }
    $null
}
function Get-SqlUpgradeMedia($Option, $Data) {
    $d = Join-Path (Get-MediaRoot) 'SqlUpgrade'
    if (-not $Option -or -not (Test-Path -LiteralPath $d)) { return @() }
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $d -Recurse -Filter 'setup.exe')) {
        if (-not $f) { continue }
        $e = Get-SqlVersionEntry (Get-SqlMajor (Get-FileVersionText $f.FullName)) $Data
        if ($e -and @($Option.To) -contains $e['Name']) { $out += New-Object PSObject -Property @{ Path = $f.FullName; Name = $e['Name'] } }
    }
    $out
}
function Get-OsMedia([string]$NextBuild) {
    # setup.exe in Media\Os, or on any drive that holds sources\install.wim (a mounted ISO). Build must match the next hop.
    $cand = @(Join-Path (Get-MediaRoot) 'Os')
    try { foreach ($d in @(Get-Wmi 'Win32_LogicalDisk')) { if ($d -and $d.DeviceID) { $cand += ($d.DeviceID + '\') } } } catch { }
    $found = @()
    foreach ($c in $cand) {
        $setup = Join-Path $c 'setup.exe'
        if (-not (Test-Path -LiteralPath $setup) -or -not (Test-Path -LiteralPath (Join-Path $c 'sources'))) { continue }
        $b = ''; try { $b = "$((Get-Item -LiteralPath (Join-Path $c 'sources\setup.exe')).VersionInfo.FileBuildPart)" } catch { }
        if (-not $b) { try { $b = "$((Get-Item -LiteralPath $setup).VersionInfo.FileBuildPart)" } catch { } }
        $found += New-Object PSObject -Property @{ Root = $c.TrimEnd('\'); Setup = $setup; Build = $b; Match = ($b -eq $NextBuild) }
    }
    $found
}
function Get-WimImages([string]$Root) {
    $wim = Join-Path $Root 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $wim)) { $wim = Join-Path $Root 'sources\install.esd' }
    $out = @()
    if (Get-Command Get-WindowsImage -ErrorAction SilentlyContinue) {
        try { foreach ($i in @(Get-WindowsImage -ImagePath $wim -ErrorAction Stop)) { $out += New-Object PSObject -Property @{ Index = $i.ImageIndex; Name = "$($i.ImageName)" } }; return $out } catch { }
    }
    try {
        $idx = $null
        foreach ($l in @(& dism.exe /English /Get-WimInfo ('/WimFile:' + $wim))) {
            if ("$l" -match '^Index\s*:\s*(\d+)') { $idx = [int]$Matches[1] }
            elseif ("$l" -match '^Name\s*:\s*(.+)$' -and $idx) { $out += New-Object PSObject -Property @{ Index = $idx; Name = $Matches[1].Trim() }; $idx = $null }
        }
    } catch { }
    $out
}
function Copy-Media([string]$Sub) {
    # Staging: copy one media sub folder into the work folder (C:\Temp). Allowed in business hours.
    if ($Script:Policy -and $Script:Policy.Scope -eq 'ClientOs') { Bad (' ' + $Script:Policy.Why + ' Staging copies files onto it: refused.'); Write-Log 'Stage' 'Blocked' 'client OS without -Order'; return 5 }
    $src = Join-Path $Script:MediaRoot $Sub
    $dst = Join-Path (Join-Path $Script:WorkRoot 'Media') $Sub
    if (-not (Test-Path -LiteralPath $src)) { Bad (" Nothing to stage: $src does not exist. Put the files there first (local media only, nothing is downloaded).") ; return 5 }
    if ($src.TrimEnd('\') -ieq $dst.TrimEnd('\')) { Good ' Media is already in the work folder.'; return 0 }
    $bytes = 0; foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse | Where-Object { -not $_.PSIsContainer })) { if ($f) { $bytes += $f.Length } }
    $freeGB = $Script:Facts.CFreeGB
    if ($null -ne $freeGB -and ($bytes / 1GB) + 2 -gt $freeGB) { Bad (' Not enough free space on C: to stage {0:N1} GB (free {1} GB).' -f ($bytes / 1GB), $freeGB); return 5 }
    Initialize-WorkDir (Join-Path $Script:WorkRoot 'Media')
    Info (' Copying {0:N1} GB from {1} to {2} ...' -f ($bytes / 1GB), $src, $dst)
    Copy-Item -LiteralPath $src -Destination (Join-Path $Script:WorkRoot 'Media') -Recurse -Force
    $Script:MediaRoot = Join-Path $Script:WorkRoot 'Media'
    Write-Log 'Stage' 'Success' ("staged $Sub")
    Good ' Staged. The media folder for this session is now the work folder copy.'
    0
}

# ============================================================== screens
function Show-Header {
    Write-Host ''
    Info (' VmMaintenance FALLBACK ' + $FallbackVersion + '  -  the last fallback for this host (no vmm, no network)')
    $w = Get-Window $Script:Data['Settings'] ([DateTime]::UtcNow)
    if ($w.ChangesAllowed) { Good (' ' + $w.Why) } else { Warn (' ' + $w.Why) }
    if (-not (Test-Admin)) { Warn ' Not running as administrator: reads that need it fail, changes are refused (exit 10).' }
}
function Show-Facts($f, $pol) {
    Write-Host ''
    Info ' This host'
    Write-Host (' OS        : {0} (build {1}.{2}, {3}, {4})' -f $f.OS, $f.Build, $f.UBR, $f.Edition, $f.InstallType)
    Write-Host (' Platform  : {0}  {1} {2}' -f $f.Platform, $f.Manufacturer, $f.Model)
    Write-Host (' CPU / RAM : {0} logical / {1} GB   Uptime {2} days' -f $f.Cpus, $f.RamGB, $f.UptimeDays)
    foreach ($d in @($f.Disks)) {
        if (-not $d) { continue }
        $t = (' Disk {0}   : {1} GB, {2} GB free ({3})' -f $d.Drive, $d.SizeGB, $d.FreeGB, $d.FileSystem)
        if ($d.SizeGB -gt 0 -and ($d.FreeGB / $d.SizeGB) -lt 0.1) { Warn $t } else { Write-Host $t }
    }
    $pr = @($f.PendingReboot)
    if ($pr.Count) { Warn (' Reboot    : PENDING (' + ($pr -join ', ') + ')') } else { Good ' Reboot    : none pending' }
    Write-Host (' Patches   : {0} installed, last {1}   Windows Update service {2}, WSUS {3}' -f $f.PatchCount, $f.LastPatch, $f.WuService, $f.Wsus)
    Write-Host (' Roles     : DC {0}, cluster {1}, IIS {2}, Exchange {3}, {4} features' -f $f.DomainController, $f.Cluster, $f.Iis, $f.Exchange, @($f.Features).Count)
    if (@($f.Sql).Count -eq 0) { Write-Host ' SQL       : none' }
    foreach ($i in @($f.Sql)) {
        if (-not $i) { continue }
        $v = Get-SqlVerdict $i $Script:Data
        $t = (' SQL       : {0} ({1}) {2} {3} {4} {5}, service {6}, {7} dbs, {8} without a fresh full backup -> {9}' -f $i.Name, $i.Bits, $v.Name, $i.Version, $i.Level, $i.Update, $i.Service, $i.Databases, @($i.Stale).Count, $v.Verdict)
        if ($v.Verdict -eq 'OK' -and @($i.Stale).Count -eq 0) { Good $t } else { Warn $t }
    }
    $ag = @(); foreach ($k in @($f.Agents.Keys | Sort-Object)) { $ag += ($k + ' ' + $f.Agents[$k]) }
    if ($ag.Count) { Write-Host (' Agents    : ' + ($ag -join ', ')) }
    Write-Host (' Errors    : System {0}; Application {1} (last {2} h)' -f $f.EventsSystem, $f.EventsApplication, $Script:Data['Settings']['EventLogHours'])
    Write-Host ''
    $line = (' Policy    : {0} - {1}' -f $pol.Scope, $pol.Why)
    if ($pol.ChangeOk) { Good $line } else { Warn $line }
    foreach ($w in @($pol.Warnings)) { if ($w) { Warn (' WARNING   : ' + $w) } }
    if (@($Script:Problems).Count) {
        Warn (' {0} read(s) failed; the rest is complete:' -f @($Script:Problems).Count)
        foreach ($p in @($Script:Problems)) { Warn ('   ' + $p) }
    }
}
function Get-PlaceholderMap($SqlName, $SqlMedia, $OsMedia) {
    $f = $Script:Facts; $s = $Script:Data['Settings']
    $next = '-'; if ($Script:Policy.Entry -and $Script:Policy.Entry['Next']) { $next = $Script:Policy.Entry['Next'] }
    $inst = $SqlName; if (-not $inst) { $inst = '<instance>' }
    $sm = $SqlMedia; if (-not $sm) { $sm = (Join-Path $Script:MediaRoot 'Sql') + '\<installer>.exe' }
    $om = $OsMedia; if (-not $om) { $om = '<ISO drive or ' + (Join-Path $Script:MediaRoot 'Os') + '>' }
    @{ WorkDir = $Script:WorkRoot; MediaDir = $Script:MediaRoot; TargetOs = $s['TargetOs']; Os = $f.OS; NextOs = $next
       Instance = $inst; SqlMedia = $sm; OsMedia = $om; MinFreeGB = $s['MinFreeGBOsUpgrade']; FreeGB = $f.CFreeGB }
}
function Show-Advice([string]$StepId, $Map) {
    $d = Get-StepDef $StepId
    Write-Host ''
    Info (' ' + $StepId + ': ' + $d['Title'])
    foreach ($l in @($d['Advice'])) { Write-Host ('   ' + (Expand-Text $l $Map)) }
}
function Show-Manual([string]$StepId, $Map, $Extra) {
    # Guidance only: nothing is changed. The companion file's manual lines, then the exact commands for this host.
    $d = Get-StepDef $StepId
    Write-Host ''
    Info ' Guidance only (nothing is changed). Do it by hand:'
    $n = 0
    foreach ($l in @($d['Manual'])) { $n++; Write-Host ('   {0}. {1}' -f $n, (Expand-Text $l $Map)) }
    if ($Extra) {
        Info ' For this host:'
        foreach ($l in @($Extra)) { if ($l) { Write-Host ('   ' + $l) } }
    }
    Write-Log $StepId 'Guidance' 'manual instructions shown'
    0
}
function Read-Choice([string]$Options) {
    $a = Read-Answer (' Choose ' + $Options)
    if ($null -eq $a) { return 'B' }
    "$a".Trim().ToUpper()
}

# ============================================================== steps
function Invoke-StepSnapshot([string]$Kind) {
    if (-not $Kind) { $Kind = 'snapshot' }
    Info ' Reading this host (read-only)...'
    $Script:Problems = @()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $Script:Facts = Get-Facts $Script:Data
    $Script:Policy = Get-Policy $Script:Facts $Script:Data $Order
    $lines = ConvertTo-ResultLines $Script:Facts $Script:Policy $Script:Data $Kind
    $sw.Stop()
    $lines += ('Seconds=' + [int]$sw.Elapsed.TotalSeconds)
    Show-Facts $Script:Facts $Script:Policy
    $file = $null
    try { $file = Save-ResultFile $lines $Script:WorkRoot $Kind } catch { Bad (' Could not save the result file: ' + (Protect-Text $_.Exception.Message)) }
    Write-Host ''
    if (-not $file) { Write-Log 'Snapshot' 'Failed' 'result file not saved'; return 1 }
    Good (' SAVED: ' + $file + ('   ({0} s)' -f [int]$sw.Elapsed.TotalSeconds))
    Warn ' The file is NOT encrypted (no laptop key here). Keep it on this host or carry it only to the vmm laptop.'
    $Script:LastResult = $file
    Write-Log 'Snapshot' 'Success' ("$Kind saved, $(@($Script:Problems).Count) read(s) failed")
    if (@($Script:Problems).Count) { return 7 }
    0
}
function Invoke-StepPrecheck([string]$Act) {
    $f = $Script:Facts; $s = $Script:Data['Settings']; $map = Get-PlaceholderMap '' '' ''
    Show-Advice 'Precheck' $map
    if ($Act -eq 'Guide') { return (Show-Manual 'Precheck' $map $null) }
    $bad = 0
    Write-Host ''
    $pr = @($f.PendingReboot)
    if ($pr.Count) { Bad (' [STOP] Reboot pending (' + ($pr -join ', ') + '): reboot in the maintenance window before any change.'); $bad++ } else { Good ' [ OK ] No reboot pending.' }
    if ($null -eq $f.CFreeGB) { Warn ' [WARN] C: free space unknown.' }
    elseif ($f.CFreeGB -lt $s['MinFreeGBPatch']) { Bad (' [STOP] C: has {0} GB free, patches need {1} GB (step Disk).' -f $f.CFreeGB, $s['MinFreeGBPatch']); $bad++ }
    elseif ($f.CFreeGB -lt $s['MinFreeGBOsUpgrade']) { Warn (' [WARN] C: has {0} GB free: enough to patch, not for an OS upgrade ({1} GB).' -f $f.CFreeGB, $s['MinFreeGBOsUpgrade']) }
    else { Good (' [ OK ] C: has {0} GB free.' -f $f.CFreeGB) }
    if ("$($f.WuService)" -like 'Disabled*' -or "$($f.WuService)" -like '*(Disabled)*') { Warn ' [WARN] Windows Update service is disabled: offline .msu files still install with wusa.' } else { Good (' [ OK ] Windows Update service: ' + $f.WuService) }
    foreach ($i in @($f.Sql)) {
        if (-not $i) { continue }
        if (-not $i.Live) { Warn (' [WARN] SQL ' + $i.Name + ': backup age unknown (' + $i.Service + ', ' + $i.LiveError + '). Run as a SQL sysadmin to check.') }
        elseif (@($i.Stale).Count) { Bad (' [STOP] SQL ' + $i.Name + ': ' + @($i.Stale).Count + ' database(s) without a full backup in ' + $s['SqlBackupMaxAgeHours'] + ' h: ' + ((@($i.Stale) | Select-Object -First 5) -join ', ')); $bad++ }
        else { Good (' [ OK ] SQL ' + $i.Name + ': every database has a recent full backup.') }
        $v = Get-SqlVerdict $i $Script:Data
        if ($v.Verdict -ne 'OK') { Warn (' [WARN] SQL ' + $i.Name + ': ' + $v.Why) }
    }
    foreach ($w in @($Script:Policy.Warnings)) { if ($w) { Warn (' [WARN] ' + $w) } }
    if ($f.Platform -eq 'Azure') { Warn ' [TODO] Azure: take a snapshot of the OS disk (and SQL data disks) in the portal before any change.' }
    $code = 0; if ($bad) { $code = 5 }
    Write-Log 'Precheck' ($(if ($bad) { 'Blocked' } else { 'Success' })) ("$bad blocking finding(s)")
    if ($bad) { Warn (' {0} blocking finding(s): fix them before the change steps.' -f $bad) } else { Good ' Pre-checks passed.' }
    $code
}
function Invoke-StepWindowsPatch([string]$Act) {
    $map = Get-PlaceholderMap '' '' ''
    Show-Advice 'WindowsPatch' $map
    $files = @(Get-WindowsMedia)
    $extra = @()
    foreach ($x in $files) {
        if (-not $x) { continue }
        if ($x.Extension -eq '.msu') { $extra += ('wusa.exe "' + $x.FullName + '" /quiet /norestart') }
        else { $extra += ('dism.exe /online /add-package /packagepath:"' + $x.FullName + '" /quiet /norestart') }
    }
    if (-not $extra.Count) { $extra += ('No .msu/.cab files in ' + (Join-Path $Script:MediaRoot 'Windows') + ' yet.') }
    if ($Act -eq 'Guide') { return (Show-Manual 'WindowsPatch' $map $extra) }
    if ($Act -eq 'Stage') { return (Copy-Media 'Windows') }
    if ($Act -eq 'Menu') {
        Write-Host (' Offline packages found: {0}' -f $files.Count)
        $c = Read-Choice '[R] run offline packages, [G] guidance only, [T] stage media, [B] back'
        switch ($c) { 'R' { $Act = 'Run' } 'G' { return (Show-Manual 'WindowsPatch' $map $extra) } 'T' { return (Copy-Media 'Windows') } default { return 0 } }
    }
    $g = Test-Gate 'WindowsPatch'
    if ($g.Code) { Bad (' ' + $g.Why); Write-Log 'WindowsPatch' 'Blocked' $g.Why; return $g.Code }
    if (@($Script:Facts.PendingReboot).Count) { Bad ' A reboot is pending: reboot first, then patch.'; Write-Log 'WindowsPatch' 'Blocked' 'pending reboot'; return 5 }
    if (-not $files.Count) { Bad (' No .msu/.cab files in ' + (Join-Path $Script:MediaRoot 'Windows') + '. Copy them there (local media only, nothing is downloaded).'); return 5 }
    $c = Confirm-Rollback 'WindowsPatch'; if ($c) { return $c }
    $c = Confirm-Yes ('Install {0} package(s) from {1} with wusa/DISM, no reboot.' -f $files.Count, (Join-Path $Script:MediaRoot 'Windows'))
    if ($c) { Write-Log 'WindowsPatch' 'Cancelled' ''; return $c }
    $c = Test-WindowStill 'WindowsPatch'; if ($c) { return $c }
    $reboot = $false; $failed = 0
    foreach ($x in $files) {
        if (-not $x) { continue }
        if ($x.Extension -eq '.msu') { $e = Invoke-Native (Join-Path $env:SystemRoot 'System32\wusa.exe') ('"' + $x.FullName + '" /quiet /norestart'); $v = Get-NativeVerdict ('wusa ' + $x.Name) $e }
        else { $e = Invoke-Native (Join-Path $env:SystemRoot 'System32\dism.exe') ('/online /add-package /packagepath:"' + $x.FullName + '" /quiet /norestart'); $v = Get-NativeVerdict ('dism ' + $x.Name) $e }
        switch ($v.Result) { 'Ok' { Good (' ' + $v.Message) } 'Reboot' { Good (' ' + $v.Message); $reboot = $true } 'Skip' { Mute (' ' + $v.Message) } default { Bad (' ' + $v.Message); $failed++ } }
        Write-Log 'WindowsPatch' $v.Result $v.Message
    }
    if ($failed) { Bad (' {0} package(s) failed: read C:\Windows\Logs\CBS\CBS.log and the Setup event log.' -f $failed); return 1 }
    if ($reboot) { Warn ' Reboot needed: reboot in the maintenance window, then run the snapshot again.'; return 9 }
    Good ' Windows packages done.'
    0
}
function Select-SqlInstance {
    $all = @(); foreach ($i in @($Script:Facts.Sql)) { if ($i) { $all += $i } }
    if (-not $all.Count) { return $null }
    if ($Instance) { foreach ($i in $all) { if ($i.Name -ieq $Instance) { return $i } }; Bad (" SQL instance '$Instance' not found on this host."); return $null }
    if ($all.Count -eq 1) { return $all[0] }
    for ($n = 0; $n -lt $all.Count; $n++) { Write-Host ('   {0}. {1} ({2}) {3} {4}' -f ($n + 1), $all[$n].Name, $all[$n].Bits, $all[$n].Version, $all[$n].Level) }
    $a = Read-Answer ' Instance number'
    $k = 0; if ([int]::TryParse("$a", [ref]$k) -and $k -ge 1 -and $k -le $all.Count) { return $all[$k - 1] }
    $null
}
function Test-SqlSafe($Sql) {
    # Safety checks before SQL setup touches an instance: 0 ok, 5 refused (reason shown)
    if ($Sql.Clustered -eq 'Yes' -or $Sql.Hadr -eq 'Yes' -or $Script:Facts.Cluster -eq 'Yes') { Bad ' Clustered or Always On instance: guidance only (rolling patch, secondaries first).'; return 5 }
    if (-not $Sql.Live) { Bad (' Cannot check the backups of ' + $Sql.Name + ' (' + $Sql.LiveError + '). Run this script as a SQL sysadmin (Windows login).'); return 5 }
    if (@($Sql.Stale).Count) { Bad (' ' + @($Sql.Stale).Count + ' database(s) without a fresh full backup: ' + ((@($Sql.Stale) | Select-Object -First 5) -join ', ') + '. Back them up first.'); return 5 }
    if (@($Script:Facts.PendingReboot).Count) { Bad ' A reboot is pending: reboot first (SQL setup fails its rule check otherwise).'; return 5 }
    if ($null -ne $Script:Facts.CFreeGB -and $Script:Facts.CFreeGB -lt $Script:Data['Settings']['MinFreeGBSql']) { Bad (' C: has {0} GB free, SQL setup needs {1} GB.' -f $Script:Facts.CFreeGB, $Script:Data['Settings']['MinFreeGBSql']); return 5 }
    0
}
function Invoke-StepSqlPatch([string]$Act) {
    $sql = Select-SqlInstance
    if (-not $sql) { Show-Advice 'SqlPatch' (Get-PlaceholderMap '' '' ''); Good ' No SQL instance selected or found: nothing to patch.'; return 0 }
    $media = Get-SqlPatchMedia $sql
    $mp = ''; if ($media) { $mp = $media.Path }
    $map = Get-PlaceholderMap $sql.Name $mp ''
    Show-Advice 'SqlPatch' $map
    $major = Get-SqlMajor $sql.Version
    $acc = ' /IAcceptSQLServerLicenseTerms'; if ($major -lt 10.5) { $acc = '' }
    $cmdArgs = '/quiet' + $acc + ' /Action=Patch /InstanceName=' + $sql.Name
    $extra = @(('Instance {0} ({1}): {2} {3} {4}' -f $sql.Name, $sql.Bits, $sql.Version, $sql.Level, $sql.Update))
    if ($media) { $extra += ('Installer found: ' + $media.Path + ' (version ' + $media.Version + ')'); $extra += ('"' + $media.Path + '" ' + $cmdArgs) }
    else { $extra += ('No installer for this version in ' + (Join-Path $Script:MediaRoot 'Sql') + ': copy the latest SP/CU .exe there.') }
    if ($Act -eq 'Guide') { return (Show-Manual 'SqlPatch' $map $extra) }
    if ($Act -eq 'Stage') { return (Copy-Media 'Sql') }
    if ($Act -eq 'Menu') {
        $c = Read-Choice '[R] run the patch, [G] guidance only, [T] stage media, [B] back'
        switch ($c) { 'R' { } 'G' { return (Show-Manual 'SqlPatch' $map $extra) } 'T' { return (Copy-Media 'Sql') } default { return 0 } }
    }
    $g = Test-Gate 'SqlPatch'
    if ($g.Code) { Bad (' ' + $g.Why); Write-Log 'SqlPatch' 'Blocked' $g.Why; return $g.Code }
    $s = Test-SqlSafe $sql
    if ($s) { Write-Log 'SqlPatch' 'Blocked' ('safety check ' + $sql.Name); return $s }
    if (-not $media) { Bad (' No installer for ' + $sql.Name + ' in ' + (Join-Path $Script:MediaRoot 'Sql') + '.'); return 5 }
    $cur = $null; $new = $null
    try { $cur = New-Object Version ($sql.Version -replace '[^\d\.].*$', ''); $new = New-Object Version $media.Version } catch { }
    if ($cur -and $new -and $new -le $cur) { Good (' ' + $sql.Name + ' is already at ' + $sql.Version + ' (installer ' + $media.Version + '): nothing to do.'); Write-Log 'SqlPatch' 'NotNeeded' $sql.Name; return 0 }
    $c = Confirm-Rollback 'SqlPatch'; if ($c) { return $c }
    $c = Confirm-Yes ('Patch SQL instance ' + $sql.Name + ' to ' + $media.Version + '. The instance restarts.')
    if ($c) { Write-Log 'SqlPatch' 'Cancelled' $sql.Name; return $c }
    $c = Test-WindowStill 'SqlPatch'; if ($c) { return $c }
    $v = Get-NativeVerdict 'SQL setup' (Invoke-Native $media.Path $cmdArgs)
    Write-Log 'SqlPatch' $v.Result ($sql.Name + ': ' + $v.Message)
    switch ($v.Result) {
        'Ok'     { Good (' ' + $v.Message + '. Check the application, then run the snapshot again.'); return 0 }
        'Reboot' { Warn (' ' + $v.Message + '. Reboot in the maintenance window.'); return 9 }
        default  { Bad (' ' + $v.Message + '. Read Setup Bootstrap\Log\Summary.txt under the SQL Server program folder.'); return 1 }
    }
}
function Invoke-StepSqlUpgrade([string]$Act) {
    $sql = Select-SqlInstance
    if (-not $sql) { Show-Advice 'SqlUpgrade' (Get-PlaceholderMap '' '' ''); Good ' No SQL instance selected or found: nothing to upgrade.'; return 0 }
    $verdict = Get-SqlVerdict $sql $Script:Data
    $opt = Get-SqlUpgradeOption $sql $Script:Data
    $media = @(Get-SqlUpgradeMedia $opt $Script:Data)
    $mp = ''; if ($media.Count) { $mp = $media[0].Path }
    $map = Get-PlaceholderMap $sql.Name $mp ''
    Show-Advice 'SqlUpgrade' $map
    $extra = @(('Instance {0}: {1} -> {2}' -f $sql.Name, $verdict.Verdict, $verdict.Why))
    if ($opt) {
        $extra += ('In-place targets: ' + (@($opt.To) -join ', ') + ' (needs ' + $opt.MinLevel + ' or later; now ' + $sql.Level + ')')
        if (-not $opt.LevelOk) { $extra += ('Patch to ' + $opt.MinLevel + ' first (step SqlPatch).') }
        if ($opt.Note) { $extra += $opt.Note }
    } else { $extra += 'No in-place upgrade listed for this version in the companion file: migrate to a new instance.' }
    $cmdArgs = '/q /ACTION=Upgrade /INSTANCENAME=' + $sql.Name + ' /IACCEPTSQLSERVERLICENSETERMS /UpdateEnabled=False'
    foreach ($m in $media) { if ($m) { $extra += ('Media: ' + $m.Name + ' - "' + $m.Path + '" ' + $cmdArgs) } }
    if ($Act -eq 'Guide') { return (Show-Manual 'SqlUpgrade' $map $extra) }
    if ($Act -eq 'Stage') { return (Copy-Media 'SqlUpgrade') }
    if ($Act -eq 'Menu') {
        $c = Read-Choice '[R] run the upgrade, [G] guidance only, [T] stage media, [B] back'
        switch ($c) { 'R' { } 'G' { return (Show-Manual 'SqlUpgrade' $map $extra) } 'T' { return (Copy-Media 'SqlUpgrade') } default { return 0 } }
    }
    $g = Test-Gate 'SqlUpgrade'
    if ($g.Code) { Bad (' ' + $g.Why); Write-Log 'SqlUpgrade' 'Blocked' $g.Why; return $g.Code }
    if (-not $opt) { Bad ' No in-place upgrade path for this version: guidance only.'; return 5 }
    if (-not $opt.LevelOk) { Bad (' ' + $sql.Name + ' is at ' + $sql.Level + '; the upgrade needs ' + $opt.MinLevel + '. Run SqlPatch first.'); return 5 }
    $s = Test-SqlSafe $sql
    if ($s) { Write-Log 'SqlUpgrade' 'Blocked' ('safety check ' + $sql.Name); return $s }
    if (-not $media.Count) { Bad (' No setup.exe for ' + (@($opt.To) -join '/') + ' in ' + (Join-Path $Script:MediaRoot 'SqlUpgrade') + '.'); return 5 }
    $m = $media[0]
    if ($media.Count -gt 1) {
        for ($n = 0; $n -lt $media.Count; $n++) { Write-Host ('   {0}. {1}  {2}' -f ($n + 1), $media[$n].Name, $media[$n].Path) }
        $a = Read-Answer ' Media number'; $k = 0
        if (-not ([int]::TryParse("$a", [ref]$k) -and $k -ge 1 -and $k -le $media.Count)) { Mute ' Cancelled.'; return 8 }
        $m = $media[$k - 1]
    }
    $c = Confirm-Rollback 'SqlUpgrade'; if ($c) { return $c }
    $c = Confirm-Yes ('Upgrade SQL instance ' + $sql.Name + ' (' + $verdict.Name + ') to ' + $m.Name + ' in place. Databases stay; the instance is offline during setup.')
    if ($c) { Write-Log 'SqlUpgrade' 'Cancelled' $sql.Name; return $c }
    # Product key: typed without echo, used once, never logged or stored. Empty = the key carried by the media.
    $pidKey = Read-Secret ' Product key for the licensed edition, not shown while typing (empty = use the key on the media)'
    $c = Test-WindowStill 'SqlUpgrade'; if ($c) { $pidKey = $null; return $c }
    $run = $cmdArgs; if ($pidKey) { $run += (' /PID=' + "$pidKey".Trim()) }
    $v = Get-NativeVerdict 'SQL setup' (Invoke-Native $m.Path $run)
    $pidKey = $null; $run = $null
    Write-Log 'SqlUpgrade' $v.Result ($sql.Name + ' to ' + $m.Name + ': ' + $v.Message)
    switch ($v.Result) {
        'Ok'     { Good (' ' + $v.Message + '. Test the application; set database compatibility levels only with the owner''s agreement.'); return 0 }
        'Reboot' { Warn (' ' + $v.Message + '. Reboot in the maintenance window.'); return 9 }
        default  { Bad (' ' + $v.Message + '. Read Setup Bootstrap\Log\Summary.txt.'); return 1 }
    }
}
function Invoke-StepOsUpgrade([string]$Act) {
    $pol = $Script:Policy; $f = $Script:Facts; $s = $Script:Data['Settings']
    $next = ''; $nb = ''; if ($pol.Entry) { $next = "$($pol.Entry['Next'])"; $nb = "$($pol.Entry['NextBuild'])" }
    $media = @(); if ($nb) { $media = @(Get-OsMedia $nb) }
    $good = $null; foreach ($m in $media) { if ($m -and $m.Match -and -not $good) { $good = $m } }
    $om = ''; if ($good) { $om = $good.Root }
    $map = Get-PlaceholderMap '' '' $om
    Show-Advice 'OsUpgrade' $map
    $extra = @(('Policy: {0} - {1}' -f $pol.Scope, $pol.Why))
    if ($pol.Entry -and $pol.Entry['Note']) { $extra += ('Path: ' + $pol.Entry['Note']) }
    foreach ($w in @($pol.Warnings)) { if ($w) { $extra += ('Warning: ' + $w) } }
    foreach ($i in @($f.Sql)) {
        if (-not $i) { continue }
        $v = Get-SqlVerdict $i $Script:Data
        if ($next -eq $s['TargetOs'] -and $v.Verdict -ne 'OK') { $extra += ('SQL ' + $i.Name + ': ' + $v.Why + ' Fix it before the OS upgrade.') }
        elseif ($next -and $next -ne $s['TargetOs']) { $extra += ('SQL ' + $i.Name + ': check it is supported on ' + $next + ' (intermediate hop).') }
    }
    foreach ($m in $media) { if ($m) { $extra += ('Media: ' + $m.Root + ' build ' + $m.Build + $(if ($m.Match) { ' (matches ' + $next + ')' } else { ' (NOT ' + $next + ', build ' + $nb + ' needed)' })) } }
    if (-not $media.Count -and $nb) { $extra += ('No setup media found: mount the ' + $next + ' ISO or extract it to ' + (Join-Path $Script:MediaRoot 'Os') + '.') }
    $auto = $nb -and ([int]$nb -ge 10240)
    if ($nb -and -not $auto) { $extra += ('Setup for ' + $next + ' has no unattended upgrade switch: run setup.exe from the ISO by hand and choose Upgrade.') }
    if ($Act -eq 'Guide') { return (Show-Manual 'OsUpgrade' $map $extra) }
    if ($Act -eq 'Stage') { return (Copy-Media 'Os') }
    if ($Act -eq 'Menu') {
        $c = Read-Choice '[C] compatibility scan, [R] run the upgrade, [G] guidance only, [T] stage media, [B] back'
        switch ($c) { 'C' { $Act = 'Scan' } 'R' { } 'G' { return (Show-Manual 'OsUpgrade' $map $extra) } 'T' { return (Copy-Media 'Os') } default { return 0 } }
    }
    $g = Test-Gate 'OsUpgrade' -OsUpgrade
    if ($g.Code) { Bad (' ' + $g.Why); Write-Log 'OsUpgrade' 'Blocked' $g.Why; return $g.Code }
    if (-not $auto) { Bad (' No unattended upgrade for ' + $next + ': guidance only (G).'); return 5 }
    if (@($f.PendingReboot).Count) { Bad ' A reboot is pending: reboot first.'; return 5 }
    if ($null -eq $f.CFreeGB -or $f.CFreeGB -lt $s['MinFreeGBOsUpgrade']) { Bad (' C: has {0} GB free, the upgrade needs {1} GB (step Disk).' -f $f.CFreeGB, $s['MinFreeGBOsUpgrade']); return 5 }
    if ($next -eq $s['TargetOs']) {
        foreach ($i in @($f.Sql)) { if ($i -and (Get-SqlVerdict $i $Script:Data).Verdict -ne 'OK') { Bad (' SQL ' + $i.Name + ' is not ready for ' + $next + ': run SqlPatch/SqlUpgrade first.'); return 5 } }
    }
    if (-not $good) { Bad (' No ' + $next + ' setup media (build ' + $nb + ') found. Mount the ISO or extract it to ' + (Join-Path $Script:MediaRoot 'Os') + '.'); return 5 }
    $c = Confirm-Rollback 'OsUpgrade'; if ($c) { return $c }
    $base = '/auto upgrade /quiet /dynamicupdate disable /noreboot'
    if ($Act -eq 'Scan') {
        $c = Confirm-Yes ('Run the ' + $next + ' compatibility scan (no upgrade; setup writes its working folder on C:).')
        if ($c) { return $c }
        $c = Test-WindowStill 'OsUpgrade'; if ($c) { return $c }
        $v = Get-NativeVerdict 'Windows setup' (Invoke-Native $good.Setup ($base + ' /compat scanonly'))
        Write-Log 'OsUpgrade' ('Scan' + $v.Result) $v.Message
        if ($v.Result -eq 'Ok') { Good (' ' + $v.Message); return 0 }
        Bad (' ' + $v.Message + '. Logs: C:\$WINDOWS.~BT\Sources\Panther\'); return 1
    }
    $images = @(Get-WimImages $good.Root)
    $isCore = "$($f.InstallType)" -like '*Core*'
    $idx = Select-ImageIndex $images $f.Edition $isCore
    foreach ($im in $images) { if ($im) { Write-Host ('   index {0}: {1}' -f $im.Index, $im.Name) } }
    if (-not $idx) {
        $a = Read-Answer (' Image index matching ' + $f.Edition + ' ' + $f.InstallType + ' (empty cancels)')
        if (-not ([int]::TryParse("$a", [ref]$idx)) -or $idx -lt 1) { Mute ' Cancelled.'; return 8 }
    } else { Good (' Image index {0} matches {1} {2}.' -f $idx, $f.Edition, $f.InstallType) }
    $c = Confirm-Yes ('Upgrade this host from ' + $f.OS + ' to ' + $next + ' (index ' + $idx + ', keep files and apps). Setup stops before its reboot; YOU reboot to continue.')
    if ($c) { Write-Log 'OsUpgrade' 'Cancelled' ''; return $c }
    $c = Test-WindowStill 'OsUpgrade'; if ($c) { return $c }
    $v = Get-NativeVerdict 'Windows setup' (Invoke-Native $good.Setup ($base + ' /imageindex ' + $idx))
    Write-Log 'OsUpgrade' $v.Result $v.Message
    if ($v.Result -eq 'Ok' -or $v.Result -eq 'Reboot') {
        Warn (' ' + $v.Message + '. Reboot now in the maintenance window to continue the upgrade; it restarts several times.')
        Warn ' Afterwards run this script again: snapshot, then the next hop if any.'
        return 9
    }
    Bad (' ' + $v.Message + '. Logs: C:\$WINDOWS.~BT\Sources\Panther\setuperr.log')
    1
}
function Invoke-StepDisk([string]$Act) {
    $f = $Script:Facts; $s = $Script:Data['Settings']
    $map = Get-PlaceholderMap '' '' ''
    Show-Advice 'Disk' $map
    $extra = @()
    $unalloc = $null; $maxSize = $null
    try {
        if (Get-Command Get-PartitionSupportedSize -ErrorAction SilentlyContinue) {
            $part = Get-Partition -DriveLetter C -ErrorAction Stop
            $sup = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
            $maxSize = $sup.SizeMax
            $unalloc = [math]::Round(($sup.SizeMax - $part.Size) / 1GB, 1)
        }
    } catch { }
    if ($null -ne $unalloc) { $extra += ('Space C: can grow into now: ' + $unalloc + ' GB.') }
    if ($null -ne $f.CTotalGB) {
        $tier = Get-NextDiskTier $f.CTotalGB $s['DiskTiersGB']
        if ($f.Platform -eq 'Azure' -and $tier) { $extra += ('Azure: next OS disk size ' + $tier + ' GB (now ' + $f.CTotalGB + ' GB). Snapshot, deallocate, resize, start.') }
        elseif ($f.Platform -ne 'Azure') { $extra += ('Platform ' + $f.Platform + ': grow the disk in the hypervisor/storage first.') }
    }
    if ($Act -eq 'Guide') { return (Show-Manual 'Disk' $map $extra) }
    if ($Act -eq 'Stage') { Mute ' Nothing to stage for this step.'; return 0 }
    if ($Act -eq 'Menu') {
        foreach ($l in $extra) { Write-Host ('   ' + $l) }
        $c = Read-Choice '[R] extend C: into free space, [G] guidance only, [B] back'
        switch ($c) { 'R' { } 'G' { return (Show-Manual 'Disk' $map $extra) } default { return 0 } }
    }
    $g = Test-Gate 'Disk'
    if ($g.Code) { Bad (' ' + $g.Why); Write-Log 'Disk' 'Blocked' $g.Why; return $g.Code }
    if ($null -ne $unalloc -and $unalloc -lt 1) { Bad ' There is no free space after C: to extend into. Grow the disk in Azure (or the hypervisor) first.'; Write-Log 'Disk' 'Blocked' 'no free space after C:'; return 5 }
    $msg = 'Extend C: into the free space after it'; if ($null -ne $unalloc) { $msg += (' (+' + $unalloc + ' GB)') }
    $c = Confirm-Rollback 'Disk'; if ($c) { return $c }
    $c = Confirm-Yes ($msg + '. Online operation, no reboot.')
    if ($c) { Write-Log 'Disk' 'Cancelled' ''; return $c }
    $c = Test-WindowStill 'Disk'; if ($c) { return $c }
    try {
        if ($null -ne $maxSize) { Resize-Partition -DriveLetter C -Size $maxSize -ErrorAction Stop }
        else {
            $ds = Join-Path $Script:WorkRoot 'extend-c.txt'
            Initialize-WorkDir $Script:WorkRoot
            Set-Content -LiteralPath $ds -Value @('select volume C', 'extend') -Encoding ASCII
            $e = Invoke-Native (Join-Path $env:SystemRoot 'System32\diskpart.exe') ('/s "' + $ds + '"')
            Remove-Item -LiteralPath $ds -Force -ErrorAction SilentlyContinue
            if ($e -ne 0) { throw ('diskpart exit code ' + $e + ' (no free space after C:, or C: is not the last partition before it)') }
        }
    } catch { Bad (' Extend failed: ' + (Protect-Text $_.Exception.Message)); Write-Log 'Disk' 'Failed' $_.Exception.Message; return 1 }
    Write-Log 'Disk' 'Success' 'C: extended'
    Good ' C: extended. Run the snapshot again to see the new size.'
    0
}
function Get-StoppedAutoServices {
    $skip = @('gupdate', 'gupdatem', 'sppsvc', 'RemoteRegistry', 'MapsBroker', 'edgeupdate', 'edgeupdatem', 'tiledatamodelsvc', 'wuauserv', 'BITS', 'TrustedInstaller', 'ShellHWDetection', 'CDPSvc', 'WbioSrvc', 'clr_optimization_v4.0.30319_32', 'clr_optimization_v4.0.30319_64')
    $out = @()
    try { foreach ($x in @(Get-Wmi 'Win32_Service' "StartMode='Auto' AND State<>'Running'")) { if ($x -and $skip -notcontains $x.Name) { $out += "$($x.Name)" } } } catch { Add-Problem 'Stopped automatic services' $_ }
    $out
}
function Invoke-StepPostcheck([string]$Act) {
    $map = Get-PlaceholderMap '' '' ''
    Show-Advice 'Postcheck' $map
    if ($Act -eq 'Guide') { return (Show-Manual 'Postcheck' $map $null) }
    $before = $Script:FirstFacts
    $r = Invoke-StepSnapshot 'postcheck'
    if ($r -eq 1) { return 1 }
    $after = $Script:Facts
    Write-Host ''
    Info ' Changes since the first snapshot of this session:'
    $n = 0
    if ($before) {
        foreach ($k in 'OS', 'Build', 'UBR', 'CTotalGB', 'CFreeGB', 'PatchCount', 'LastPatch') {
            if ("$($before.$k)" -ne "$($after.$k)") { Write-Host ('   {0}: {1} -> {2}' -f $k, $before.$k, $after.$k); $n++ }
        }
        foreach ($i in @($after.Sql)) {
            if (-not $i) { continue }
            foreach ($b in @($before.Sql)) { if ($b -and $b.Name -eq $i.Name -and ($b.Version -ne $i.Version -or $b.Level -ne $i.Level)) { Write-Host ('   SQL {0}: {1} {2} -> {3} {4}' -f $i.Name, $b.Version, $b.Level, $i.Version, $i.Level); $n++ } }
        }
    }
    if (-not $n) { Mute '   none' }
    $stopped = @(Get-StoppedAutoServices)
    if ($stopped.Count) { Warn (' Automatic services not running: ' + ($stopped -join ', ')) } else { Good ' Every automatic service is running.' }
    if (@($after.PendingReboot).Count) { Warn ' A reboot is still pending.' }
    Write-Log 'Postcheck' 'Success' ("$n change(s), $($stopped.Count) stopped automatic service(s)")
    if (@($after.PendingReboot).Count) { return 9 }
    $r
}
function Invoke-StepFinish([string]$Act) {
    $map = Get-PlaceholderMap '' '' ''
    Show-Advice 'Finish' $map
    if ($Act -eq 'Guide') { return (Show-Manual 'Finish' $map $null) }
    $staged = Join-Path $Script:WorkRoot 'Media'
    if ($Act -eq 'Menu') {
        $c = Read-Choice '[R] delete staged media, [A] delete the whole work folder (results and log too, once copied), [G] guidance only, [B] back'
        switch ($c) { 'R' { } 'A' { $Act = 'All' } 'G' { return (Show-Manual 'Finish' $map $null) } default { return 0 } }
    }
    if ($Act -eq 'All') {
        if ($Script:SelfPath -and $Script:SelfPath.StartsWith($Script:WorkRoot, [StringComparison]::OrdinalIgnoreCase)) { Bad ' This script is inside the work folder: copy it elsewhere first.'; return 5 }
        $c = Confirm-Yes ('Delete ' + $Script:WorkRoot + ' completely (results, log, staged media). Copy the results first.')
        if ($c) { return $c }
        Exit-Lock
        try { Remove-Item -LiteralPath $Script:WorkRoot -Recurse -Force -ErrorAction Stop } catch { Bad (' Could not delete everything: ' + (Protect-Text $_.Exception.Message)); return 1 }
        Good ' Work folder deleted.'
        return 0
    }
    if (-not (Test-Path -LiteralPath $staged)) { Good ' No staged media to delete.'; Write-Log 'Finish' 'NotNeeded' 'no staged media'; return 0 }
    $c = Confirm-Yes ('Delete staged media in ' + $staged + '. Result files and the log stay (NOT encrypted: use [A] once they are copied).')
    if ($c) { return $c }
    try { Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction Stop } catch { Bad (' Could not delete the staged media: ' + (Protect-Text $_.Exception.Message)); return 1 }
    Write-Log 'Finish' 'Success' 'staged media deleted'
    Good (' Staged media deleted. Results and log remain in ' + $Script:WorkRoot + '.')
    0
}
function Invoke-Step([string]$Id, [string]$Act) {
    switch ($Id) {
        'Snapshot'     { if ($Act -eq 'Guide') { Show-Advice 'Snapshot' (Get-PlaceholderMap '' '' ''); return (Show-Manual 'Snapshot' (Get-PlaceholderMap '' '' '') $null) }; return (Invoke-StepSnapshot 'snapshot') }
        'Precheck'     { return (Invoke-StepPrecheck $Act) }
        'WindowsPatch' { return (Invoke-StepWindowsPatch $Act) }
        'SqlPatch'     { return (Invoke-StepSqlPatch $Act) }
        'SqlUpgrade'   { return (Invoke-StepSqlUpgrade $Act) }
        'OsUpgrade'    { return (Invoke-StepOsUpgrade $Act) }
        'Disk'         { return (Invoke-StepDisk $Act) }
        'Postcheck'    { return (Invoke-StepPostcheck $Act) }
        'Finish'       { return (Invoke-StepFinish $Act) }
    }
    2
}
function Get-StepHint([string]$Id) {
    # A short "is this needed here" hint for the menu, from the snapshot
    $f = $Script:Facts; $pol = $Script:Policy
    switch ($Id) {
        'SqlPatch'   { if (@($f.Sql).Count -eq 0) { return 'no SQL here' }; $n = 0; foreach ($i in @($f.Sql)) { if ($i -and (Get-SqlVerdict $i $Script:Data).Verdict -eq 'PatchFirst') { $n++ } }; if ($n) { return "$n instance(s) below the level needed" }; return 'patch to the latest CU' }
        'SqlUpgrade' { if (@($f.Sql).Count -eq 0) { return 'no SQL here' }; $n = 0; foreach ($i in @($f.Sql)) { if ($i -and (Get-SqlVerdict $i $Script:Data).Verdict -eq 'UpgradeFirst') { $n++ } }; if ($n) { return "NEEDED: $n instance(s) not supported on the target" }; return 'not needed for the target OS' }
        'OsUpgrade'  { if ($pol.Scope -eq 'InScope') { return ('next hop ' + $pol.Entry['Next']) }; return $pol.Scope }
        'Disk'       { if ($null -ne $f.CFreeGB) { return ('C: ' + $f.CFreeGB + ' GB free') } }
        'Precheck'   { if (@($f.PendingReboot).Count) { return 'reboot pending' } }
    }
    ''
}
function Invoke-GuideMenu {
    $outcomes = @()
    $r = Invoke-StepSnapshot 'snapshot'
    $Script:FirstFacts = $Script:Facts
    $outcomes += $r
    $Script:StepState = @{}; $Script:StepState['Snapshot'] = $r
    $ids = @(); foreach ($e in @($Script:Data['Steps'])) { $ids += $e['Id'] }
    while ($true) {
        Write-Host ''
        Info ' Steps (each one shows its advice first; R runs it, G gives guidance only)'
        for ($n = 0; $n -lt $ids.Count; $n++) {
            $id = $ids[$n]; $st = '-'
            if ($Script:StepState.ContainsKey($id)) { $st = Get-CodeName $Script:StepState[$id] }
            $hint = Get-StepHint $id; if ($hint) { $hint = '  (' + $hint + ')' }
            Write-Host ('   {0}. {1,-13} {2,-10} {3}{4}' -f ($n + 1), $id, $st, (Get-StepDef $id)['Title'], $hint)
        }
        $a = Read-Answer ' Step number, or Q to quit'
        if ($null -eq $a -or "$a".Trim().ToUpper() -eq 'Q') { break }
        $k = 0
        if (-not ([int]::TryParse("$a", [ref]$k)) -or $k -lt 1 -or $k -gt $ids.Count) { Warn ' Type a step number from the list, or Q.'; continue }
        $id = $ids[$k - 1]
        $res = $null
        try { $res = @(Invoke-Step $id 'Menu')[-1] }
        catch { Bad (' ' + $id + ' failed: ' + (Protect-Text $_.Exception.Message)); Write-Log $id 'Error' $_.Exception.Message; $res = 1 }
        $Script:StepState[$id] = [int]$res
        $outcomes += [int]$res
        if ($id -eq 'Finish' -and -not (Test-Path -LiteralPath $Script:WorkRoot)) { break }
    }
    Get-SessionExitCode $outcomes @($Script:Problems).Count
}
function Get-CodeName([int]$c) {
    switch ($c) { 0 { 'done' } 1 { 'FAILED' } 2 { 'usage' } 3 { 'hours' } 5 { 'refused' } 6 { 'busy' } 7 { 'partial' } 8 { 'cancelled' } 9 { 'REBOOT' } 10 { 'admin' } default { "$c" } }
}

# ============================================================== main
function Show-Usage {
    Write-Host 'VmmFallback.ps1 - the last fallback on a host (see the header of this file for details).'
    Write-Host '  (no switch)              Guide menu in a console, otherwise -Snapshot'
    Write-Host '  -Snapshot                read-only snapshot, result file in the work folder'
    Write-Host '  -Check                   validate the companion file VmmFallback.psd1'
    Write-Host '  -Step <Id> [-Action Guide|Run|Stage] [-Instance <name>]'
    Write-Host ('                           Id: ' + ($Script:StepIds -join ', '))
    Write-Host '  -DataFile <psd1> -WorkDir <C:\Temp\...> -MediaDir <folder> -Order "<reason>" -NoColor'
    Write-Host 'Exit codes: 0 done, 1 error, 2 usage/companion, 3 time window, 5 refused, 6 busy, 7 partial snapshot,'
    Write-Host '            8 cancelled, 9 reboot needed, 10 needs administrator.'
}
function Invoke-Main {
    if ($Help) { Show-Usage; return 0 }
    $modes = 0; foreach ($m in @($Snapshot, $Guide, $Check, [bool]$Step)) { if ($m) { $modes++ } }
    if ($modes -gt 1) { Bad 'Use one of -Snapshot, -Guide, -Check or -Step.'; Show-Usage; return 2 }
    if ($Step -and $Script:StepIds -notcontains $Step) { Bad ("Unknown step '$Step'. Known: " + ($Script:StepIds -join ', ')); return 2 }
    if (@('Guide', 'Run', 'Stage') -notcontains $Action) { Bad ("Unknown -Action '$Action': use Guide, Run or Stage."); return 2 }
    if ($Instance -and -not $Step) { Bad '-Instance needs -Step SqlPatch or -Step SqlUpgrade.'; return 2 }
    if ($Order -and $Order.Trim().Length -lt 10) { Bad '-Order needs the reason for the order (at least 10 characters), it is logged.'; return 2 }

    $path = $DataFile; if (-not $path) { $path = Get-DefaultDataFile }
    try { $Script:Data = Read-Companion $path } catch { Bad (' Companion file: ' + $_.Exception.Message); return 2 }
    $issues = @(Test-Companion $Script:Data)
    if ($issues.Count) {
        Bad (' Companion file ' + $path + ' is invalid (' + $issues.Count + ' problem(s)):')
        foreach ($i in $issues) { Bad ('   ' + $i) }
        return 2
    }
    $Script:WorkRoot = "$($Script:Data['Settings']['WorkDir'])".TrimEnd('\')
    if ($WorkDir) {
        if (-not (Test-UnderTemp $WorkDir)) { Bad (" -WorkDir must be under C:\Temp (project rule): $WorkDir"); return 2 }
        $Script:WorkRoot = $WorkDir.TrimEnd('\')
    }
    $Script:MediaRoot = "$($Script:Data['Settings']['MediaDir'])".TrimEnd('\')
    if ($MediaDir) { $Script:MediaRoot = $MediaDir.TrimEnd('\') }
    if ($Check) {
        Good (' Companion file is valid: ' + $path)
        Mute (' {0} OS path entries, {1} SQL versions, {2} steps, work folder {3}' -f @($Script:Data['OsPath']).Count, @($Script:Data['SqlVersions']).Count, @($Script:Data['Steps']).Count, $Script:WorkRoot)
        return 0
    }
    if ($Step -and $Step -ne 'Snapshot' -and $Action -eq 'Run' -and -not (Test-Interactive)) { Bad ' -Action Run needs a console: a person must type YES.'; return 2 }

    $lk = Enter-Lock $Script:WorkRoot
    if ($lk -eq 6) { Bad (' Another copy of VmmFallback is running on this host (' + (Join-Path $Script:WorkRoot 'fallback.lock') + ').'); return 6 }
    if ($lk -ne 0) { return 1 }
    Write-Log 'Script' 'Start' ('version ' + $FallbackVersion + ', PowerShell ' + $PSVersionTable.PSVersion + $(if ($Order) { ', order: ' + $Order } else { '' }))
    Show-Header
    if ($Snapshot -or (-not $Guide -and -not $Step -and -not (Test-Interactive))) { return (Invoke-StepSnapshot 'snapshot') }
    if ($Step) {
        if ($Step -eq 'Snapshot' -and $Action -ne 'Guide') { return (Invoke-StepSnapshot 'snapshot') }
        # Every other step needs the facts: read them first (shown, saved as a snapshot)
        $r = Invoke-StepSnapshot 'snapshot'
        $Script:FirstFacts = $Script:Facts
        if ($r -eq 1) { return 1 }
        return [int](@(Invoke-Step $Step $Action)[-1])
    }
    Invoke-GuideMenu
}

# Run only when started as a script (the tests dot-source nothing: they parse the functions out of this file)
$Script:Exit = 1
$Script:Finished = $false
try {
    $Script:Exit = [int](@(Invoke-Main)[-1])
    $Script:Finished = $true
} catch {
    Bad (' Unexpected error: ' + (Protect-Text $_.Exception.Message))
    try { Bad (' At line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + (Protect-Text $_.InvocationInfo.Line.Trim())) } catch { }
    Write-Log 'Script' 'Error' $_.Exception.Message
    $Script:Exit = 1
    $Script:Finished = $true
} finally {
    if (-not $Script:Finished) { Write-Log 'Script' 'Interrupted' 'Ctrl+C or the window was closed' }
    elseif ($Script:WorkRoot -and $Script:Lock) { Write-Log 'Script' 'End' ('exit code ' + $Script:Exit) }
    Exit-Lock
}
Write-Host ''
Mute (' Exit code ' + $Script:Exit + ' (' + (Get-CodeName $Script:Exit) + ')')
if ($Script:Exit -ne 0) { Wait-BeforeClose }
exit $Script:Exit
