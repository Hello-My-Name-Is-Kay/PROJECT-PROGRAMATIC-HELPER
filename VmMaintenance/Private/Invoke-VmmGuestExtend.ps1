function Invoke-VmmGuestExtend {
    # Waits for the VM agent on all items together, launches the extend on each as soon as its agent
    # is Ready, then checks C: really grew. Status: Complete or ExtendCheck (with the reason in Notes).
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Item,
        [Parameter(Mandatory)][string]$ScriptFile,
        [int]$AgentWaitMinutes = 10
    )
    if (-not $Item) { return }

    $pending  = @($Item)
    $deadline = (Get-Date).AddMinutes($AgentWaitMinutes)
    Write-VmmLog "`n[Extend C:] waiting for VM agent on $($pending.Count) VM(s) (up to $AgentWaitMinutes min)..." -Level Info

    while ($pending.Count -and (Get-Date) -lt $deadline) {
        $still = @()
        foreach ($p in $pending) {
            $agent = $null
            try {
                Set-VmmSubscription -Subscription $p.SubscriptionId
                $agent = (Get-AzVM -ResourceGroupName $p.ResourceGroup -Name $p.VMName -Status -ErrorAction Stop).VMAgent.Statuses |
                         Select-Object -First 1
            } catch { $agent = $null }   # transient while booting; retried until the deadline

            if ($agent -and $agent.DisplayStatus -eq 'Ready') {
                Write-VmmLog "  $($p.VMName): agent Ready, extending C:"
                try {
                    $p.Job = Invoke-AzVMRunCommand -ResourceGroupName $p.ResourceGroup -VMName $p.VMName `
                             -CommandId 'RunPowerShellScript' -ScriptPath $ScriptFile -AsJob -ErrorAction Stop
                } catch {
                    $p.Status = 'ExtendCheck'
                    $p.Notes += (ConvertTo-VmmNote -Activity 'Run Command start' -ErrorRecord $_) + '; '
                }
            } else { $still += $p }
        }
        $pending = $still
        if ($pending.Count) { Start-Sleep -Seconds 15 }
    }
    foreach ($p in $pending) {
        $p.Status = 'ExtendCheck'
        $p.Notes += "VM agent not Ready after $AgentWaitMinutes min - extend C: by hand (Disk Management) or raise OsDiskExpand.AgentWaitMinutes; "
        Write-VmmLog "$($p.VMName): VM agent not Ready after $AgentWaitMinutes min - C: not extended" -Level Warn
    }

    # Collect results and check that C: actually grew
    foreach ($p in @($Item | Where-Object { $_.Job })) {
        $p.Job | Wait-Job | Out-Null
        $jerr = $null
        $res  = Receive-Job $p.Job -ErrorVariable jerr -ErrorAction SilentlyContinue
        Remove-Job $p.Job -Force; $p.Job = $null
        $msg = ($res.Value | Select-Object -ExpandProperty Message) -join "`n"
        if ($msg -match 'BEFORE=([\d\.]+) AFTER=([\d\.]+)') {
            $p.CBeforeGB = [double]$Matches[1]; $p.CAfterGB = [double]$Matches[2]
            if ($p.CAfterGB -gt $p.CBeforeGB) {
                $p.Status = 'Complete'
                Write-VmmLog "  $($p.VMName): C: $($p.CBeforeGB) -> $($p.CAfterGB) GB" -Level Success
            } else {
                $p.Status = 'ExtendCheck'
                $p.Notes += 'C: did not grow (already full size, or a recovery partition after C: blocks it) - see log; '
                Write-VmmLog "$($p.VMName): C: did not grow. diskpart output follows." -Level Warn
                Write-VmmLog "--- diskpart output for $($p.VMName) ---`n$msg" -Level Muted
            }
        } else {
            $why = if ($jerr) { "$($jerr | Select-Object -First 1)" } else { 'no BEFORE/AFTER line returned' }
            $p.Status = 'ExtendCheck'
            $p.Notes += "Run Command output unreadable: $why; "
            Write-VmmLog "$($p.VMName): Run Command output unreadable - $why" -Level Warn
        }
    }
}
