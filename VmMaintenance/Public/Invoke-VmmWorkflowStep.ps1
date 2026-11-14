function Invoke-VmmWorkflowStep {
    <#
    .SYNOPSIS
        Runs one workflow step on one host, enforcing order, the time rules, gates and checkpoints.
    .DESCRIPTION
        Steps: Precheck, Stage, PreSnapshot, ExpandDisk, Upgrade, Verify (see docs\WORKFLOW.md).
        - Earlier steps must be finished first.
        - Change steps are refused in business hours unless -Override -OverrideReason (recorded).
        - Guided steps (and Hybrid steps on non-Azure hosts) need -Confirmed after you did the work in
          RDP/RDM following Get-VmmRdpGuide.
        - After each successful changing step on an Azure VM, a checkpoint snapshot is taken
          (Workflow.SnapshotAfter = ChangingSteps | EveryStep | Off).
        - Access errors produce a blocker report and mark the step Blocked (-Contact answers the
          manager-contact question up front).
    .EXAMPLE
        Invoke-VmmWorkflowStep -HostName srv01 -Step Precheck
    .EXAMPLE
        Invoke-VmmWorkflowStep -HostName srv01 -Step Upgrade -Confirmed
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][ValidateSet('Precheck', 'Stage', 'PreSnapshot', 'ExpandDisk', 'Upgrade', 'Verify')][string]$Step,
        [switch]$Confirmed,
        [switch]$Override,
        [string]$OverrideReason,
        [ValidateSet('Sent', 'Later', 'Bypass')][string]$Contact
    )
    $def   = Get-VmmWorkflowDefinition
    $sd    = $def | Where-Object Name -eq $Step
    $store = Read-VmmStore
    $rec   = Get-VmmHostRecord -Store $store -Name $HostName
    $name  = $rec.Name

    # Order: every earlier step finished
    foreach ($e in $def | Where-Object { $_.Order -lt $sd.Order }) {
        $st = $rec.Steps.PSObject.Properties[$e.Name]
        if (-not $st -or $st.Value.Status -notin 'Success', 'NotNeeded', 'Skipped') {
            throw (New-VmmErrorRecord -Activity "Cannot run $Step on $name yet." -Target $name `
                -Cause "Step $($e.Order) '$($e.Name)' is $(if ($st) { $st.Value.Status } else { 'not done' })." `
                -Fix "Run $($e.Name) first (vmm step -HostName $name -Step $($e.Name))." -Category InvalidOperation -ErrorId 'VmmStepOrder')
        }
    }
    Assert-VmmWindow -Class $sd.Class -Target "$name/$Step" -Override:$Override -OverrideReason $OverrideReason

    $isAzure = [bool]$rec.Azure
    $guided  = $sd.Mode -eq 'Guided' -or ($sd.Mode -eq 'Hybrid' -and -not $isAzure)
    if ($Step -eq 'Upgrade' -and $isAzure -and (Get-VmmSetting 'Upgrade.Mode' -Default 'Guided') -eq 'RunCommand') { $guided = $false }
    if ($guided -and -not $Confirmed) {
        throw (New-VmmErrorRecord -Activity "$Step on $name is a guided step." -Target $name `
            -Cause $(if ($sd.Mode -eq 'Hybrid') { "$name is not an Azure VM ($($rec.Platform)), so the tool cannot do this itself." } else { 'This step is done by you in RDP/RDM.' }) `
            -Fix "Follow: vmm guide -HostName $name -Step $Step   then confirm with -Confirmed (G and Y keys in the console)." `
            -Category InvalidOperation -ErrorId 'VmmGuided')
    }

    Write-VmmLog "[$name] $Step - $($sd.Title)" -Level Info
    $status = 'Success'; $note = ''; $snap = $null
    try {
        switch ($Step) {
            'Precheck' {
                $r = @(Invoke-VmmFleetCheck -Name $name -Azure:([bool](Get-VmmSetting 'Azure.TenantId')) -PassThru -Quiet)[0]
                $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
                if ($r.Reachable -ne 'Yes') { throw "Host not reachable over WMI: $($r.Error)" }
                if (-not $rec.Baseline) { $rec.Baseline = [pscustomobject]@{ OS = $r.OS; Build = $r.Build; Sql = $r.Sql } }
                $note = "$($r.OS) build $($r.Build), C: $($r.CFreeGB) GB free, SQL: $($r.Sql), reboot pending: $($r.PendingReboot)"
                if ($r.PendingReboot -eq 'Yes') { $note += ' - REBOOT PENDING: reboot in the maintenance window before upgrading' }
            }
            'Stage' {
                $files = @(Copy-VmmStagingPackage -HostName $name)
                $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
                $note = "Staged: $($files -join ', ')"
            }
            'PreSnapshot' {
                if ($isAzure) {
                    $s = @(New-VmmSnapshot -VMName $rec.Azure.VMName -Subscription $rec.Azure.SubscriptionId -Label 'pre' -PassThru -Confirm:$false)
                    if (-not $s) { throw 'No snapshot was created - see the errors above.' }
                    $snap = ($s | ForEach-Object { $_.Snapshot }) -join ', '
                    $note = "$($s.Count) disk snapshot(s)"
                } else { $note = "Backup/snapshot confirmed by operator on $($rec.Platform)" }
                $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
            }
            'ExpandDisk' {
                $ok = [double](Get-VmmSetting 'Lansweeper.OkGB' -Default 40)
                $free = if ($rec.Check) { [double]$rec.Check.CFreeGB } else { $null }
                if ($null -ne $free -and $free -ge $ok) { $status = 'NotNeeded'; $note = "C: has $free GB free (>= $ok GB)" }
                elseif ($isAzure) {
                    $res = @(Expand-VmmOsDisk -ComputerName $rec.Azure.VMName -Apply -Confirm:$false -PassThru -Override:$Override -OverrideReason $OverrideReason)
                    $row = $res | Select-Object -First 1
                    if (-not $row -or $row.Status -ne 'Complete') { throw "Disk expansion ended as '$($row.Status)': $($row.Notes)" }
                    $note = "OS disk $($row.CurrentGB)->$($row.NewGB) GB, C: $($row.CBeforeGB)->$($row.CAfterGB) GB"
                } else { $note = 'Grown and extended by operator (guided)' }
                $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
            }
            'Upgrade' {
                if ($guided) { $note = 'Upgrade run by operator in RDP/RDM (guided)' }
                else {
                    $cmd = Get-VmmSetting 'Upgrade.CommandLine' -Required
                    $script = "Start-Process -FilePath cmd.exe -ArgumentList '/c $($cmd -replace "'", "''")' -WindowStyle Hidden; 'LAUNCHED'"
                    Set-VmmSubscription -Subscription $rec.Azure.SubscriptionId
                    $out = Invoke-AzVMRunCommand -ResourceGroupName $rec.Azure.ResourceGroup -VMName $rec.Azure.VMName -CommandId 'RunPowerShellScript' -ScriptString $script -ErrorAction Stop
                    if (($out.Value | ForEach-Object Message) -notmatch 'LAUNCHED') { throw 'Run Command did not confirm the launch.' }
                    $status = 'Launched'; $note = 'Upgrade launched via Run Command; run Verify when the VM is back'
                }
            }
            'Verify' {
                $r = @(Invoke-VmmFleetCheck -Name $name -PassThru -Quiet)[0]
                $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
                if ($r.Reachable -ne 'Yes') { throw "Host not reachable after the change: $($r.Error)" }
                $expect = Get-VmmSetting 'Upgrade.ExpectedOs' -Default ''
                if ($expect -and $r.OS -notlike $expect) { throw "OS is '$($r.OS)', expected '$expect'. Upgrade not finished or rolled back." }
                if (-not $expect -and $rec.Baseline -and $r.Build -eq $rec.Baseline.Build) { $note = 'WARNING: build unchanged since Precheck. ' }
                $note += "$($r.OS) build $($r.Build), C: $($r.CFreeGB) GB free, SQL: $($r.Sql)"
            }
        }
    } catch {
        $msg = Protect-VmmLogText (($_.Exception.Message -replace '\s+', ' ').Trim())
        $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
        if (Get-VmmAccessRequirement -Message $msg -Target $name) {
            Write-VmmLog "[$name] $Step blocked by missing access: $msg" -Level Error
            $p = @{ HostName = $name; Step = $Step; Message = $msg }
            if ($Contact) { $p.Contact = $Contact }
            [void](New-VmmBlockerReport @p)
            return
        }
        Set-VmmStepState -Record $rec -Step $Step -Status 'Failed' -Note $msg
        Save-VmmStore -Store $store
        Write-VmmLog "[$name] $Step FAILED: $msg" -Level Error
        Write-VmmLog "Options: retry, follow the RDP guide (vmm guide -HostName $name -Step $Step), or raise a blocker report and move on." -Level Info
        return
    }

    # Checkpoint snapshot after a successful step (Azure VMs only)
    $policy = Get-VmmSetting 'Workflow.SnapshotAfter' -Default 'ChangingSteps'
    $wantCp = $status -eq 'Success' -and $isAzure -and $Step -ne 'PreSnapshot' -and
              (($policy -eq 'EveryStep') -or ($policy -eq 'ChangingSteps' -and $sd.Changes))
    if ($wantCp) {
        try {
            $days = [string](Get-VmmSetting 'Workflow.CheckpointRetentionDays' -Default 7)
            $cp = @(New-VmmSnapshot -VMName $rec.Azure.VMName -Subscription $rec.Azure.SubscriptionId -Label "cp-$Step" `
                    -ExtraTags @{ Checkpoint = $Step; RetentionDays = $days } -PassThru -Confirm:$false)
            if ($cp) { $snap = ($cp | ForEach-Object { $_.Snapshot }) -join ', '; $note += " | checkpoint: $($cp.Count) snapshot(s)" }
            else { $note += ' | CHECKPOINT FAILED - see log' }
        } catch { $note += " | CHECKPOINT FAILED: $($_.Exception.Message.Split([Environment]::NewLine)[0])" }
        $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
    } elseif ($status -eq 'Success' -and -not $isAzure -and $sd.Changes -and $policy -ne 'Off') {
        $note += ' | no automatic checkpoint (not Azure) - take one in the platform console if needed'
    }

    Set-VmmStepState -Record $rec -Step $Step -Status $status -Note $note -Snapshot $snap
    Save-VmmStore -Store $store
    $lvl = if ($status -in 'Success', 'NotNeeded', 'Launched') { 'Success' } else { 'Warn' }
    Write-VmmLog "[$name] $Step = $status. $note" -Level $lvl
}
