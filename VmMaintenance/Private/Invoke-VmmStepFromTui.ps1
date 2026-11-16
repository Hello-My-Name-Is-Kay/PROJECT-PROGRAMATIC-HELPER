function Invoke-VmmStepFromTui {
    # Runs a step from the console, asking the questions the CLI takes as switches: override reason
    # (business hours), confirmation for guided steps, manager-contact answer for blockers, whether to take
    # the start snapshot (default yes), and confirm-or-bypass for the manual check.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][string]$Step, [switch]$Confirmed)
    $sd = Get-VmmWorkflowDefinition | Where-Object Name -eq $Step
    $w = Get-VmmTimeWindow
    $p = @{ HostName = $HostName; Step = $Step }
    if ($sd.Class -eq 'Change' -and -not $w.ChangesAllowed) {
        Write-VmmLog "IMPORTANT: it is business hours ($($w.ZoneTime.ToString('HH:mm')) $($w.ZoneLabel)). $Step changes the host while people use it." -Level Error
        Write-VmmLog "Allowed from $($w.NextChangeAt.ToString('ddd HH:mm')) (in $($w.UntilChangeText)). Override only with your manager's agreement - it is recorded and reported." -Level Warn
        $a = Read-VmmPrompt "Type OVERRIDE to continue, anything else to cancel"
        if ($a -cne 'OVERRIDE') { Write-VmmLog 'Cancelled - nothing changed.' -Level Muted; return }
        $p.Override = $true
        $p.OverrideReason = Read-VmmPrompt 'Reason (who approved, why; min 10 chars)'
    }
    if ($Step -eq 'SnapStart') {
        $a = Read-VmmPrompt "Take the start snapshot of every disk of $HostName now (skipped by itself when every disk has one from the last hour)? (Y/n)"
        if ("$a" -match '^[nN]') { $p.Decline = $true; Write-VmmLog 'Start snapshot declined - recorded.' -Level Warn }
        return (Invoke-VmmWorkflowStep @p)
    }
    if ($Step -eq 'ManualCheck') {
        Write-VmmLog "Manual check of ${HostName}: log in, check the applications, SQL jobs and event logs as you normally do." -Level Info
        $a = Read-VmmPrompt 'Type Y if you checked it and it is fine, BYPASS to skip the check (recorded with a reason), anything else to cancel'
        if ("$a" -match '^[yY]$') { $p.Confirmed = $true }
        elseif ("$a" -ceq 'BYPASS') { $p.Bypass = $true; $p.BypassReason = Read-VmmPrompt 'Reason (who checked instead, or why no check is needed; min 10 chars)' }
        else { Write-VmmLog 'Cancelled - nothing recorded.' -Level Muted; return }
        return (Invoke-VmmWorkflowStep @p)
    }
    if ($Confirmed) {
        $a = Read-VmmPrompt "Confirm you completed '$Step' on $HostName yourself and it succeeded (y/N)"
        if ($a -notmatch '^[yY]') { Write-VmmLog 'Not confirmed - nothing recorded.' -Level Muted; return }
        $p.Confirmed = $true
    }
    if ($sd.Class -eq 'Change' -and -not $Confirmed) {
        $a = Read-VmmPrompt "Run $Step on $HostName now? (y/N)"
        if ($a -notmatch '^[yY]') { Write-VmmLog 'Cancelled.' -Level Muted; return }
    }
    Invoke-VmmWorkflowStep @p
}
