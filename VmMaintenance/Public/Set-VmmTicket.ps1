function Set-VmmTicket {
    <#
    .SYNOPSIS
        Creates or edits a host ticket: workflow, priority, assignee, notes; -New adds the host first.
    .DESCRIPTION
        -Workflow takes a workflow name or id; 'default' (or an empty value) follows the DEFAULT workflow.
        Changing the workflow drops steps added or removed on this ticket (-KeepSteps keeps them). Step results
        already recorded stay on the host (a step shared by both workflows keeps its state).
        -ResetSteps goes back to the workflow's own step list. Nothing about credentials is stored.
    .EXAMPLE
        Set-VmmTicket -HostName srv01 -New -Workflow 'Read-only snapshot' -Priority High
    .EXAMPLE
        Set-VmmTicket -HostName srv01 -Notes 'app owner: finance team, after 18:00 only'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [switch]$New,
        [string]$Workflow,
        [ValidateSet('High', 'Normal', 'Low')][string]$Priority,
        [string]$Assignee,
        [string]$Notes,
        [switch]$ResetSteps,
        [switch]$KeepSteps
    )
    if ($New) {
        $s0 = Read-VmmStore
        $short = ($HostName.Trim() -split '\.')[0].ToUpper()
        if ($s0.Hosts | Where-Object { $_.Name -eq $short }) { Write-VmmLog "$short is already in the fleet: editing its ticket." -Level Muted }
        else { Import-VmmFleet -Name $HostName | Out-Null }
    }
    $store = Read-VmmStore
    $rec = Get-VmmHostRecord -Store $store -Name $HostName
    $t = Initialize-VmmTicket -Record $rec
    if ($PSBoundParameters.ContainsKey('Workflow')) {
        if (-not $Workflow -or $Workflow -eq 'default') { $t.Workflow = $null }
        else {
            $cat = Get-VmmWorkflowCatalog
            $wf = @($cat.Workflows | Where-Object { $_.Id -eq $Workflow -or $_.Name -eq $Workflow })
            if ($wf.Count -ne 1) {
                throw (New-VmmErrorRecord -Activity "Workflow '$Workflow' $(if ($wf.Count) { 'is ambiguous' } else { 'not found' })." `
                    -Fix "One of: $((@($cat.Workflows | ForEach-Object { "'$($_.Name)'" })) -join ', ') or 'default'. List: vmm workflows" -Category ObjectNotFound -ErrorId 'VmmWorkflowUnknown')
            }
            $t.Workflow = $wf[0].Id
        }
        if (-not $KeepSteps) { $t.Steps = $null }
    }
    if ($ResetSteps) { $t.Steps = $null }
    if ($Priority) { $t.Priority = $Priority }
    if ($PSBoundParameters.ContainsKey('Assignee')) { $t.Assignee = (Protect-VmmLogText $Assignee) }
    if ($PSBoundParameters.ContainsKey('Notes')) { $t.Notes = (Protect-VmmLogText $Notes) }
    $t.Updated = (Get-Date).ToUniversalTime().ToString('o')
    Save-VmmStore -Store $store
    Write-VmmLog "Ticket $($rec.Name) saved." -Level Success
    Get-VmmTicket -Filter $rec.Name -Store $store
}
