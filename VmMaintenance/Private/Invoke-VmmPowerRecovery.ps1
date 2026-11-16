function Invoke-VmmPowerRecovery {
    # [SAFETY] Expand-VmmOsDisk stopped half way (unexpected error or Ctrl+C) after it had switched VMs off or on.
    # Waits for the Azure operations already sent (a VM that is still deallocating cannot be started), then puts
    # every VM back as it was: running before -> started again (a VM is never left down by this tool); off before
    # and started by this run -> switched off again (deallocated or stopped, as it was). Each VM is handled on its
    # own; one that cannot be put back is named in red, to do in the Azure portal. Never throws.
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Item, [int]$WaitSeconds = 900)
    $items = @($Item | Where-Object { $_ })
    if (-not $items) { return }
    Write-VmmLog "[Recovery] the run stopped before the power-state restore: putting $($items.Count) VM(s) back as they were..." -Level Error

    # 1. Operations already sent to Azure finish first
    $jobs = @($items | Where-Object { $_.Job } | ForEach-Object { $_.Job })
    if ($jobs) {
        Write-VmmLog "[Recovery] waiting for $($jobs.Count) Azure operation(s) already sent (up to $([int]($WaitSeconds / 60)) min)..." -Level Info
        try { $null = $jobs | Wait-Job -Timeout $WaitSeconds } catch { }
        foreach ($p in @($items | Where-Object { $_.Job })) {
            if ($p.Job.State -in 'NotStarted', 'Running') { $p.Notes += 'RECOVERY: an Azure operation was still running; ' }
            try { Remove-Job $p.Job -Force -ErrorAction Stop } catch { }
            $p.Job = $null
        }
    }

    # 2. Live state, then start or switch off what differs from the state before the run
    foreach ($p in $items) {
        $now = 'unknown'
        try { $now = Get-VmmPowerState -SubscriptionId $p.SubscriptionId -ResourceGroup $p.ResourceGroup -VMName $p.VMName } catch { }
        try {
            if ($p.InitialState -eq 'running' -and $now -ne 'running') {
                Write-VmmLog "[Recovery] $($p.VMName): $now, was running - starting it again" -Level Warn
                Set-VmmSubscription -Subscription $p.SubscriptionId
                $p.Job = Start-AzVM -ResourceGroupName $p.ResourceGroup -Name $p.VMName -AsJob -ErrorAction Stop
            } elseif ($p.InitialState -ne 'running' -and $p.Started -and $now -in 'running', 'starting') {
                Write-VmmLog "[Recovery] $($p.VMName): $now, was $($p.InitialState) - switching it off again" -Level Warn
                Set-VmmSubscription -Subscription $p.SubscriptionId
                $p.Job = Stop-AzVM -ResourceGroupName $p.ResourceGroup -Name $p.VMName -Force -StayProvisioned:($p.InitialState -eq 'stopped') -AsJob -ErrorAction Stop
            }
        } catch {
            $p.Notes += (ConvertTo-VmmNote -Activity 'RECOVERY' -ErrorRecord $_) + '; '
            Write-VmmLog "[Recovery] $($p.VMName): could not put it back ($now, was $($p.InitialState)): $($_.Exception.Message)" -Level Error
        }
    }
    try { Wait-VmmJob -Item $items -Label 'RECOVERY' -KeepStatus } catch { Write-VmmLog "[Recovery] waiting for Azure failed: $($_.Exception.Message)" -Level Error }

    # 3. What is true now: off-before VMs count as back when they are off (deallocated or stopped)
    $wrong = @()
    foreach ($p in $items) {
        try { $p.FinalState = Get-VmmPowerState -SubscriptionId $p.SubscriptionId -ResourceGroup $p.ResourceGroup -VMName $p.VMName } catch { $p.FinalState = 'unknown' }
        $p.Notes += 'RUN STOPPED: power state put back by recovery; '
        $back = ($p.FinalState -eq $p.InitialState) -or ($p.InitialState -ne 'running' -and $p.FinalState -in 'deallocated', 'stopped')
        if (-not $back) { $wrong += "$($p.VMName) ($($p.FinalState), was $($p.InitialState))" }
    }
    if ($wrong) { Write-VmmLog "[Recovery] put these back in the Azure portal NOW: $($wrong -join ', ')" -Level Error }
    else { Write-VmmLog '[Recovery] every VM is back in its power state from before the run (off ones may now be deallocated).' -Level Success }
}
