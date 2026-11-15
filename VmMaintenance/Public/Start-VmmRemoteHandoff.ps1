function Start-VmmRemoteHandoff {
    <#
    .SYNOPSIS
        Hands-on fallback for staging: when vmm cannot copy the files to a host from the terminal, it opens
        RDP, RDM or RDCMan for you, tells you exactly what to copy where (C:\Temp), then checks the files
        are really there (size and SHA256) before the work goes on.
    .DESCRIPTION
        1. The file list is the same as the terminal copy (Copy-VmmStagingPackage) and the staging gate
           applies: a file missing or wrong on the share stops here.
        2. Optional outbox (Handoff.Outbox = Ask | Always | Never): for hosts that cannot open the share, the
           files are first copied to a folder on this laptop, whose drive is shared with the RDP session, so
           the host takes them from \\tsclient\<drive>\...
        3. A short host script goes on the clipboard (also kept in the handoff folder until the end). Pasted in
           PowerShell on the host it writes only in Staging.TargetFolder: creates it, copies what is missing
           from the first source the host can open, reads size and SHA256 on the host and puts a one-line
           VMMSTAGE1 report on the clipboard. Nothing is installed or run.
        4. You pick the client (or Handoff.Client), vmm starts it. You sign in: vmm keeps no password.
        5. Back in vmm, V verifies: the pasted report first, then WinRM, the admin share and WMI (see
           Get-VmmHandoffEvidence). Only a verified result marks the Stage step done (when Precheck is done).
        Everything is written to the day log. Client OS hosts are refused without an order, like every step.
        Staging is allowed in business hours, but only into C:\Temp (Staging.TargetFolder elsewhere waits).
        -VerifyOnly (or -Report "VMMSTAGE1|...") skips the session and only checks, so it also runs unattended.
    .EXAMPLE
        Start-VmmRemoteHandoff -HostName srv01
    .EXAMPLE
        Start-VmmRemoteHandoff -HostName srv01 -Client Rdm -Outbox Always
    .EXAMPLE
        Start-VmmRemoteHandoff -HostName srv01 -VerifyOnly
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateSet('Default', 'Ask', 'Rdp', 'Rdm', 'RdcMan', 'None')][string]$Client = 'Default',
        [ValidateSet('Ask', 'Always', 'Never')][string]$Outbox,
        [string]$Reason,
        [switch]$VerifyOnly,
        [string]$Report,
        [switch]$NoMarkStep
    )
    $store = Read-VmmStore
    $rec = Get-VmmHostRecord -Store $store -Name $HostName
    $name = $rec.Name
    $addr = if ($rec.PSObject.Properties['Fqdn'] -and $rec.Fqdn) { $rec.Fqdn } else { $rec.Name }

    $pol = Get-VmmHostPolicy -Record $rec
    if (-not $pol.Workable) {
        throw (New-VmmErrorRecord -Activity "Policy: no staging on $name." -Target "$name ($($pol.Os))" -Cause $pol.Why `
            -Fix $(if ($pol.Scope -eq 'ClientOs') { "Only with orders: vmm order -HostName $name -Reason '<ticket / who approved>'" } else { 'Nothing to do; put the host on hold (H) or remove it.' }) `
            -Category PermissionDenied -ErrorId 'VmmPolicy')
    }
    $target = Get-VmmSetting 'Staging.TargetFolder' -Default 'C:\Temp'
    if ($target -notmatch '^[A-Za-z]:\\') { throw (New-VmmErrorRecord -Activity "Staging.TargetFolder '$target' is not a local path like C:\Temp." -Category InvalidArgument) }
    $w = Get-VmmTimeWindow
    if (-not $w.ChangesAllowed -and $target.TrimEnd('\') -notlike 'C:\Temp*') {
        throw (New-VmmErrorRecord -Activity "Blocked: staging into '$target' during business hours." -Target "$($w.ZoneTime.ToString('ddd HH:mm')) $($w.ZoneLabel)" `
            -Cause 'In business hours only checks and staging into C:\Temp are allowed.' `
            -Fix "Set Staging.TargetFolder to C:\Temp, or wait until $($w.NextChangeAt.ToString('ddd HH:mm'))." -Category PermissionDenied -ErrorId 'VmmWindowBlocked')
    }

    $items = @(Get-VmmHandoffItem -Record $rec)
    $res = [pscustomobject]@{ HostName = $name; Client = ''; Verified = $false; VerifiedBy = ''; Target = $target
                              Files = @($items | ForEach-Object { $_.DestName }); Rows = @() }
    if (-not $items.Count) { Write-VmmLog "[$name] nothing to stage." -Level Success; $res.Verified = $true; $res.VerifiedBy = 'nothing to stage'; return $res }

    $finish = {
        param($Ev, $ClientName)
        if ($Ev) {
            $res.Rows = @($Ev.Rows)
            $Ev.Rows | Format-Table File, Status, ExpectedBytes, HostBytes, Method -AutoSize | Out-VmmHost
            foreach ($r in $Ev.Rows) {
                $lvl = if ($r.Status -eq 'OK') { 'Success' } elseif ($r.Status -eq 'NotHashed') { 'Warn' } else { 'Error' }
                Write-VmmLog "[$name] $target\$($r.File): $($r.Status) (host $($r.HostBytes) bytes$(if ($r.HostSha256) { ", SHA256 $($r.HostSha256)" }); via $($r.Method))" -Level $lvl -FileOnly
            }
        }
        if (-not $Ev -or -not $Ev.Verified) {
            $why = if (-not $Ev) { 'vmm could not read the host and no VMMSTAGE1 report is on the clipboard' }
                   else { (@($Ev.Rows | Where-Object Status -ne 'OK' | ForEach-Object { "$($_.File) $($_.Status)" }) -join ', ') }
            Write-VmmLog "[$name] not verified yet: $why" -Level Warn
            if (@($Ev.Rows | Where-Object Status -eq 'NotHashed').Count) { Write-VmmLog 'Size is right but the SHA256 could not be read that way: run the host script and paste its report (P).' -Level Info }
            return $false
        }
        $res.Verified = $true; $res.VerifiedBy = $Ev.Method
        Write-VmmLog "[$name] $($items.Count) file(s) verified in $target by $($Ev.Method)." -Level Success
        if ($NoMarkStep) { return $true }
        $st = Read-VmmStore; $r2 = Get-VmmHostRecord -Store $st -Name $name
        $pre = $r2.Steps.PSObject.Properties['Precheck']
        if ($pre -and $pre.Value.Status -in 'Success', 'NotNeeded', 'Skipped') {
            Set-VmmStepState -Record $r2 -Step 'Stage' -Status 'Success' -Note "Staged by hand ($ClientName), verified by $($Ev.Method): $($res.Files -join ', ')" | Out-Null
            Save-VmmStore -Store $st | Out-Null
            Write-VmmLog "[$name] Stage = Success (hands-on, verified)." -Level Success
        } else { Write-VmmLog "[$name] Stage not recorded: Precheck is not done. Run Precheck, then: vmm handoff -HostName $name -VerifyOnly" -Level Warn }
        $true
    }

    if ($VerifyOnly -or $Report) {
        Write-VmmLog "[$name] verifying staged files in $target (read-only)" -Level Info
        $ev = Get-VmmHandoffEvidence -Record $rec -Items $items -Target $target -Pasted $Report
        [void](& $finish $ev 'checked later')
        return $res
    }
    if (-not (Test-VmmInteractive)) {
        throw (New-VmmErrorRecord -Activity "The RDP/RDM handoff for $name needs you at the keyboard." -Category InvalidOperation -ErrorId 'VmmHandoffInteractive' `
            -Fix "Run it in a console (vmm handoff -HostName $name), or check files copied by hand with -VerifyOnly / -Report 'VMMSTAGE1|...'.")
    }

    Write-VmmLog "[$name] Hands-on staging over remote desktop$(if ($Reason) { ": the terminal copy failed ($Reason)" })." -Level Warn
    Assert-VmmVpn -Activity 'RDP handoff'

    # Outbox: only needed when the host cannot open the share; the files then come from this laptop over \\tsclient
    $drives = @()
    $share = "$(Get-VmmSetting 'Staging.SourceShare' -Default '')"
    if ($share -match '^([A-Za-z]):\\') { $drives += $Matches[1] }   # share given as a local drive: share that drive
    $mode = if ($Outbox) { $Outbox } else { "$(Get-VmmSetting 'Handoff.Outbox' -Default 'Ask')" }
    $needBytes = [long](($items | Measure-Object -Property Size -Sum).Sum)
    $useOutbox = $false
    if (-not $drives.Count -and $mode -ne 'Never') {
        if ($mode -eq 'Always') { $useOutbox = $true }
        else {
            $a = Read-VmmPrompt ("If the host cannot open the share, it can take the files from this laptop over RDP. Copy {0} file(s) ({1:N1} GB) to the local outbox first? (y/N)" -f $items.Count, ($needBytes / 1GB))
            $useOutbox = "$a" -match '^[yY]'
        }
    }
    if ($useOutbox) {
        $ob = Get-VmmPath -Name Outbox
        $free = try { (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($ob))).AvailableFreeSpace } catch { [long]::MaxValue }
        if ($free -lt $needBytes + 1GB) {
            Write-VmmLog ("[$name] outbox skipped: {0:N1} GB free on {1}, {2:N1} GB needed. The host must open the share." -f ($free / 1GB), $ob, ($needBytes / 1GB)) -Level Warn
        } else {
            foreach ($i in $items) {
                $dest = Join-Path $ob $i.DestName
                if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -eq $i.Size) { Write-VmmLog "outbox: $($i.DestName) already there" -Level Muted; continue }
                Write-VmmLog "outbox: copying $($i.DestName) ($($i.SizeMB) MB)..." -Level Info
                Copy-VmmFileWithProgress -Source $i.Source -Destination $dest -Label "outbox: $($i.DestName)" | Out-Null
                if ($i.Sha256 -and (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $i.Sha256) {
                    Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
                    throw (New-VmmErrorRecord -Activity "Outbox copy of $($i.DestName) is corrupt (SHA256 mismatch)." -Fix 'Run the handoff again.' -Category InvalidData -ErrorId 'VmmHashMismatch')
                }
            }
            $items = @(Get-VmmHandoffItem -Record $rec -WithOutbox)
            if ($ob -match '^([A-Za-z]):\\') { $drives += $Matches[1] }
        }
    }
    $drives = @($drives | Select-Object -Unique)

    $hostScript = Get-VmmHandoffScript -HostName $name -Target $target -Items $items
    $scriptFile = Join-Path (Get-VmmPath -Name Handoff) ('vmm_stage_{0}.ps1' -f [guid]::NewGuid().ToString('N').Substring(0, 12))
    [IO.File]::WriteAllText($scriptFile, $hostScript, [Text.Encoding]::ASCII)
    $toClip = { try { $hostScript | Set-Clipboard -ErrorAction Stop; Write-VmmLog 'Host script copied to the clipboard.' -Level Muted } catch { Write-VmmLog "Clipboard failed ($($_.Exception.Message)): open $scriptFile and copy it by hand." -Level Warn } }
    & $toClip

    $c = Select-VmmRemoteClient -Client $Client -For $name
    $state = @{ Launched = $null }
    $res.Client = if ($c) { $c.Name } else { 'None' }
    $open = { if ($c) { try { $state.Launched = Start-VmmRemoteClient -Client $c -Address $addr -DisplayName $name -Drive $drives } catch { Write-VmmLog $_.Exception.Message -Level Error } } else { Write-VmmLog "Open your remote session to $addr now." -Level Info } }
    & $open

    $passed = { param($o) (@($o) | Select-Object -Last 1) -eq $true }   # the verdict is the last thing $finish returns
    $steps = {
        Write-VmmLog ("Hands-on staging for {0}: {1} file(s), {2:N0} MB, into {3}" -f $name, $items.Count, ($needBytes / 1MB), $target) -Level Info
        Write-VmmLog "  1. $(if ($c) { $c.Label } else { 'Your remote session' }) to ${addr}: sign in with your admin account (vmm keeps no password)."
        Write-VmmLog '  2. On the host open Windows PowerShell (right-click > Run as administrator).'
        Write-VmmLog "  3. Paste the script that is on your clipboard (Ctrl+V or right-click). It writes only in ${target}: copies each file, checks size and SHA256 on the host, and puts a VMMSTAGE1 report on the clipboard."
        Write-VmmLog "     By hand instead (Explorer, RDM file transfer), put these files in ${target}:"
        foreach ($i in $items) {
            Write-VmmLog ("       {0}  {1:N1} MB{2}" -f $i.DestName, $i.SizeMB, $(if ($i.Sha256) { "  SHA256 $($i.Sha256)" }))
            Write-VmmLog ("         from: {0}" -f (@($i.Sources) -join '  or  ')) -Level Muted
        }
        Write-VmmLog '  4. Back here press V: vmm reads the report from the clipboard, or checks the host itself (WinRM, admin share, WMI).'
    }
    & $steps
    try {
        while ($true) {
            $a = "$(Read-VmmPrompt 'V verify | P paste report | C copy script again | O open session again | S steps | Q stop')".Trim().ToUpper()
            switch ($a) {
                'V' { $ev = Get-VmmHandoffEvidence -Record $rec -Items $items -Target $target; if (& $passed (& $finish $ev $res.Client)) { return $res } }
                'P' {
                    $line = Read-VmmPrompt 'Paste the VMMSTAGE1|... line from the host'
                    $ev = Get-VmmHandoffEvidence -Record $rec -Items $items -Target $target -Pasted $line -NoNetwork
                    if (& $passed (& $finish $ev $res.Client)) { return $res }
                }
                'C' { & $toClip }
                'O' { & $open }
                'S' { & $steps }
                'Q' { Write-VmmLog "[$name] hands-on staging stopped: nothing recorded. Verify later with: vmm handoff -HostName $name -VerifyOnly" -Level Warn; return $res }
                default { Write-VmmLog 'Type V, P, C, O, S or Q.' -Level Muted }
            }
        }
    } finally {
        Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
        if ($state.Launched -and $state.Launched.File) { Remove-Item -LiteralPath $state.Launched.File -Force -ErrorAction SilentlyContinue }
    }
}
