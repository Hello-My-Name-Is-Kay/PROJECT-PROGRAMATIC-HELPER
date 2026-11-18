function Initialize-VmmTicket {
    # Every host is a ticket. Adds the ticket fields to a host record that has none (in memory; saved with the
    # next Save-VmmStore) and returns them:
    #   Workflow  workflow id, $null = the DEFAULT workflow (workflow manager, S)
    #   Steps     action ids for this host only (steps added or removed on the ticket), $null = the workflow's
    #   Priority  High | Normal | Low      Assignee  who works on it (free text)     Notes  free text
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    if (-not $Record.PSObject.Properties['Ticket'] -or -not $Record.Ticket) {
        $at = if ($Record.PSObject.Properties['AddedAt'] -and $Record.AddedAt) { $Record.AddedAt } else { (Get-Date).ToUniversalTime().ToString('o') }
        $t = [pscustomobject]@{ Workflow = $null; Steps = $null; Priority = 'Normal'; Assignee = ''; Notes = ''; Created = $at; Updated = $at }
        $Record | Add-Member -NotePropertyName Ticket -NotePropertyValue $t -Force
    }
    $t = $Record.Ticket
    foreach ($p in @{ Workflow = $null; Steps = $null; Priority = 'Normal'; Assignee = ''; Notes = ''; Created = $null; Updated = $null }.GetEnumerator()) {
        if (-not $t.PSObject.Properties[$p.Key]) { $t | Add-Member -NotePropertyName $p.Key -NotePropertyValue $p.Value }
    }
    if ($null -ne $t.Steps) { $t.Steps = @($t.Steps | Where-Object { $_ }) }
    $t
}
