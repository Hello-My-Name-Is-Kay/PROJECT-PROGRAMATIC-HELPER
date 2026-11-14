function Restore-VmmPowerState {
    # Switches off again the VMs this run started that were off before:
    #   deallocated -> deallocated, stopped -> stopped (still allocated). Runs even if the extend failed.
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Item)

    $toRestore = @($Item | Where-Object { $_.Started -and $_.InitialState -ne 'running' })
    Write-VmmLog "`n[Restore] switching off $($toRestore.Count) VM(s) that were off before the run..." -Level Info
    foreach ($p in $toRestore) {
        try {
            Set-VmmSubscription -Subscription $p.SubscriptionId
            if ($p.InitialState -eq 'stopped') {
                $p.Job = Stop-AzVM -ResourceGroupName $p.ResourceGroup -Name $p.VMName -Force -StayProvisioned -AsJob -ErrorAction Stop
            } else {
                $p.Job = Stop-AzVM -ResourceGroupName $p.ResourceGroup -Name $p.VMName -Force -AsJob -ErrorAction Stop
            }
        } catch {
            $p.Notes += (ConvertTo-VmmNote -Activity 'RESTORE (VM may be left running)' -ErrorRecord $_) + '; '
            Write-VmmLog "$($p.VMName): could not switch off again - VM may be left running and billing. $($_.Exception.Message)" -Level Error
        }
    }
    # -KeepStatus: a failed switch-off is noted but doesn't hide whether the extend worked
    Wait-VmmJob -Item $toRestore -Label 'RESTORE (VM may be left running)' -KeepStatus
}
