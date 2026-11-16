function Invoke-VmmWorkflowStep {
    <#
    .SYNOPSIS
        Runs one workflow step on one host, enforcing order, the time rules, gates and the snapshot points.
    .DESCRIPTION
        Steps: Precheck, SnapStart, Stage, SnapPreSql, ExpandDisk, Upgrade, SnapPostSql, Verify, ManualCheck,
        SnapFinal (see docs\WORKFLOW.md).
        - Earlier steps must be finished first.
        - Change steps are refused in business hours unless -Override -OverrideReason (recorded).
        - Guided steps (and Hybrid steps on non-Azure hosts) need -Confirmed after you did the work in
          RDP/RDM following Get-VmmRdpGuide.
        - Four snapshot points, every disk of an Azure VM (tag SnapPoint=<step>, RetentionDays for prune):
            SnapStart   taken unless every disk already has a snapshot from the last
                        Workflow.StartSnapshotMaxAgeMinutes (60; portal snapshots count). -Decline skips it (recorded).
                        Allowed in business hours while Policy.SnapStartInBusinessHours is on.
            SnapPreSql  before the first SQL-invasive step (ExpandDisk, Upgrade). NotNeeded when a full set from
                        the last Workflow.StartSnapshotMaxAgeMinutes exists (only Stage ran since). Other platforms:
                        you confirm a backup (-Confirmed).
            SnapPostSql after the last SQL-invasive step. Always taken.
            SnapFinal   the last step, after ManualCheck. Always taken.
          Other platforms: SnapStart, SnapPostSql and SnapFinal print a reminder (NotNeeded); vmm cannot snapshot them.
        - ManualCheck: your own check after Verify. -Confirmed records it, -Bypass -BypassReason '...' (10+ chars)
          records it as Skipped with the reason.
        - An Upgrade recorded as Launched (Run Command) is finished with -Step Upgrade -Confirmed once it is done.
        - Access errors produce a blocker report and mark the step Blocked (-Contact answers the
          manager-contact question up front).
        - A failed or blocked step is recorded first, then raised as an error (VmmStepFailed / VmmStepBlocked,
          exit code 1; VPN down, lock and security errors keep their own exit codes). A change step stopped
          with Ctrl+C is recorded as Failed (INTERRUPTED) so nobody takes the old state for the truth.
          Every result is logged with its duration.
        - Stage: when the terminal copy fails (admin share closed, access denied, copy broken), vmm offers
          the hands-on handoff over RDP / RDM / RDCMan (Start-VmmRemoteHandoff) and records the step only
          when the files are verified on the host. -Handoff Ask | Always | Never (default Handoff.Offer).
    .EXAMPLE
        Invoke-VmmWorkflowStep -HostName srv01 -Step Precheck
    .EXAMPLE
        Invoke-VmmWorkflowStep -HostName srv01 -Step Upgrade -Confirmed
    .EXAMPLE
        Invoke-VmmWorkflowStep -HostName srv01 -Step ManualCheck -Bypass -BypassReason 'app owner checked, ticket 123'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][ValidateSet('Precheck', 'SnapStart', 'Stage', 'SnapPreSql', 'ExpandDisk', 'Upgrade', 'SnapPostSql', 'Verify', 'ManualCheck', 'SnapFinal')][string]$Step,
        [switch]$Confirmed,
        [switch]$Decline,          # SnapStart only: do not take the start snapshot (recorded as Skipped)
        [switch]$Bypass,           # ManualCheck only: skip your manual check, with -BypassReason (recorded)
        [string]$BypassReason,
        [switch]$Override,
        [string]$OverrideReason,
        [ValidateSet('Sent', 'Later', 'Bypass')][string]$Contact,
        [ValidateSet('Ask', 'Always', 'Never')][string]$Handoff
    )
    $def   = Get-VmmWorkflowDefinition
    $sd    = $def | Where-Object Name -eq $Step
    $store = Read-VmmStore
    $rec   = Get-VmmHostRecord -Store $store -Name $HostName
    $name  = $rec.Name

    # Switches that belong to one step only
    if ($Decline -and $Step -ne 'SnapStart') {
        throw (New-VmmErrorRecord -Activity '-Decline is for the start snapshot only.' -Target "$name/$Step" -Fix "Use it as: vmm step -HostName $name -Step SnapStart -Decline" -Category InvalidArgument -ErrorId 'VmmStepUsage')
    }
    if ($Bypass -and $Step -ne 'ManualCheck') {
        throw (New-VmmErrorRecord -Activity '-Bypass is for the manual check only.' -Target "$name/$Step" -Fix "Use it as: vmm step -HostName $name -Step ManualCheck -Bypass -BypassReason '<why>'" -Category InvalidArgument -ErrorId 'VmmStepUsage')
    }
    if ($Bypass -and (-not $BypassReason -or $BypassReason.Trim().Length -lt 10)) {
        throw (New-VmmErrorRecord -Activity 'Bypass refused: a reason of at least 10 characters is required.' -Target "$name/$Step" `
            -Fix "Add -BypassReason 'who checked instead, or why no check is needed'" -Category InvalidArgument -ErrorId 'VmmBypassReason')
    }

    # Order: every earlier step finished
    foreach ($e in $def | Where-Object { $_.Order -lt $sd.Order }) {
        $st = $rec.Steps.PSObject.Properties[$e.Name]
        if (-not $st -or $st.Value.Status -notin 'Success', 'NotNeeded', 'Skipped') {
            $fix = if ($st -and $st.Value.Status -eq 'Launched') { "Wait until $($e.Name) has finished on the host, then confirm it: vmm step -HostName $name -Step $($e.Name) -Confirmed" }
                   else { "Run $($e.Name) first (vmm step -HostName $name -Step $($e.Name))." }
            throw (New-VmmErrorRecord -Activity "Cannot run $Step on $name yet." -Target $name `
                -Cause "Step $($e.Order) '$($e.Name)' is $(if ($st) { $st.Value.Status } else { 'not done' })." `
                -Fix $fix -Category InvalidOperation -ErrorId 'VmmStepOrder')
        }
    }
    # OS policy: target Windows Server 2019; client OS only with an order; nothing to do on target/newer OS
    $pol = Get-VmmHostPolicy -Record $rec
    if ($sd.Class -ne 'ReadOnly' -and -not $pol.Workable) {
        throw (New-VmmErrorRecord -Activity "Policy: $Step not run on $name." -Target "$name ($($pol.Os))" -Cause $pol.Why `
            -Fix $(if ($pol.Scope -eq 'ClientOs') { "Only with orders: vmm order -HostName $name -Reason '<ticket / who approved>'" } else { 'Nothing to do; put the host on hold (H) or remove it.' }) `
            -Category PermissionDenied -ErrorId 'VmmPolicy')
    }
    foreach ($w in $pol.Warnings) { Write-VmmLog "[$name] $w" -Level Warn }
    # [SEC] Disk expansion deallocates the VM: business-hours override is refused unless Policy.ExpandDiskOverride
    $noOv = $null
    if ($Step -eq 'ExpandDisk' -and -not (Get-VmmSetting 'Policy.ExpandDiskOverride' -Default $false)) { $noOv = 'Disk expansion shuts the VM down (deallocate, resize, start): after business hours only.' }
    Assert-VmmWindow -Class $sd.Class -Target "$name/$Step" -Override:$Override -OverrideReason $OverrideReason -NoOverrideReason $noOv

    $isAzure = [bool]$rec.Azure
    $guided  = $sd.Mode -eq 'Guided' -or ($sd.Mode -eq 'Hybrid' -and -not $isAzure)
    $cur     = $rec.Steps.PSObject.Properties[$Step]
    $finishLaunched = $Step -eq 'Upgrade' -and $Confirmed -and $cur -and $cur.Value.Status -eq 'Launched'
    if ($Step -eq 'Upgrade' -and $isAzure -and (Get-VmmSetting 'Upgrade.Mode' -Default 'Guided') -eq 'RunCommand' -and -not $finishLaunched) { $guided = $false }
    if ($guided -and -not $Confirmed -and -not $Bypass) {
        throw (New-VmmErrorRecord -Activity "$Step on $name is a guided step." -Target $name `
            -Cause $(if ($sd.Mode -eq 'Hybrid') { "$name is not an Azure VM ($($rec.Platform)), so the tool cannot do this itself." } else { 'This step is done by you in RDP/RDM.' }) `
            -Fix "Follow: vmm guide -HostName $name -Step $Step   then confirm with -Confirmed (G and Y keys in the console)." `
            -Category InvalidOperation -ErrorId 'VmmGuided')
    }

    Write-VmmLog "[$name] $Step - $($sd.Title)" -Level Info
    $status = 'Success'; $note = ''; $snap = $null
    $maxAge = [int](Get-VmmSetting 'Workflow.StartSnapshotMaxAgeMinutes' -Default 60)
    $days   = [string](Get-VmmSetting 'Workflow.SnapshotRetentionDays' -Default (Get-VmmSetting 'Workflow.CheckpointRetentionDays' -Default 7))
    $snapBox = @{ Names = $null }
    # One snapshot point = every disk of the VM, named <VM>_snap-<Point>_..., tagged SnapPoint and RetentionDays
    $takeSet = {
        $s = @(New-VmmSnapshot -VMName $rec.Azure.VMName -Subscription $rec.Azure.SubscriptionId -Label ('snap-' + ($Step -replace '^Snap', '')) `
                -ExtraTags @{ SnapPoint = $Step; RetentionDays = $days } -PassThru -Confirm:$false)
        if (-not $s) { throw 'No snapshot was created - see the errors above.' }
        $snapBox.Names = ($s | ForEach-Object { $_.Snapshot }) -join ', '
        "$($s.Count) disk snapshot(s)"
    }
    # A full set of the VM from the last $maxAge minutes, from any source (vmm, script, Azure portal)
    $recentSet = {
        try {
            Assert-VmmModule -Name 'Az.Accounts', 'Az.Compute'
            Connect-VmmAzure -TenantId (Get-VmmSetting 'Azure.TenantId') -Subscription $rec.Azure.SubscriptionId
            Get-VmmRecentSnapshotSet -VMName $rec.Azure.VMName -Subscription $rec.Azure.SubscriptionId -MaxAgeMinutes $maxAge
        } catch {
            Write-VmmLog "[$name] could not list recent snapshots ($((("$($_.Exception.Message)" -split "`r?`n")[0]).Trim())): a new set is taken." -Level Warn
            $null
        }
    }
    $recentText = { param($r) "every disk ($($r.Disks)) has a snapshot from the last $($r.MaxAgeMinutes) min (newest $($r.Newest.ToString('yyyy-MM-dd HH:mm')) UTC: $($r.Snapshots -join ', '))" }
    $notAzure = "Not an Azure VM ($($rec.Platform)): vmm cannot snapshot it. Take one in the platform console if you want this point."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $phase = 'run'        # run -> record
    $recorded = $false    # the result is in the store
    $ended = $false       # stays $false only when Ctrl+C stopped the step (catch blocks do not run then, finally does)
    try {
        try {
            switch ($Step) {
                'Precheck' {
                    $r = @(Invoke-VmmFleetCheck -Name $name -Azure:([bool](Get-VmmSetting 'Azure.TenantId')) -PassThru -Quiet)[0]
                    $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
                    if ($r.Reachable -ne 'Yes') { throw "Host not reachable over WMI: $($r.Error)" }
                    if (-not $rec.Baseline) { $rec.Baseline = [pscustomobject]@{ OS = $r.OS; Lang = $r.Lang; Build = $r.Build; Sql = $r.Sql } }
                    $note = "$($r.OS) build $($r.Build), C: $($r.CFreeGB) GB free, SQL: $($r.Sql), reboot pending: $($r.PendingReboot)"
                    if ($r.PendingReboot -eq 'Yes') { $note += ' - REBOOT PENDING: reboot in the maintenance window before upgrading' }
                }
                'Stage' {
                    $via = ''
                    try { $files = @(Copy-VmmStagingPackage -HostName $name) }
                    catch {
                        # Terminal copy failed: offer the hands-on handoff, except when RDP cannot help (files
                        # missing on the share, share or VPN down, setting missing) or nobody is at the keyboard.
                        $copyErr = $_
                        $offer = if ($Handoff) { $Handoff } else { "$(Get-VmmSetting 'Handoff.Offer' -Default 'Ask')" }
                        $noHelp = "$($copyErr.FullyQualifiedErrorId)" -match 'VmmStagingGate|VmmShareUnreachable|VmmVpnDown|VmmSettingMissing|VmmInstanceLocked|VmmCredCancelled'
                        if ($noHelp -or $offer -eq 'Never' -or -not (Test-VmmInteractive)) { throw }
                        $why = (("$($copyErr.Exception.Message)" -split "`r?`n")[0]).Trim()
                        Write-VmmLog "[$name] the terminal copy failed: $why" -Level Error
                        if ($offer -ne 'Always') {
                            $a = Read-VmmPrompt 'Continue by hand over remote desktop (RDP / RDM / RDCMan)? vmm opens it, lists the files and verifies them on the host (y/N)'
                            if ("$a" -notmatch '^[yY]') { Write-VmmLog "[$name] hands-on staging declined." -Level Muted -FileOnly; throw $copyErr }
                        }
                        $h = @(Start-VmmRemoteHandoff -HostName $name -Reason $why -NoMarkStep) | Select-Object -Last 1
                        if (-not $h.Verified) { throw $copyErr }
                        $files = @($h.Files)
                        $via = " - by hand over $($h.Client), verified by $($h.VerifiedBy)"
                    }
                    $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
                    $note = "Staged: $($files -join ', ')$via"
                }
                'SnapStart' {
                    if ($Decline) { $status = 'Skipped'; $note = 'Start snapshot declined by operator' }
                    elseif (-not $isAzure) { $status = 'NotNeeded'; $note = $notAzure }
                    else {
                        $r = & $recentSet
                        if ($r -and $r.Complete) { $status = 'NotNeeded'; $note = 'Not taken: ' + (& $recentText $r) }
                        else {
                            $note = & $takeSet; $snap = $snapBox.Names
                            if ($r -and $r.Missing) { $note += " (no recent snapshot of: $($r.Missing -join ', '))" }
                        }
                    }
                    $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
                }
                'SnapPreSql' {
                    if ($isAzure) {
                        $r = & $recentSet
                        if ($r -and $r.Complete) { $status = 'NotNeeded'; $note = 'Not taken: ' + (& $recentText $r) + '; only non-changing steps ran since' }
                        else { $note = & $takeSet; $snap = $snapBox.Names }
                    } else { $note = "Backup/snapshot confirmed by operator on $($rec.Platform)" }
                    $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
                }
                { $_ -in 'SnapPostSql', 'SnapFinal' } {
                    if ($isAzure) { $note = & $takeSet; $snap = $snapBox.Names }
                    else { $status = 'NotNeeded'; $note = $notAzure }
                    $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
                }
                'ManualCheck' {
                    if ($Bypass) { $status = 'Skipped'; $note = "Manual check BYPASSED by operator: $BypassReason" }
                    else { $note = 'Manual check done and confirmed by operator' }
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
                    if ($finishLaunched) { $note = 'Launched upgrade finished, confirmed by operator' }
                    elseif ($guided) { $note = 'Upgrade run by operator in RDP/RDM (guided)' }
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
                    $expect = Get-VmmSetting 'Upgrade.ExpectedOs' -Default (Get-VmmSetting 'Policy.TargetOs' -Default '*Server 2019*')
                    if ($expect -and $r.OS -notlike $expect) { throw "OS is '$($r.OS)', expected '$expect'. Upgrade not finished or rolled back." }
                    if (-not $expect -and $rec.Baseline -and $r.Build -eq $rec.Baseline.Build) { $note = 'WARNING: build unchanged since Precheck. ' }
                    $note += "$($r.OS) build $($r.Build), C: $($r.CFreeGB) GB free, SQL: $($r.Sql)"
                }
            }
        } catch {
            $err = $_
            $msg = Protect-VmmLogText (("$($err.Exception.Message)" -replace '\s+', ' ').Trim())
            $secs = '{0:N0}' -f $sw.Elapsed.TotalSeconds
            if (Get-VmmAccessRequirement -Message $msg -Target $name) {
                Write-VmmLog "[$name] $Step = Blocked after $secs s (missing access): $msg" -Level Error
                $p = @{ HostName = $name; Step = $Step; Message = $msg }
                if ($Contact) { $p.Contact = $Contact }
                $report = @(New-VmmBlockerReport @p) | Select-Object -Last 1
                $recorded = $true
                throw (New-VmmErrorRecord -Activity "$Step on $name is blocked by missing access (recorded as Blocked)." -Target $name -Cause $msg `
                    -Fix "Send the blocker report to your manager ($([IO.Path]::GetFileName("$report"))) and move on to the next host. When access is granted: vmm resolve -HostName $name, then run $Step again." `
                    -Category PermissionDenied -ErrorId 'VmmStepBlocked')
            }
            try {
                $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
                Set-VmmStepState -Record $rec -Step $Step -Status 'Failed' -Note $msg
                Save-VmmStore -Store $store
                $recorded = $true
            } catch { Write-VmmLog "[$name] $Step failed and the failure could not be saved: $($_.Exception.Message)" -Level Error }
            Write-VmmLog "[$name] $Step = Failed after $secs s: $msg" -Level Error -FileOnly
            # VPN down, another vmm running, security checks: their own exit codes and fixes
            if ((Get-VmmExitCode -ErrorRecord $err) -ne 1) { throw $err }
            $opt = "retry (vmm step -HostName $name -Step $Step), follow the RDP guide (vmm guide -HostName $name -Step $Step)$(if ($Step -eq 'Stage') { ", copy by hand with checks (vmm handoff -HostName $name)" }), or raise a blocker report and move on"
            throw (New-VmmErrorRecord -Activity "$Step on $name FAILED (recorded as Failed)." -Target $name -Exception $err.Exception `
                -Fix "Options: $opt." -Category $err.CategoryInfo.Category -ErrorId 'VmmStepFailed')
        }
        $phase = 'record'
        Set-VmmStepState -Record $rec -Step $Step -Status $status -Note $note -Snapshot $snap
        Save-VmmStore -Store $store
        $recorded = $true
        $lvl = if ($status -in 'Success', 'NotNeeded', 'Launched') { 'Success' } else { 'Warn' }
        Write-VmmLog ("[{0}] {1} = {2} after {3:N0} s. {4}" -f $name, $Step, $status, $sw.Elapsed.TotalSeconds, $note) -Level $lvl
        $ended = $true
    } catch {
        $ended = $true
        throw
    } finally {
        if (-not $recorded) {
            # Ctrl+C (or a store that could not be saved): an honest record instead of the state from before
            $secs = '{0:N0}' -f $sw.Elapsed.TotalSeconds
            $why = if ($ended) { 'the result could not be saved' } else { 'INTERRUPTED (Ctrl+C)' }
            Add-VmmLogEntry -Text "[$name] $Step $why after $secs s: result not recorded" -Level Error
            if ($phase -ne 'run' -or $sd.Class -ne 'ReadOnly') {
                try {
                    $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $name
                    if ($phase -eq 'run') {
                        Set-VmmStepState -Record $rec -Step $Step -Status 'Failed' -Note "$why after $secs s, before the result was known: check the host before running $Step again"
                    } else {
                        Set-VmmStepState -Record $rec -Step $Step -Status $status -Note "$note | $why while recording: check it in Azure and vmm plan" -Snapshot $snap
                    }
                    Save-VmmStore -Store $store
                } catch { Add-VmmLogEntry -Text (Protect-VmmLogText "[$name] $($Step): this record could not be saved either ($($_.Exception.Message)): check the host and vmm plan") -Level Error }
            }
        }
    }
}
