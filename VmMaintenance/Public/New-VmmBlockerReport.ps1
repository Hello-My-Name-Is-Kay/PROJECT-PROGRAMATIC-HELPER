function New-VmmBlockerReport {
    <#
    .SYNOPSIS
        Writes a ready-to-send access/blocker report for your manager, marks the step Blocked and
        lets you move on to the next host. The tool never sends email: you send it from Outlook.
    .DESCRIPTION
        The report says what failed, the exact error, the target, the access needed and why, plus
        suggested request text. It is plaintext (it must be readable by your manager) and is saved under
        %LOCALAPPDATA%\VmMaintenance\Reports\Blockers. It contains no usernames or passwords.
        You must answer how the manager contact is handled: Sent, Later or Bypass (recorded).
    .EXAMPLE
        New-VmmBlockerReport -HostName srv01 -Step Stage -Message 'Access is denied' -Contact Later
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Message,
        [string]$Needed,
        [string]$Why,
        [ValidateSet('Sent', 'Later', 'Bypass')][string]$Contact,
        [switch]$NoClipboard
    )
    $Message = Protect-VmmLogText $Message
    $req = Get-VmmAccessRequirement -Message $Message -Target $HostName
    if (-not $Needed) { $Needed = if ($req) { $req.Needed } else { 'To be confirmed - see the error above' } }
    $stepDef = Get-VmmWorkflowDefinition | Where-Object Name -eq $Step
    if (-not $Why) { $Why = if ($stepDef) { "Needed for step '$Step' ($($stepDef.Title)) of the planned OS/software upgrade." } else { "Needed for step '$Step'." } }
    $hint = Get-VmmErrorHint -Message $Message
    $manager = Get-VmmSetting 'Reports.ManagerName' -Default ''
    $w = Get-VmmTimeWindow
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    $text = @"
Subject: Access needed - $Step on $HostName ($($w.ZoneTime.ToString('yyyy-MM-dd')))

Hi$(if ($manager) { " $manager" }),

While working on $HostName I was blocked at step "$Step".

  What failed : $(if ($stepDef) { $stepDef.Title } else { $Step })
  Target      : $HostName
  Error       : $Message
  Likely cause: $(if ($hint) { $hint.Cause } else { 'not identified automatically' })
  Access needed: $Needed
  Why         : $Why
  When        : $($w.ZoneTime.ToString('yyyy-MM-dd HH:mm')) $($w.ZoneLabel)

Could you grant this, or tell me who can? Until then $HostName stays in my queue as Blocked
and I have moved on to the next machine.

Thanks,
"@
    $dir  = Get-VmmPath -Name Blockers
    $file = Join-Path $dir ('{0}_{1}_{2}.txt' -f $stamp, $HostName.ToUpper(), $Step)
    Set-Content -LiteralPath $file -Value $text -Encoding UTF8

    if (-not $Contact) {
        Write-VmmLog 'Manager contact is required for this blocker. Answer: [S]ent now / [L]ater (listed in the daily report) / [B]ypass (you confirm no contact is needed)' -Level Warn
        do { $a = (Read-VmmPrompt 'S/L/B').Trim().ToUpper() } until ($a -in 'S', 'L', 'B')
        $Contact = @{ S = 'Sent'; L = 'Later'; B = 'Bypass' }[$a]
    }

    $store = Read-VmmStore
    $rec = Get-VmmHostRecord -Store $store -Name $HostName
    $rec.Blockers = @($rec.Blockers) + [pscustomobject]@{
        At = (Get-Date).ToUniversalTime().ToString('o'); Step = $Step; Summary = $Needed; File = $file; Contact = $Contact; Resolved = $false
    }
    Set-VmmStepState -Record $rec -Step $Step -Status 'Blocked' -Note "$Needed (report: $([IO.Path]::GetFileName($file)), contact: $Contact)"
    Save-VmmStore -Store $store

    if (-not $NoClipboard) { try { $text | Set-Clipboard; $clip = ' and copied to the clipboard' } catch { $clip = '' } }
    Write-VmmLog "Blocker report saved$clip`: $file" -Level Warn
    Write-VmmLog "Paste it into Outlook to your manager. $HostName is marked Blocked at $Step; move on to the next host." -Level Info
    $file
}
