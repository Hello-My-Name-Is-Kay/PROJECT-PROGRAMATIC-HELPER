function Select-VmmTicketWorkflow {
    # Picker: which workflow this ticket follows (DEFAULT first). Returns a status line for the screen.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName)
    $cat = Get-VmmWorkflowCatalog
    $def = $cat.Workflows | Where-Object Id -eq $cat.Default | Select-Object -First 1
    $items = @([pscustomobject]@{ Id = 'default'; Name = "DEFAULT (now: $($def.Name))"; Steps = $def.Steps; Description = 'follows whatever workflow is the default' }) + @($cat.Workflows)
    $pick = Select-VmmFromList -Title "Workflow for $HostName" -Items $items -Label { param($x) '{0,-34} {1,2} steps  {2}' -f $x.Name, @($x.Steps).Count, $x.Description } `
            -Status 'Changing the workflow drops steps added or removed on this ticket; recorded results stay.'
    if (-not $pick) { return '' }
    $null = Set-VmmTicket -HostName $HostName -Workflow $pick.Id 6>$null
    "$HostName follows '$($pick.Name)'"
}
