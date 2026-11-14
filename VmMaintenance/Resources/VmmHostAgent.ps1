<#
.SYNOPSIS
    VmMaintenance host agent - the small program you run ON a remote host inside RDP/RDM.
.DESCRIPTION
    Copy this file to the host's desktop, then in a PowerShell window on the host run:

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\VmmHostAgent.ps1"

    (-ExecutionPolicy Bypass applies to this one process only; nothing on the host is reconfigured.)

    What it does:
      - Extracts this host's facts (OS, build, SQL, C: space, pending reboot, staged files).
      - Shows every workflow step: done, current, future, and WHY a step is or is not available now
        (Lisbon business hours, admin rights, rollback snapshot, staged files, free space).
      - Runs the steps that can be done from inside the host (check, stage, extend C:, start the
        upgrade, verify), with the same time rules and override rules as the laptop console.
      - Keeps a sanitized log of what this program did here (no IPs, user names, share paths, secrets).
      - Exports an ENCRYPTED result line (VMM2|...) for the laptop. Only the laptop that built this
        agent can read it (RSA-OAEP + AES-256 + HMAC-SHA256).
      - "Finish" removes the work folder, this file and the clipboard content at the end of the cycle.

    Work folder: C:\Temp\VmmAgent (Administrators, SYSTEM and you only).
    Compatible with Windows PowerShell 2.0 to 5.1. Read-only unless you choose a change step.

    [SEC] Treat everything shown here as business data carried over the VPN: do not copy it anywhere
    other than the vmm console on your laptop.
.PARAMETER Extract
    No menu: collect facts, append to the log and print the encrypted result line.
.PARAMETER Finish
    No menu: remove the work folder and this file (end of the maintenance cycle).
.PARAMETER NoClipboard
    Do not put the result line on the clipboard.
.PARAMETER NoColor
    Plain output (for consoles that render colours badly).
.PARAMETER WorkDir
    Work folder (default C:\Temp\VmmAgent). Removed by Finish.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VmmHostAgent.ps1
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VmmHostAgent.ps1 -Extract
#>
param(
    [switch]$Extract,
    [switch]$Finish,
    [switch]$NoClipboard,
    [switch]$NoColor,
    [string]$WorkDir = 'C:\Temp\VmmAgent'
)

$AgentVersion = '2.1.0'
$CardText = ''   # VMM-CARD (filled in by Export-VmmHostAgent on the laptop; empty = generic agent)

$ErrorActionPreference = 'Stop'
$Script:SelfPath = $MyInvocation.MyCommand.Path
$Script:Inv = [Globalization.CultureInfo]::InvariantCulture

# ============================================================== output
function Say([string]$Text, [string]$Color) {
    if ($NoColor -or -not $Color) { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
}
function Info([string]$t) { Say $t 'Cyan' }
function Good([string]$t) { Say $t 'Green' }
function Warn([string]$t) { Say $t 'Yellow' }
function Bad([string]$t)  { Say $t 'Red' }
function Mute([string]$t) { Say $t 'DarkGray' }

# ============================================================== sanitizing
# [SEC] Everything written to the log or shown in an error passes through here.
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

# ============================================================== card (plan from the laptop)
function Read-Card {
    $c = @{
        Host = ''; Generated = ''; ValidHours = '48'; TimeZoneId = 'GMT Standard Time'
        BusinessDays = 'Monday,Tuesday,Wednesday,Thursday,Friday'; BusinessStart = '08:00'; BusinessEnd = '17:00'
        OffHoursWeekdays = 'True'; Holidays = ''; OkGB = '40'; CriticalGB = '32'; TargetFolder = 'C:\Temp'
        ExpectedOs = ''; UpgradeCommand = ''; Share = ''; PublicKey = ''; Platform = ''; AzureVm = 'No'
        Steps = @{}; Packages = @()
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
        elseif ($k -like 'Package.*') { $c.Packages += $v }
        else { $c[$k] = $v }
    }
    $c
}
$Card = Read-Card

# ============================================================== work folder and log
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
function Read-Events {
    $f = Join-Path $WorkDir 'agent.log'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $out = @()
    foreach ($l in (Get-Content -LiteralPath $f)) {
        $p = $l -split '\|', 4
        if ($p.Count -eq 4) { $out += New-Object PSObject -Property @{ At = $p[0]; Step = $p[1]; Status = $p[2]; Note = $p[3] } }
    }
    $out
}

# ============================================================== facts
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
            if ($f[2]) {
                try { if ((Get-FileSha256 $file) -eq $f[2].ToUpper()) { $state = 'Verified' } else { $state = 'HashMismatch' } }
                catch { $state = 'Unreadable' }
            }
        }
        $res += New-Object PSObject -Property @{ Name = $f[0]; File = $file; Sha256 = $f[2]; Rel = $f[3]; State = $state }
    }
    $res
}
function Get-Facts {
    $os = Get-WmiObject Win32_OperatingSystem
    $cs = Get-WmiObject Win32_ComputerSystem
    $c  = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
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
    $pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $plat = 'Physical'
    if ($cs.Manufacturer -like '*VMware*' -or $cs.Model -like '*VMware*') { $plat = 'VMware' }
    elseif ($cs.Model -like '*Virtual Machine*') {
        $plat = 'Hyper-V'
        if (Get-Service -Name WindowsAzureGuestAgent -ErrorAction SilentlyContinue) { $plat = 'Azure' }
    }
    $boot = $null
    try { $boot = $os.ConvertToDateTime($os.LastBootUpTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { }
    New-Object PSObject -Property @{
        Name = $env:COMPUTERNAME; OS = "$($os.Caption)".Trim(); Version = $os.Version; Build = $os.BuildNumber
        SP = $os.ServicePackMajorVersion; Manufacturer = $cs.Manufacturer; Model = $cs.Model; Platform = $plat
        CTotalGB = [math]::Round($c.Size / 1GB, 1); CFreeGB = [math]::Round($c.FreeSpace / 1GB, 1)
        PendingReboot = $pend; Sql = ($sql -join '; '); LastBoot = $boot; TempExists = (Test-Path $Card.TargetFolder)
        PSVersion = "$($PSVersionTable.PSVersion)"; Admin = (Test-Admin)
    }
}

# ============================================================== time rules (Europe/Lisbon by default)
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

# ============================================================== step plan
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
                if (-not $Card.Packages.Count) { $can = $false; $why = 'No packages in the plan. Define Staging.Packages on the laptop and export the agent again.' }
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
        if ($can -and $class -eq 'Change' -and -not $w.ChangesAllowed) { $can = $false; $why = $w.Why + ' (override possible)' }
        $plan += New-Object PSObject -Property @{ Step = $s; Class = $class; Status = (Get-LastStatus $s); Available = $can; Why = $why }
    }
    $plan
}

# ============================================================== confirmations
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

# ============================================================== steps
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
function Export-Result {
    $f = Get-Facts
    $lines = @(
        'Name=' + $f.Name, 'OS=' + $f.OS, 'Version=' + $f.Version, 'Build=' + $f.Build, 'SP=' + $f.SP,
        'Manufacturer=' + $f.Manufacturer, 'Model=' + $f.Model, 'Platform=' + $f.Platform,
        'CTotalGB=' + $f.CTotalGB.ToString($Script:Inv), 'CFreeGB=' + $f.CFreeGB.ToString($Script:Inv),
        'PendingReboot=' + $(if ($f.PendingReboot) { 'Yes' } else { 'No' }), 'Sql=' + $f.Sql, 'LastBoot=' + $f.LastBoot,
        'TempExists=' + $f.TempExists, 'AgentVersion=' + $AgentVersion, 'ExportedAt=' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    )
    foreach ($p in (Get-PackageState)) { $lines += ('Package=' + $p.Name + '|' + $p.State) }
    foreach ($e in (Read-Events)) { $lines += ('Event=' + $e.At + '|' + $e.Step + '|' + $e.Status + '|' + $e.Note) }
    $text = $lines -join "`n"
    if ($Card.PublicKey) {
        $out = Protect-Result $text
    } else {
        Warn 'This is a generic agent without the laptop key: the result cannot be encrypted.'
        Warn 'Export the agent for this host from the laptop (vmm agent -HostName <host>) instead.'
        Warn 'Type PLAIN to produce an unencrypted line anyway (it carries host facts only), anything else cancels.'
        if ((Read-Host ' >') -cne 'PLAIN') { Mute 'Cancelled.'; return }
        $out = 'VMM1|' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
    }
    Write-Event 'Export' 'Success' ('result line exported (' + $out.Substring(0, 4) + ')')
    if (-not $NoClipboard) {
        try { $out | & clip.exe; Good 'Result copied to the clipboard. On the laptop: vmm console > host > P, or: vmm collect' }
        catch { Warn 'Clipboard not available; copy the line below by hand.' }
    }
    Write-Host $out
}

# ============================================================== finish
function Invoke-Finish([switch]$Force) {
    if (-not $Force) {
        Warn "Removes $WorkDir (log, temp files), this agent file and the clipboard content."
        Warn 'Staged install files in the target folder are NOT touched. Type FINISH to continue.'
        if ((Read-Host ' >') -cne 'FINISH') { Mute 'Cancelled.'; return $false }
    }
    $ok = $true
    if (Test-Path -LiteralPath $WorkDir) {
        try { Remove-Item -LiteralPath $WorkDir -Recurse -Force; Good "Removed $WorkDir" }
        catch { $ok = $false; Bad ('Could not remove the work folder: ' + (Protect-Text $_.Exception.Message)) }
    }
    try { & cmd.exe /c 'echo off | clip' } catch { }
    if ($Script:SelfPath -and (Test-Path -LiteralPath $Script:SelfPath)) {
        try { Remove-Item -LiteralPath $Script:SelfPath -Force; Good 'Removed the agent file.' }
        catch { $ok = $false; Bad 'Could not remove the agent file; delete it from the desktop by hand.' }
    }
    if ($ok) { Good 'Host clean. Close this window and the RDP session.' }
    $ok
}

# ============================================================== screens
function Show-Header {
    Clear-Host
    $w = Get-Window
    Say (" VMM host agent $AgentVersion | $env:COMPUTERNAME | {0} {1}" -f $w.Now.ToString('ddd yyyy-MM-dd HH:mm'), $Card.TimeZoneId) 'White'
    if ($w.ChangesAllowed) { Good (' ' + $w.Why) } else { Warn (' ' + $w.Why) }
    if (-not (Test-Admin)) { Warn ' Not elevated: checks and staging only. For changes, run PowerShell as administrator.' }
    if (-not $CardText) { Warn ' Generic agent (no plan from the laptop): statuses are local only, export is unencrypted.' }
    elseif ($Card.Host -and $Card.Host -ne $env:COMPUTERNAME) { Bad " PLAN IS FOR $($Card.Host), NOT THIS HOST. Do not run change steps here." }
    elseif ($Card.Generated) {
        try {
            $age = ([DateTime]::UtcNow - [DateTime]::Parse($Card.Generated, $Script:Inv).ToUniversalTime()).TotalHours
            if ($age -gt [double]$Card.ValidHours) { Warn (" Plan is {0:N0} h old: export a fresh agent from the laptop." -f $age) }
        } catch { }
    }
    Mute ' ---------------------------------------------------------------------------------------'
}
function Show-Facts($f) {
    Info ' This host'
    Write-Host ("  OS            {0} (build {1}, SP {2})" -f $f.OS, $f.Build, $f.SP)
    Write-Host ("  Platform      {0} ({1} / {2})" -f $f.Platform, $f.Manufacturer, $f.Model)
    $col = 'Green'; if ($f.CFreeGB -lt [double]::Parse($Card.OkGB, $Script:Inv)) { $col = 'Yellow' }; if ($f.CFreeGB -lt [double]::Parse($Card.CriticalGB, $Script:Inv)) { $col = 'Red' }
    Say ("  C:            {0} GB free of {1} GB" -f $f.CFreeGB, $f.CTotalGB) $col
    if ($f.PendingReboot) { Warn '  Reboot        PENDING' } else { Write-Host '  Reboot        not pending' }
    Write-Host ("  SQL           {0}" -f $(if ($f.Sql) { $f.Sql } else { 'none' }))
    Write-Host ("  Last boot     {0} UTC   PowerShell {1}   Admin {2}" -f $f.LastBoot, $f.PSVersion, $f.Admin)
    $pk = @(Get-PackageState)
    if ($pk.Count) { Info ' Staged files'; foreach ($p in $pk) { $c = 'Red'; if ($p.State -eq 'Verified' -or $p.State -eq 'Present') { $c = 'Green' }; Say ("  {0,-24} {1}" -f $p.Name, $p.State) $c } }
}
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
        $c = 'Gray'; if ($e.Status -match 'Success|NotNeeded') { $c = 'Green' } elseif ($e.Status -match 'Failed') { $c = 'Red' } elseif ($e.Status -match 'Override') { $c = 'Yellow' }
        Say (' {0,-21} {1,-12} {2,-10} {3}' -f $e.At, $e.Step, $e.Status, $e.Note) $c
    }
    if ($Card.Steps.Count) {
        Info ' From the laptop (at export time)'
        foreach ($s in $StepNames) { if ($Card.Steps.ContainsKey($s)) { $p = $Card.Steps[$s] -split '\|', 3; Write-Host (' {0,-21} {1,-12} {2,-10} {3}' -f $p[1], $s, $p[0], $p[2]) } }
    }
}
function Pause-Agent { Write-Host ''; Read-Host ' Enter to continue' | Out-Null }

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

# ============================================================== main
try {
    if ($Finish) { [void](Invoke-Finish -Force); return }
    if ($Extract) { Invoke-Check 'Precheck'; Export-Result; return }

    while ($true) {
        Show-Header
        Write-Host ' 1 Status    live facts for this host'
        Write-Host ' 2 Steps     current and future steps, and why each is or is not available'
        Write-Host ' 3 Run       run a step from here'
        Write-Host ' 4 History   what this program did on this host'
        Write-Host ' 5 Export    encrypted result line for the laptop (clipboard)'
        Write-Host ' 6 Finish    end of maintenance: remove agent files from this host'
        Write-Host ' Q Quit      keep files for the next session'
        $k = Read-Host ' Choice'
        Show-Header
        try {
            switch -Regex ($k) {
                '^1$' { Show-Facts (Get-Facts); Pause-Agent }
                '^2$' { [void](Show-Plan); Pause-Agent }
                '^3$' { Invoke-RunMenu; Pause-Agent }
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
} catch {
    Bad (' ERROR: ' + (Protect-Text $_.Exception.Message))
    exit 1
}
