function Get-VmmTicketState {
    # Ticket state of a host from its resolved workflow (Resolve-VmmHostWorkflow):
    #   OnHold (H), Excluded (client OS without orders), NotNeeded (already on/over the target OS and the
    #   workflow changes things), Done, Blocked (open blocker or blocked step), Failed, InProgress, New.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)]$Resolved)
    if ($Record.Hold) { return 'OnHold' }
    $scope = $Resolved.Policy.Scope
    if ($scope -eq 'ClientOs') { return 'Excluded' }
    if ($Resolved.Total -and $Resolved.Done -ge $Resolved.Total) { return 'Done' }
    if ($scope -in 'AtTarget', 'NewerThanTarget' -and @($Resolved.Steps | Where-Object { $_.Action.Category -eq 'Change' }).Count) { return 'NotNeeded' }
    if (@($Record.Blockers | Where-Object { -not $_.Resolved }).Count -or @($Resolved.Steps | Where-Object Status -eq 'Blocked').Count) { return 'Blocked' }
    if (@($Resolved.Steps | Where-Object Status -eq 'Failed').Count) { return 'Failed' }
    if (@($Resolved.Steps | Where-Object Status).Count) { return 'InProgress' }
    'New'
}
