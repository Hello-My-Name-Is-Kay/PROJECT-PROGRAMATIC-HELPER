function Expand-VmmOsDisk {
    <#
    .SYNOPSIS
        Grows the OS disk of Azure Windows VMs to the next size tier, extends C:, and puts each VM
        back in the power state it was in before the run. Report only unless -Apply.
    .DESCRIPTION
        For every computer on the list:
          1. Resolve    - Finds the Azure VM by VM name or Windows computer name (Resource Graph).
                          If that fails: DNS -> private IP -> NIC -> VM.
          2. Plan       - Reads the live power state and the OS disk, works out the next tier.
                          Without -Apply the run stops here and writes the plan to CSV.
          3. Deallocate - Every VM that isn't already deallocated (in parallel).
          4. Snapshot   - Full copy of the OS disk, tagged, taken while deallocated (consistent).
          5. Resize     - OS disk to the next tier. Disk SKU (Premium/Standard) is not changed.
          6. Start      - Every VM in the batch. C: can only be extended while Windows is running.
          7. Extend C:  - Run Command + diskpart inside the VM (works on 2008 R2 and later).
          8. Restore    - VMs that were off before the run are switched off again:
                            deallocated -> deallocated, stopped -> stopped (still allocated).
                          VMs that were running are left running.

        Output (in <WorkDir>\OsDiskExpand): Plan_<time>.csv or Results_<time>.csv, plus a transcript.

        MODES
          (default)    Plan only. Nothing is changed.
          -Apply       Make changes. Asks for confirmation (-Confirm:$false to skip).
          -ExtendOnly  Skip steps 3-5. For VMs whose disk was already grown in Azure but whose C:
                       was never extended. Running VMs get no downtime in this mode.

        SAFETY
          - Disks larger than OsDiskExpand.MaxCurrentGB are skipped.
          - A name that matches no VM, or more than one VM, is skipped.
          - A VM in a transitional state (starting, stopping, ...) is skipped. Re-run it later.
          - If any step fails for a VM, that VM still goes back to its original power state.
            A VM whose snapshot or resize failed and that was off is never started.
          - If the run itself stops half way (an unexpected error or Ctrl+C), a recovery waits for the Azure
            operations already sent and puts every VM back in its power state; running VMs are started again.
          - When any VM is not Complete or not back in its power state, the run ends with an error naming them
            (VmmExpandIncomplete, exit code 1) after the results CSV is written.
          - The snapshot is kept for rollback. Its RetentionDays tag tells cleanup when it can go.

        DOWNTIME
          Running VMs: deallocate + snapshot + resize + start, typically 5-10 minutes.
          The whole batch goes down together, so keep batches small (5-11 VMs) and agreed with owners.

        IF C: DOES NOT GROW (Status = ExtendCheck)
          Usually a recovery partition sits directly after C:, so diskpart can't extend into the new
          space. The diskpart output is in the transcript. Fix by hand in Disk Management.

        Rights: Virtual Machine Contributor (stop/start/run command) and Disk Snapshot Contributor
        on the VMs' resource groups. Run from a machine that resolves the computer names in DNS.
    .EXAMPLE
        Expand-VmmOsDisk                                  # plan for ServerLists.OsDiskExpand
    .EXAMPLE
        Expand-VmmOsDisk -ComputerName srv01, srv02 -Apply
    .EXAMPLE
        Expand-VmmOsDisk -Apply -ExtendOnly
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string[]]$ComputerName,
        [string]$ServerList,
        [switch]$Apply,
        [switch]$ExtendOnly,
        [string]$TenantId,
        [string]$Subscription,
        [hashtable]$SnapshotTags,
        [int[]]$TierSizes,
        [int]$MaxCurrentGB,
        [int]$AgentWaitMinutes,
        [string]$LogDir,
        [switch]$Override,
        [string]$OverrideReason,
        [switch]$PassThru
    )

    # --- Settings: parameter, else local config, else built-in default
    if (-not $PSBoundParameters.ContainsKey('TenantId'))         { $TenantId         = Get-VmmSetting 'Azure.TenantId' -Required }
    if (-not $PSBoundParameters.ContainsKey('Subscription'))     { $Subscription     = Get-VmmSetting 'Azure.Subscription' }
    if (-not $PSBoundParameters.ContainsKey('TierSizes'))        { $TierSizes        = Get-VmmSetting 'OsDiskExpand.TierSizes' -Default @(4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096) }
    if (-not $PSBoundParameters.ContainsKey('MaxCurrentGB'))     { $MaxCurrentGB     = Get-VmmSetting 'OsDiskExpand.MaxCurrentGB' -Default 128 }
    if (-not $PSBoundParameters.ContainsKey('AgentWaitMinutes')) { $AgentWaitMinutes = Get-VmmSetting 'OsDiskExpand.AgentWaitMinutes' -Default 10 }
    if ($Apply -and -not $ExtendOnly -and -not $SnapshotTags)   { $SnapshotTags     = Get-VmmSetting 'Snapshots.Tags' -Required }
    $snapshotSku = Get-VmmSetting 'Snapshots.SkuName' -Default 'Standard_LRS'
    $LogDir = if ($LogDir) { Resolve-VmmWorkDir -Path $LogDir } else { Resolve-VmmWorkDir -SubFolder 'OsDiskExpand' }

    $names = @(Read-VmmServerList -Name $ComputerName -Path $ServerList -ListKey 'OsDiskExpand' -Case Lower)
    if ($names.Count -gt 11) {
        Write-VmmLog "$($names.Count) names in one batch. The whole batch goes down together - 5-11 per run is the agreed size." -Level Warn
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $transcribing = $false
    $changing = $false   # from the first power change until the restore: the finally puts VMs back if the run stops
    $work = @()
    try {
        Start-Transcript -Path (Join-Path $LogDir "OsDiskExpand_$stamp.log") -ErrorAction Stop | Out-Null
        $transcribing = $true
    } catch {
        Write-VmmLog "Transcript not started ($($_.Exception.Message)). Another transcript may be running; the run continues without a log file." -Level Warn
    }

    try {
        Assert-VmmModule -Name 'Az.Accounts', 'Az.Compute', 'Az.ResourceGraph'
        Connect-VmmAzure -TenantId $TenantId -Subscription $Subscription

        #region 1-2. Resolve and plan
        $plan = @(New-VmmExpandPlan -Name $names -TierSizes $TierSizes -MaxCurrentGB $MaxCurrentGB -ExtendOnly:$ExtendOnly)
        $mode = if ($ExtendOnly) { 'EXTEND ONLY' } else { 'RESIZE + EXTEND' }
        Write-VmmLog "`nMode: $mode" -Level Info
        $plan | Format-Table ComputerName, VMName, MatchedBy, InitialState, Sku, CurrentGB, NewGB, Action, Status, Notes -AutoSize | Out-VmmHost

        if (-not $Apply) {
            Export-VmmCsv -InputObject @($plan | Select-Object * -ExcludeProperty Job, Started) -Path (Join-Path $LogDir "Plan_$stamp.csv")
            Write-VmmLog 'Report only - nothing changed. Review the plan, then re-run with -Apply.' -Level Warn
            if ($PassThru) { $plan | Select-Object * -ExcludeProperty Job, Started }
            return
        }

        $work = @($plan | Where-Object Status -eq 'Ready')
        if (-not $work) { Write-VmmLog 'Nothing to do: no VM is Ready. See Status/Notes in the plan above.' -Level Warn; return }

        $noOv = if (-not (Get-VmmSetting 'Policy.ExpandDiskOverride' -Default $false)) { 'Disk expansion shuts the VMs down (deallocate, resize, start): after business hours only.' } else { $null }
        Assert-VmmWindow -Class Change -Target "OS disk expand: $(($work.VMName) -join ', ')" -Override:$Override -OverrideReason $OverrideReason -NoOverrideReason $noOv
        $impact = if ($ExtendOnly) { 'no downtime for running VMs' } else { 'running VMs go down for about 5-10 minutes' }
        if (-not $PSCmdlet.ShouldProcess(($work.VMName -join ', '), "$mode on $($work.Count) VM(s) - $impact")) {
            Write-VmmLog 'Cancelled - nothing changed.' -Level Warn
            return
        }
        #endregion
        $changing = $true

        if (-not $ExtendOnly) {
            #region 3. Deallocate (all VMs not already deallocated)
            # 'stopped' VMs are deallocated too: Azure only allows an OS disk resize when deallocated.
            $toDealloc = @($work | Where-Object InitialState -ne 'deallocated')
            Write-VmmLog "`n[Deallocate] $($toDealloc.Count) VM(s)..." -Level Info
            foreach ($p in $toDealloc) {
                try {
                    Set-VmmSubscription -Subscription $p.SubscriptionId
                    $p.Job = Stop-AzVM -ResourceGroupName $p.ResourceGroup -Name $p.VMName -Force -AsJob -ErrorAction Stop
                } catch {
                    $p.Status = 'Failed'
                    $p.Notes += (ConvertTo-VmmNote -Activity 'Deallocate' -ErrorRecord $_) + '; '
                    Write-VmmLog "$($p.VMName): deallocate could not start - $($_.Exception.Message)" -Level Error
                }
            }
            Wait-VmmJob -Item $toDealloc -Label 'Deallocate'
            #endregion

            #region 4-5. Snapshot, then resize
            foreach ($p in @($work | Where-Object Status -eq 'Ready')) {
                Invoke-VmmOsDiskResize -Item $p -Tags $SnapshotTags -Stamp $stamp -SkuName $snapshotSku
            }
            #endregion
        }

        #region 6. Start
        # Every VM that was running (even if a step failed, so nothing is left down), plus VMs that
        # were off but are ready for the extend. Off VMs that failed stay off.
        $readyState = if ($ExtendOnly) { 'Ready' } else { 'Resized' }
        $toStart = @($work | Where-Object { $_.InitialState -eq 'running' -or $_.Status -eq $readyState })
        # In ExtendOnly mode running VMs are already up
        $toStart = @($toStart | Where-Object { -not ($ExtendOnly -and $_.InitialState -eq 'running') })

        Write-VmmLog "`n[Start] $($toStart.Count) VM(s)..." -Level Info
        foreach ($p in $toStart) {
            try {
                Set-VmmSubscription -Subscription $p.SubscriptionId
                $p.Started = $true    # step 8 switches it off again if it was off before
                $p.Job = Start-AzVM -ResourceGroupName $p.ResourceGroup -Name $p.VMName -AsJob -ErrorAction Stop
            } catch {
                $p.Status = 'Failed'
                $p.Notes += (ConvertTo-VmmNote -Activity 'Start' -ErrorRecord $_) + '; '
                Write-VmmLog "$($p.VMName): start could not be launched - VM may be left down. $($_.Exception.Message)" -Level Error
            }
        }
        Wait-VmmJob -Item $toStart -Label 'Start'
        #endregion

        #region 7. Extend C: via Run Command
        $scriptFile = Join-Path $LogDir "extend_c_$stamp.ps1"
        Set-Content -LiteralPath $scriptFile -Value (Get-VmmExtendScript) -Encoding UTF8
        Invoke-VmmGuestExtend -Item @($work | Where-Object Status -eq $readyState) -ScriptFile $scriptFile -AgentWaitMinutes $AgentWaitMinutes
        #endregion

        #region 8. Restore original power state
        Restore-VmmPowerState -Item $work
        $changing = $false
        #endregion

        #region Results
        # Live final state, so the report shows what is really true now
        foreach ($p in $work) {
            try { $p.FinalState = Get-VmmPowerState -SubscriptionId $p.SubscriptionId -ResourceGroup $p.ResourceGroup -VMName $p.VMName }
            catch { $p.FinalState = 'unknown' }
            if ($p.FinalState -ne $p.InitialState) { $p.Notes += 'FINAL STATE differs from initial - check; ' }
        }
        # Snapshot left without a resize: flag it so nobody assumes the disk grew
        foreach ($p in @($work | Where-Object { $_.Snapshot -and $_.Status -eq 'Failed' })) {
            $p.Notes += "Snapshot $($p.Snapshot) exists but resize did not complete; "
        }

        $plan | Format-Table ComputerName, VMName, InitialState, CurrentGB, NewGB, Snapshot, CBeforeGB, CAfterGB, FinalState, Status, Notes -AutoSize | Out-VmmHost
        Export-VmmCsv -InputObject @($plan | Select-Object * -ExcludeProperty Job, Started) -Path (Join-Path $LogDir "Results_$stamp.csv")
        Write-VmmLog 'Status key: Complete = done | ExtendCheck = disk grown, C: needs a manual look | Failed = see Notes | Skipped = not touched'

        $bad = @($work | Where-Object { $_.Status -ne 'Complete' -or $_.FinalState -ne $_.InitialState })
        if ($bad) { Write-VmmLog "$($bad.Count) VM(s) need a look: $(($bad.VMName) -join ', ')" -Level Warn }
        else { Write-VmmLog "All $($work.Count) VM(s) complete and back in their original power state." -Level Success }

        if ($PassThru) { $plan | Select-Object * -ExcludeProperty Job, Started }
        if ($bad) {
            throw (New-VmmErrorRecord -Activity "OS disk expansion incomplete: $($bad.Count) of $($work.Count) VM(s) need a look." `
                -Target (@($bad | ForEach-Object { "$($_.VMName): $($_.Status), $($_.FinalState) (was $($_.InitialState))" }) -join ' | ') `
                -Cause (@($bad | Select-Object -First 3 | ForEach-Object { "$($_.VMName): $((("$($_.Notes)") -replace '\s+', ' ').Trim())" }) -join ' | ') `
                -Fix "Details: Results_$stamp.csv and the transcript in $LogDir. ExtendCheck = disk grown, extend C: in Disk Management; Failed = see Notes; power state differs = fix it in the Azure portal." `
                -Category InvalidResult -ErrorId 'VmmExpandIncomplete')
        }
        #endregion
    }
    finally {
        if ($changing) {
            # [SAFETY] stopped between the first power change and the restore: no VM is left down or left running
            try { Invoke-VmmPowerRecovery -Item $work } catch { Write-VmmLog "[Recovery] failed: $($_.Exception.Message). Check these VMs in the Azure portal: $(($work.VMName) -join ', ')" -Level Error }
            try {
                Export-VmmCsv -InputObject @($plan | Select-Object * -ExcludeProperty Job, Started) -Path (Join-Path $LogDir "Results_$stamp.csv")
                Add-VmmLogEntry -Text ("Disk expansion stopped half way; results: " + (@($work | ForEach-Object { "$($_.VMName)=$($_.Status)/$($_.FinalState)" }) -join ', ')) -Level Error
            } catch { }
        }
        if ($transcribing) { Stop-Transcript | Out-Null }
    }
}
