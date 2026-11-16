function Invoke-VmmNextStep {
    <#
    .SYNOPSIS
        Runs the next step for one host, or the next AUTO step on every queued host where it is
        allowed right now (-All). Failures are recorded and the batch carries on; at the end the command
        fails (VmmNextStepFailed, exit code 1) when any host failed or was blocked, naming them.
    .DESCRIPTION
        Business hours: this moves every host through Precheck, SnapStart (while Policy.SnapStartInBusinessHours
        is on) and Stage. Maintenance window: also SnapPreSql, (on Azure) ExpandDisk, SnapPostSql, Verify and
        SnapFinal. Guided steps (Upgrade, ManualCheck) are listed, not run. SnapStart is taken, not declined.
    .EXAMPLE
        Invoke-VmmNextStep -All
    #>
    [CmdletBinding()]
    param([string]$HostName, [switch]$All, [ValidateSet('Sent', 'Later', 'Bypass')][string]$Contact = 'Later')
    $queue = Get-VmmQueue
    if ($HostName) { $queue = @($queue | Where-Object Host -eq ($HostName -split '\.')[0].ToUpper()) }
    elseif (-not $All) { $queue = @($queue | Select-Object -First 1) }
    $run    = @($queue | Where-Object { $_.Allowed -and -not $_.Guided -and $_.State -notin 'Blocked' })
    $manual = @($queue | Where-Object { $_.Allowed -and $_.Guided })
    if (-not $run) { Write-VmmLog 'Nothing auto-runnable right now (guided, blocked, or outside the change window).' -Level Warn }
    $bad = @()
    foreach ($q in $run) {
        try { Invoke-VmmWorkflowStep -HostName $q.Host -Step $q.Step.Name -Contact $Contact }
        catch {
            Write-VmmLog "[$($q.Host)] $($_.Exception.Message)" -Level Error
            $bad += [pscustomobject]@{ Host = $q.Host; Step = $q.Step.Name; Id = "$($_.FullyQualifiedErrorId)"; Why = (("$($_.Exception.Message)" -split "`r?`n")[0]).Trim() }
        }
    }
    foreach ($m in $manual) { Write-VmmLog "[$($m.Host)] $($m.Step.Name) is guided: vmm guide -HostName $($m.Host) -Step $($m.Step.Name)" -Level Info }
    if ($run -and $Contact -eq 'Later') { Write-VmmLog 'Any blocker raised here is marked "Later": send the reports from Reports\Blockers.' -Level Muted }
    if ($bad) {
        $blocked = @($bad | Where-Object { $_.Id -like 'VmmStepBlocked*' }).Count
        throw (New-VmmErrorRecord -Activity "$($bad.Count) of $($run.Count) step(s) did not succeed ($blocked blocked, $($bad.Count - $blocked) failed)." `
            -Target (@($bad | ForEach-Object { "$($_.Host)/$($_.Step)" }) -join ', ') -Cause (@($bad | Select-Object -First 3 | ForEach-Object { "$($_.Host): $($_.Why)" }) -join ' | ') `
            -Fix 'Each one is recorded on its host (vmm plan, vmm status). Fix or raise blockers, then run vmm next again.' -Category InvalidResult -ErrorId 'VmmNextStepFailed')
    }
}
