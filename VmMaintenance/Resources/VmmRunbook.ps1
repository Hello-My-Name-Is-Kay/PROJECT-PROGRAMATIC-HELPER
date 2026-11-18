# VmmRunbook - guided workflow for ONE host, run inside RDP/RDM. Built by vmm (Export-VmmWorkflowRunbook).
# Template: vmm replaces the data block between VMM-RUNBOOK-DATA-BEGIN/END with the host's steps and known fixes.
# Use: copy the .ps1 (and the .cmd next to it) to the host desktop, double-click the .cmd (or right-click the
# .ps1 > Run with PowerShell). Windows PowerShell 2.0 or later; nothing to install.
# What it does: shows each step, its instructions and commands; read-only steps marked "may run here" can run
# their commands when you type R; a step that is not read-only shows its commands only after the gate (time
# window, rollback point SNAPSHOT TAKEN / BACKUP CONFIRMED, YES). When a step fails it shows the known fixes and
# lets you record what happened and how you fixed it.
# What it writes: ONE text file on the desktop, VMMW_<HOST>_<time>.txt (also on the clipboard), that you copy
# back to the laptop: vmm imports it (I on the ticket). Nothing else is written or changed by this script.
$ErrorActionPreference = 'Continue'
# VMM-RUNBOOK-DATA-BEGIN
$Rb = @{ Host = 'TEMPLATE'; Workflow = 'template'; Generated = ''; Version = ''; Zone = 'GMT Standard Time'; BizStart = '08:00'; BizEnd = '17:00'
         OffHoursWeekdays = $true; Days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'); Holidays = @(); Azure = $false; Platform = ''; Warnings = @(); ClientOs = $false; NoChange = '' }
$Steps = @()
$Kb = @()
# VMM-RUNBOOK-DATA-END

$Out = New-Object System.Collections.ArrayList
function Say([string]$t, [string]$c) { if ($c) { Write-Host $t -ForegroundColor $c } else { Write-Host $t } }
function Ask([string]$p) { try { return [string](Read-Host $p) } catch { return $null } }
function B64([string]$s) { if (-not $s) { return '' }; [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function Add-Out([string]$l) { [void]$Out.Add($l) }
function Get-Window {
    # Business hours in the configured zone (business days, BizStart-BizEnd, holidays excluded): changes are not allowed then.
    $now = [DateTime]::UtcNow
    try { $z = [TimeZoneInfo]::FindSystemTimeZoneById($Rb.Zone); $t = [TimeZoneInfo]::ConvertTimeFromUtc($now, $z) }
    catch { return @{ Ok = $false; Why = 'The host cannot convert to Lisbon time: treated as business hours.'; Time = $now } }
    $d = $t.ToString('yyyy-MM-dd')
    $isHoliday = $false; foreach ($h in $Rb.Holidays) { if ($h -eq $d) { $isHoliday = $true } }
    $weekend = $true; foreach ($bd in $Rb.Days) { if (('' + $t.DayOfWeek) -eq $bd) { $weekend = $false } }
    $hm = $t.ToString('HH:mm')
    $inBiz = ($hm -ge $Rb.BizStart) -and ($hm -lt $Rb.BizEnd)
    if ($weekend -or $isHoliday) { return @{ Ok = $true; Why = 'Weekend or holiday.'; Time = $t } }
    if ($inBiz) { return @{ Ok = $false; Why = ('Business hours (' + $hm + ' Lisbon, Mon-Fri ' + $Rb.BizStart + '-' + $Rb.BizEnd + '): only checks and staging into C:\Temp.'); Time = $t } }
    if ($Rb.OffHoursWeekdays) { return @{ Ok = $true; Why = 'Weekday off-hours.'; Time = $t } }
    @{ Ok = $false; Why = 'Weekday off-hours are not allowed for changes (Schedule settings).'; Time = $t }
}
function Confirm-Gate($s) {
    # 0 = passed, 1 = cancelled. Records what was confirmed.
    if ($s.Category -eq 'Staging') {
        Say ' This step writes files on the host. In business hours ONLY into C:\Temp.' Yellow
        if ((Ask ' Continue? (y/N)') -notmatch '^[yY]') { return 1 }
        Add-Out ('G|' + $s.Key + '|' + (B64 'staging confirmed (C:\Temp only)')); return 0
    }
    if ($Rb.NoChange) { Say (' POLICY: ' + $Rb.NoChange) Red; return 1 }
    $w = Get-Window
    $notes = @()
    if (-not $w.Ok) {
        Say (' IMPORTANT: ' + $w.Why) Red
        Say ' Override only with your manager''s agreement: it is recorded and reported.' Yellow
        if ((Ask ' Type OVERRIDE to continue, anything else cancels') -cne 'OVERRIDE') { return 1 }
        $why = Ask ' Reason (who approved, why; min 10 chars)'
        if (-not $why -or $why.Trim().Length -lt 10) { Say ' Cancelled: the reason needs at least 10 characters.' Red; return 1 }
        Add-Out ('O|' + $s.Key + '|' + (B64 $why)); $notes += 'OVERRIDE (business hours)'
    }
    if ($Rb.Warnings.Count) {
        Say (' Management warnings: ' + ($Rb.Warnings -join ' ')) Yellow
        if ((Ask ' Type MANAGEMENT INFORMED to confirm') -cne 'MANAGEMENT INFORMED') { return 1 }
        $notes += 'management informed'
    }
    if ($Rb.Azure) { $ph = 'SNAPSHOT TAKEN'; Say ' Azure VM: a snapshot of every disk (OS and SQL data) must exist before this change.' Yellow }
    else { $ph = 'BACKUP CONFIRMED'; Say (' Platform ' + $Rb.Platform + ': a full backup or platform snapshot of this host must exist before this change.') Yellow }
    if ((Ask (' Type ' + $ph + ' to confirm the rollback point')) -cne $ph) { return 1 }
    $notes += ('rollback point confirmed (' + $ph + ')')
    if ((Ask ' Type YES to do this step now') -cne 'YES') { return 1 }
    Add-Out ('G|' + $s.Key + '|' + (B64 (($notes + 'YES') -join ', ')))
    0
}
function Show-Fixes($s, [string]$err) {
    # Known fixes for this step (and for any step), best first. Returns 1 when one fixed it.
    $words = @(); foreach ($m in [regex]::Matches($err.ToLower(), '[a-z0-9]{3,}')) { $words += $m.Value }
    $list = @()
    foreach ($k in $Kb) {
        if ($k.Action -ne $s.Id -and $k.Action -ne '*') { continue }
        $n = 0; $kw = ($k.Symptom + ' ' + $k.Cause).ToLower()
        foreach ($w in $words) { if ($kw.Contains($w)) { $n++ } }
        if ($k.Action -eq '*' -and -not $n) { continue }
        $score = 2 * $n + [int]$k.Helped; if ($k.Action -eq $s.Id) { $score += 3 }
        $list += New-Object PSObject -Property @{ K = $k; Score = $score }
    }
    $list = @($list | Sort-Object Score -Descending)
    if (-not $list.Count) { Say ' No known fix for this step yet.' DarkGray; return 0 }
    $i = 0
    foreach ($e in $list) {
        $i++
        Say ''; Say (' Suggested resolution ' + $i + ' of ' + $list.Count + ': ' + $e.K.Symptom) Cyan
        if ($e.K.Cause) { Say ('   Why: ' + $e.K.Cause) }
        $n = 0; foreach ($f in $e.K.Fix) { $n++; Say ('   ' + $n + '. ' + $f) }
        foreach ($c in $e.K.Commands) { Say ('   >> ' + $c) DarkGray }
        $a = Ask ' Did this fix it? Y = yes, N = try the next one, Enter = stop'
        if ($a -match '^[yY]') { Add-Out ('H|' + $e.K.Id + '|1'); return 1 }
        if ($a -match '^[nN]') { Add-Out ('H|' + $e.K.Id + '|0'); continue }
        return 0
    }
    0
}
function Save-Result {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
    $desk = [Environment]::GetFolderPath('Desktop'); if (-not $desk) { $desk = $env:TEMP }
    $file = Join-Path $desk ('VMMW_' + $Rb.Host + '_' + $stamp + '.txt')
    $text = (@('VMMW1|' + $Rb.Host + '|' + (B64 $Rb.Workflow) + '|' + $Rb.Generated + '|' + [DateTime]::UtcNow.ToString('o')) + @($Out)) -join "`r`n"
    try { [IO.File]::WriteAllText($file, $text); Say (' Result saved: ' + $file) Green } catch { Say (' Could not write ' + $file + ': ' + $_.Exception.Message) Red }
    try { $text | clip.exe; Say ' It is on the clipboard too: on the laptop press I on the ticket (vmm reads the clipboard).' Green } catch { Say ' Copy the file to the laptop Desktop, then press I on the ticket.' Yellow }
}

Say ''; Say (' vmm runbook - ' + $Rb.Host + ' - workflow: ' + $Rb.Workflow) Cyan
Say (' Built ' + $Rb.Generated + ' by vmm ' + $Rb.Version + '. ' + $Steps.Count + ' step(s). Nothing is changed unless you say so.') DarkGray
if ($Rb.Host -ne 'TEMPLATE' -and $env:COMPUTERNAME -and $env:COMPUTERNAME.ToUpper() -ne $Rb.Host.ToUpper()) {
    Say (' WARNING: this runbook is for ' + $Rb.Host + ' but this computer is ' + $env:COMPUTERNAME + '.') Red
    if ((Ask ' Type the host name to continue anyway') -ne $Rb.Host) { Say ' Stopped.'; exit 9 }
}
if ($Rb.ClientOs) { Say ' POLICY: this is a client OS without orders. Nothing to do here.' Red; exit 5 }
$idx = 0
foreach ($s in $Steps) {
    $idx++
    if ($s.Status -eq 'Success' -or $s.Status -eq 'NotNeeded' -or $s.Status -eq 'Skipped') { Say (' ' + $idx + '. ' + $s.Name + ': already ' + $s.Status) DarkGray; continue }
    while ($true) {
        Say ''; Say (' == Step ' + $idx + ' of ' + $Steps.Count + ': ' + $s.Name + ' [' + $s.Category + '] ==') Cyan
        Say (' ' + $s.Title)
        if ($s.Builtin) { Say ' This is a vmm maintenance step: run it from vmm on the laptop (the ticket screen). Here: S to move on.' Yellow }
        $n = 0; foreach ($l in $s.Lines) { $n++; Say ('  ' + $n + '. ' + $l) }
        $gated = ($s.Category -eq 'ReadOnly')
        if (-not $gated) { Say ' This step is not read-only: G shows its commands after the gate.' Yellow }
        else { foreach ($c in $s.Commands) { Say ('  >> ' + $c) DarkGray } }
        if ($s.Expect) { Say (' Success looks like: ' + $s.Expect) DarkGray }
        $keys = 'D done, F failed, S skip, Q stop and save'
        if ($s.RunOnHost -and $s.Commands.Count -and $s.Category -eq 'ReadOnly') { $keys = 'R run it here (read-only), ' + $keys }
        if (-not $gated) { $keys = 'G gate + commands, ' + $keys }
        $a = Ask (' ' + $keys)
        if ($null -eq $a) { Say ' No console: run it in a PowerShell window.' Red; Save-Result; exit 2 }
        $a = $a.Trim().ToUpper()
        if ($a -eq 'Q') { Save-Result; exit 0 }
        if ($a -eq 'R' -and $s.RunOnHost -and $s.Category -eq 'ReadOnly') {
            foreach ($c in $s.Commands) {
                Say ('  >> ' + $c) DarkGray
                try { Invoke-Expression $c | Out-String -Width 160 | Write-Host } catch { Say ('  ERROR: ' + $_.Exception.Message) Red }
            }
            continue
        }
        if ($a -eq 'G' -and -not $gated) {
            if ((Confirm-Gate $s) -ne 0) { Say ' Cancelled: nothing to do for this step now.' DarkGray; continue }
            foreach ($c in $s.Commands) { Say ('  >> ' + $c) DarkGray }
            if ($s.Commands.Count) { try { ($s.Commands -join "`r`n") | clip.exe; Say ' Commands are on the clipboard.' DarkGray } catch { } }
            $s.Gated = $true
            continue
        }
        if ($a -eq 'D') {
            if (-not $gated -and -not $s.Gated -and -not $s.Builtin) { Say ' Press G first: a step that is not read-only needs the gate.' Yellow; continue }
            $seen = Ask ' What did you see? (short result, Enter = as expected)'
            if (-not $seen) { $seen = 'as expected' }
            Add-Out ('S|' + $s.Key + '|Success|' + [DateTime]::UtcNow.ToString('o') + '|' + (B64 $seen)); break
        }
        if ($a -eq 'S') {
            $why = Ask ' Why is it skipped? (min 10 chars)'
            if (-not $why -or $why.Trim().Length -lt 10) { Say ' Not skipped: give a reason of 10+ characters.' Yellow; continue }
            Add-Out ('S|' + $s.Key + '|Skipped|' + [DateTime]::UtcNow.ToString('o') + '|' + (B64 ('SKIPPED: ' + $why))); break
        }
        if ($a -eq 'F') {
            $err = Ask ' What happened? (paste the exact error)'
            if (-not $err) { $err = 'failed (no text)' }
            Add-Out ('S|' + $s.Key + '|Failed|' + [DateTime]::UtcNow.ToString('o') + '|' + (B64 $err))
            if ((Show-Fixes $s $err) -eq 1) { Say ' Fixed: do the step again.' Green; continue }
            Say ' If you fixed it yourself, write how: the next technician gets it as a suggested resolution.' Cyan
            $fx = @(); while ($true) { $l = Ask ('  fix step ' + ($fx.Count + 1) + ' (Enter ends)'); if (-not $l) { break }; $fx += $l }
            if ($fx.Count) {
                $cause = Ask '  Why it happened (if known)'
                Add-Out ('K|' + $s.Id + '|' + (B64 $err) + '|' + (B64 $cause) + '|' + (B64 ($fx -join "`n")))
                if ((Ask ' Fixed now? Do the step again? (y/N)') -match '^[yY]') { continue }
            }
            Say ' Step left Failed. On the laptop: T on the step writes a ticket for the IT person who can fix it.' Yellow
            break
        }
    }
}
Say ''; Say ' All steps visited.' Green
Save-Result
