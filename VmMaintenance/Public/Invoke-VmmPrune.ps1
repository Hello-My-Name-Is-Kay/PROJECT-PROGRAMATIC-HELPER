function Invoke-VmmPrune {
    <#
    .SYNOPSIS
        End-of-work prune: deletes expired snapshots (RetentionDays tag) in every subscription used by
        the fleet. Always shows the preview first; deletes only with -Apply and your confirmation.
    .EXAMPLE
        Invoke-VmmPrune            # preview only
    .EXAMPLE
        Invoke-VmmPrune -Apply
    .EXAMPLE
        Invoke-VmmPrune -Apply -Override -OverrideReason 'approved by <manager>, storage quota alert'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([switch]$Apply, [switch]$Override, [string]$OverrideReason)
    $store = Read-VmmStore
    $subs = @($store.Hosts | Where-Object { $_.Azure } | ForEach-Object { $_.Azure.SubscriptionId } | Select-Object -Unique)
    if (-not $subs) { $s = Get-VmmSetting 'Azure.Subscription'; if ($s) { $subs = @($s) } }
    if (-not $subs) { Write-VmmLog 'No Azure subscriptions known for the fleet - nothing to prune.' -Level Muted; return }

    Write-VmmLog "Prune preview across $($subs.Count) subscription(s) (only snapshots tagged for cleanup, past RetentionDays):" -Level Info
    $preview = foreach ($s in $subs) { Remove-VmmExpiredSnapshot -Subscription $s -AllResourceGroups -WhatIf -PassThru }
    $due = @($preview | Where-Object Action -eq 'WouldDelete')
    if (-not $due) { Write-VmmLog 'Nothing expired. Prune done.' -Level Success; return }
    $due | Format-Table Snapshot, ResourceGroup, AgeDays, RetentionDays -AutoSize | Out-VmmHost
    if (-not $Apply) { Write-VmmLog "$($due.Count) snapshot(s) would be deleted. Re-run with -Apply to delete them." -Level Warn; return }
    # Deleting snapshots removes rollback points: treated as a change (business hours = override only)
    Assert-VmmWindow -Class Change -Target "prune $($due.Count) snapshot(s)" -Override:$Override -OverrideReason $OverrideReason
    if (-not $PSCmdlet.ShouldProcess("$($due.Count) expired snapshot(s)", 'Delete permanently')) { Write-VmmLog 'Cancelled.' -Level Warn; return }
    foreach ($s in $subs) { Remove-VmmExpiredSnapshot -Subscription $s -AllResourceGroups -Confirm:$false }
}
