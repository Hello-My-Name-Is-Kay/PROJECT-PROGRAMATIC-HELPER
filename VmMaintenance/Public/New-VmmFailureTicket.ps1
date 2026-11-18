function New-VmmFailureTicket {
    <#
    .SYNOPSIS
        Turns a failure (Azure permission, VPN, RDP, share, SQL, host access...) into advice for you and a
        ready-to-send ticket text for the IT person who can fix it. The tool never sends it: you paste it into
        the ticket system or an e-mail.
    .DESCRIPTION
        Writes Reports\Tickets\<time>_<kind>.txt and copies the ticket text to the clipboard. The text reads like
        a real ticket: subject, summary, what was attempted, exact error, likely cause, requested action (for
        Azure: the role and its scope), impact, urgency, steps already tried (known fixes), environment.
        Sanitized by default: host names, FQDNs, IPs, ids and secrets become <HOST>, <IP>, <ID>, *** (fill the
        target in when you send it). -IncludeTarget writes the real host and resource group instead (the file
        then stays on your laptop like the blocker reports).
        -FromErrorLog uses the last line of the sanitized error log (logs\errors.log).
        Also prints what you should do now: the fix hint, the known fixes for this step, and to move on.
    .EXAMPLE
        New-VmmFailureTicket -Message 'AuthorizationFailed: ... Microsoft.Compute/snapshots/write ...' -Activity 'Snapshot point 1' -HostName srv01
    .EXAMPLE
        New-VmmFailureTicket -FromErrorLog
    #>
    [CmdletBinding()]
    param(
        [string]$Message,
        [string]$Activity = '',
        [string]$HostName,
        [string]$Step,
        [string]$ErrorId = '',
        [ValidateSet('Normal', 'High', 'Low')][string]$Urgency,
        [switch]$FromErrorLog,
        [switch]$IncludeTarget,
        [switch]$NoClipboard
    )
    if ($FromErrorLog) {
        $f = Join-Path (Get-VmmPath -Name Logs) 'errors.log'
        $last = if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Tail 1 } else { $null }
        if (-not $last) { throw (New-VmmErrorRecord -Activity 'The error log is empty.' -Target $f -Fix 'Give the error with -Message.' -Category ObjectNotFound -ErrorId 'VmmErrorLogEmpty') }
        $parts = $last -split ' \| ', 5
        if (-not $Activity) { $Activity = $parts[1] -replace '^ui: ', '' }
        if (-not $ErrorId) { $ErrorId = $parts[2] }
        if (-not $Message) { $Message = $parts[4] }
    }
    if ($ErrorId -match '\s') { $ErrorId = '' }   # a thrown string carries its message as the id: not an id
    if (-not $Message) { throw (New-VmmErrorRecord -Activity 'No error text.' -Fix 'Give -Message "<the exact error>" or -FromErrorLog.' -Category InvalidArgument -ErrorId 'VmmTicketEmpty') }
    $store = $null; $rec = $null
    try { $store = Read-VmmStore } catch { }
    if ($HostName -and $store) { $rec = $store.Hosts | Where-Object { $_.Name -eq ($HostName.Trim() -split '\.')[0].ToUpper() } | Select-Object -First 1 }
    $names = @(); if ($store) { $names = @(Get-VmmFleetName -Store $store) }
    if ($HostName) { $names += $HostName }
    $clean = { param($s) if ($IncludeTarget) { Protect-VmmLogText "$s" } else { ConvertTo-VmmShareableText -Text "$s" -Names $names } }

    $msg = & $clean (("$Message" -replace '\s+', ' ').Trim())
    $target = if ($IncludeTarget -and $rec) { $rec.Name } elseif ($HostName) { '<HOST> (name given when the ticket is sent)' } else { 'the technician laptop / Azure subscription (see error)' }
    $req = Get-VmmAccessRequirement -Message $Message -Target $(if ($IncludeTarget -and $rec) { $rec.Name } else { '<HOST>' })
    $hint = Get-VmmErrorHint -Message $Message
    $kind = if ($req) { $req.Kind } elseif ($Message -match '(?i)vpn') { 'VPN' } elseif ($Message -match '(?i)rdp|remote desktop|mstsc') { 'Remote desktop' } elseif ($hint) { 'Error' } else { 'Unknown error' }
    $scope = ''
    if ($kind -like 'Azure*') {
        $scope = if ($IncludeTarget -and $rec -and $rec.Azure -and $rec.Azure.ResourceGroup) { "resource group $($rec.Azure.ResourceGroup) (subscription of the VM)" } else { "the resource group that holds the VM (name given when the ticket is sent)" }
    }
    $requested = if ($req) { $req.Needed } elseif ($hint) { $hint.Fix } else { 'Please investigate the error below and tell me what access or change is needed.' }
    if ($scope) { $requested = "$requested. Scope: $scope." }
    $w = Get-VmmTimeWindow
    $sd = if ($Step) { Get-VmmWorkflowDefinition | Where-Object Name -eq $Step } else { $null }
    if (-not $Urgency) { $Urgency = if (($sd -and $sd.Class -eq 'Change') -or $kind -in 'Azure role', 'Sign-in policy', 'VPN') { 'High' } else { 'Normal' } }
    $urgText = switch ($Urgency) {
        'High'   { if ($w.ChangesAllowed) { 'High - it blocks maintenance in the change window that is open now.' } else { "High - it blocks maintenance planned for the next change window ($($w.NextChangeAt.ToString('ddd yyyy-MM-dd HH:mm')) $($w.ZoneLabel))." } }
        'Normal' { 'Normal - the host stays blocked; I have moved on to other machines.' }
        'Low'    { 'Low - a workaround exists; needed for the next maintenance round.' }
    }
    $what = if ($Activity) { & $clean $Activity } elseif ($sd) { $sd.Title } elseif ($Step) { $Step } else { 'A vmm maintenance action' }
    $impact = if ($HostName) { "Maintenance of $target cannot continue$(if ($Step) { " at step '$Step'" }). The upgrade programme to $((Get-VmmSetting 'Policy.TargetOs' -Default 'Windows Server 2019') -replace '\*', '') is delayed for this machine." }
              else { 'vmm cannot run this action for any machine until it is fixed: the daily maintenance target is at risk.' }
    $tried = @()
    try {
        $cat = Get-VmmWorkflowCatalog
        $aid = if ($Step) { "b-step-$($Step.ToLower())" } else { '' }
        $tried = @(Find-VmmKnowledge -Catalog $cat -ActionId $aid -Text $Message | Select-Object -First 3 | ForEach-Object { $_.Entry })
    } catch { }
    $ver = "$($MyInvocation.MyCommand.Module.Version)"
    $ref = 'VMM-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $text = @"
Subject: [$Urgency] $kind needed - $what

Summary
  $(if ($req) { "Access is needed: $($req.Needed)." } else { "An error stops a maintenance action: $what." })

What was attempted
  $what$(if ($Step) { " (maintenance workflow step '$Step')" }) on $target
  When: $($w.ZoneTime.ToString('yyyy-MM-dd HH:mm')) $($w.ZoneLabel)

Exact error
  $msg$(if ($ErrorId) { "`r`n  Error id: $ErrorId" })

Likely cause
  $(if ($hint) { $hint.Cause } else { 'Not identified automatically.' })

Requested action
  $requested

Impact
  $impact

Urgency
  $urgText

Already tried
$(if ($tried) { ($tried | ForEach-Object { "  - $($_.Symptom): $(@($_.Fix) -join ' ')" }) -join "`r`n" } else { '  - Retried once; no known fix applied.' })

Environment
  Tool: vmm $ver (PowerShell $($PSVersionTable.PSVersion)) on the technician laptop. No passwords or usernames are stored or included.
  Reference: $ref

Please tell me when it is done (or who can do it), so I can resume this machine.
"@
    $dir = Get-VmmPath -Name Tickets
    $file = Join-Path $dir ('{0}_{1}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ($kind -replace '[^A-Za-z0-9]+', '-'))
    Set-Content -LiteralPath $file -Value $text -Encoding UTF8 -ErrorAction Stop
    $clip = ''
    if (-not $NoClipboard) { try { $text | Set-Clipboard; $clip = ' and copied to the clipboard' } catch { } }

    Write-VmmLog "What to do now ($kind):" -Level Info
    if ($hint) { Write-VmmLog "  Cause: $($hint.Cause)" -Level Plain; Write-VmmLog "  Try:   $($hint.Fix)" -Level Plain }
    foreach ($k in $tried) { Write-VmmLog "  Known fix: $($k.Symptom) - $(@($k.Fix) -join ' ')" -Level Plain }
    if ($req) { Write-VmmLog "  You cannot fix this yourself: send the ticket below to the team that grants '$($req.Kind)'." -Level Warn }
    if ($HostName) { Write-VmmLog '  Mark the host Blocked (B on the host, or vmm blocker) and move on to the next host.' -Level Muted }
    Write-VmmLog "Ticket for IT saved$clip`: $file" -Level Success
    if (-not $IncludeTarget) { Write-VmmLog 'Sanitized: add the host / resource group name when you send it (<HOST> marks the place).' -Level Muted }
    [pscustomobject]@{ File = $file; Kind = $kind; Urgency = $Urgency; Reference = $ref; Text = $text }
}
