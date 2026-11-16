function Remove-VmmExpiredSnapshot {
    <#
    .SYNOPSIS
        Deletes Azure snapshots older than their RetentionDays tag.
    .DESCRIPTION
        Only touches snapshots in -ResourceGroup whose tag <TagName> equals <TagValue>
        (config Snapshots.CleanupTagName / CleanupTagValue) AND that carry a RetentionDays tag.
        Age is counted in whole days since creation (UTC).
    .EXAMPLE
        Remove-VmmExpiredSnapshot -WhatIf        # dry run
    .EXAMPLE
        Remove-VmmExpiredSnapshot                # for real
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ResourceGroup,
        [string]$Subscription,
        [string]$TenantId,
        [string]$TagName,
        [string]$TagValue,
        [switch]$AllResourceGroups,   # whole subscription instead of one resource group
        [switch]$PassThru
    )
    if (-not $AllResourceGroups -and -not $PSBoundParameters.ContainsKey('ResourceGroup')) { $ResourceGroup = Get-VmmSetting 'Azure.ResourceGroup' -Required }
    if (-not $PSBoundParameters.ContainsKey('Subscription'))  { $Subscription  = Get-VmmSetting 'Azure.Subscription' -Required }
    if (-not $PSBoundParameters.ContainsKey('TenantId'))      { $TenantId      = Get-VmmSetting 'Azure.TenantId' }
    if (-not $PSBoundParameters.ContainsKey('TagName'))       { $TagName       = Get-VmmSetting 'Snapshots.CleanupTagName' -Default 'Project' }
    if (-not $PSBoundParameters.ContainsKey('TagValue'))      { $TagValue      = Get-VmmSetting 'Snapshots.CleanupTagValue' -Required }

    Assert-VmmModule -Name 'Az.Accounts', 'Az.Compute'
    Connect-VmmAzure -TenantId $TenantId -Subscription $Subscription

    $scope = if ($AllResourceGroups) { "subscription $Subscription" } else { "resource group $ResourceGroup" }
    try {
        $all = if ($AllResourceGroups) { @(Get-AzSnapshot -ErrorAction Stop) } else { @(Get-AzSnapshot -ResourceGroupName $ResourceGroup -ErrorAction Stop) }
    }
    catch {
        throw (New-VmmErrorRecord -Activity 'Could not list snapshots.' -Target $scope -Exception $_.Exception -Category ReadError)
    }

    $snaps = @($all | Where-Object {
        (Get-VmmTagValue -Tags $_.Tags -Name $TagName) -eq $TagValue -and (Get-VmmTagValue -Tags $_.Tags -Name 'RetentionDays')
    })
    Write-VmmLog "$($snaps.Count) of $($all.Count) snapshot(s) in $scope tagged $TagName = $TagValue with RetentionDays" -Level Info

    $now = (Get-Date).ToUniversalTime()
    $results = foreach ($s in $snaps) {
        $row = [ordered]@{ Snapshot = $s.Name; ResourceGroup = $s.ResourceGroupName; AgeDays = $null; RetentionDays = $null; Action = $null; Detail = $null }
        $raw = Get-VmmTagValue -Tags $s.Tags -Name 'RetentionDays'
        $retention = 0
        if (-not [int]::TryParse("$raw", [ref]$retention) -or $retention -lt 0) {
            $row.Action = 'Skipped'; $row.Detail = "RetentionDays tag '$raw' is not a whole number - fix the tag on the snapshot"
            Write-VmmLog "Skipped: $($s.Name) - RetentionDays tag '$raw' is not a whole number. Fix the tag on the snapshot." -Level Warn
            [pscustomobject]$row; continue
        }
        if (-not $s.TimeCreated) {
            $row.Action = 'Skipped'; $row.Detail = 'No creation time reported by Azure'
            Write-VmmLog "Skipped: $($s.Name) - Azure reports no creation time" -Level Warn
            [pscustomobject]$row; continue
        }
        # Whole days only: a 4.6-day-old snapshot is 4 days old, not 5
        $age = [int][math]::Floor(($now - $s.TimeCreated.ToUniversalTime()).TotalDays)
        $row.AgeDays = $age; $row.RetentionDays = $retention

        if ($age -ge $retention) {
            if ($PSCmdlet.ShouldProcess($s.Name, "Delete snapshot (age $age days, retention $retention)")) {
                try {
                    Remove-AzSnapshot -ResourceGroupName $s.ResourceGroupName -SnapshotName $s.Name -Force -ErrorAction Stop | Out-Null
                    $row.Action = 'Deleted'
                    Write-VmmLog "Deleted: $($s.Name)" -Level Success
                } catch {
                    $row.Action = 'Failed'; $row.Detail = ConvertTo-VmmNote -Activity 'Delete' -ErrorRecord $_
                    Write-VmmLog "Failed:  $($s.Name) - $($row.Detail)" -Level Error
                }
            } else {
                $row.Action = 'WouldDelete'
            }
        } else {
            $row.Action = 'Kept'
            Write-VmmLog "Kept:    $($s.Name) (age $age of $retention days)" -Level Muted
        }
        [pscustomobject]$row
    }

    $results = @($results)
    $count = { param($a) @($results | Where-Object Action -eq $a).Count }
    Write-VmmLog ("Deleted {0} | Would delete {1} | Kept {2} | Skipped {3} | Failed {4}" -f (& $count 'Deleted'), (& $count 'WouldDelete'), (& $count 'Kept'), (& $count 'Skipped'), (& $count 'Failed')) -Level Info
    if ($PassThru) { $results }
    $failedRows = @($results | Where-Object Action -eq 'Failed')
    if ($failedRows) {
        throw (New-VmmErrorRecord -Activity "$($failedRows.Count) expired snapshot(s) could not be deleted in $scope." -Target (@($failedRows | ForEach-Object Snapshot) -join ', ') `
            -Cause (@($failedRows | Select-Object -First 3 | ForEach-Object Detail) -join ' | ') -Fix 'See the errors above (a lock or missing rights is the usual cause), then run the prune again.' `
            -Category InvalidResult -ErrorId 'VmmPruneIncomplete')
    }
}
