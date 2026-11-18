function Set-VmmTicketStep {
    # Records the result of one workflow step on a ticket (host) and saves the fleet store. Text is masked
    # (Protect-VmmLogText). Status: Success, Failed, Blocked, Skipped, Running (gate passed, work in progress),
    # Pending (a known fix was applied: do the step again).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][ValidateSet('Success', 'Failed', 'Blocked', 'Skipped', 'Running', 'Pending', 'NotNeeded')][string]$Status,
        [string]$Note = ''
    )
    $store = Read-VmmStore
    $rec = Get-VmmHostRecord -Store $store -Name $HostName
    Set-VmmStepState -Record $rec -Step $Key -Status $Status -Note $Note
    $t = Initialize-VmmTicket -Record $rec
    $t.Updated = (Get-Date).ToUniversalTime().ToString('o')
    Save-VmmStore -Store $store
    $lvl = switch ($Status) { 'Success' { 'Success' } 'NotNeeded' { 'Success' } 'Failed' { 'Error' } 'Blocked' { 'Error' } 'Skipped' { 'Warn' } default { 'Info' } }
    Write-VmmLog "$($rec.Name) / $($Key -replace '^W:', ''): $Status$(if ($Note) { " - $Note" })" -Level $lvl
}
