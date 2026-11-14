function Invoke-VmmNextStep {
    <#
    .SYNOPSIS
        Runs the next step for one host, or the next AUTO step on every queued host where it is
        allowed right now (-All). Failures are recorded and the batch carries on.
    .DESCRIPTION
        Business hours: this moves every host through Precheck and Stage. Maintenance window: also
        PreSnapshot and (on Azure) ExpandDisk. Guided steps are listed, not run.
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
    foreach ($q in $run) {
        try { Invoke-VmmWorkflowStep -HostName $q.Host -Step $q.Step.Name -Contact $Contact }
        catch { Write-VmmLog "[$($q.Host)] $($_.Exception.Message)" -Level Error }
    }
    foreach ($m in $manual) { Write-VmmLog "[$($m.Host)] $($m.Step.Name) is guided: vmm guide -HostName $($m.Host) -Step $($m.Step.Name)" -Level Info }
    if ($run -and $Contact -eq 'Later') { Write-VmmLog 'Any blocker raised here is marked "Later": send the reports from Reports\Blockers.' -Level Muted }
}
