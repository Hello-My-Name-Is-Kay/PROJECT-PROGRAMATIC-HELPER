function Resolve-VmmHostWorkflow {
    # The workflow a host (ticket) follows and the state of each of its steps.
    # Returns Workflow, IsDefault, Custom (steps changed on this ticket), Steps (Index, Action, Key, Status, At, Note,
    # Finished, Allowed, Why), Next (first unfinished step), Done/Total and Missing (action ids that no longer exist).
    # Allowed/Why apply the rules: client OS without orders = nothing, at/over target OS = no Change step, Change
    # only outside business hours (or OVERRIDE), Change only when every earlier step is finished.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, $Catalog, $Window, $Policy)
    if (-not $Catalog) { $Catalog = Get-VmmWorkflowCatalog }
    if (-not $Window)  { $Window = Get-VmmTimeWindow }
    if (-not $Policy)  { $Policy = Get-VmmHostPolicy -Record $Record }
    $t = Initialize-VmmTicket -Record $Record
    $wf = $null
    if ($t.Workflow) { $wf = $Catalog.Workflows | Where-Object { $_.Id -eq $t.Workflow } | Select-Object -First 1 }
    $isDefault = -not $wf
    if (-not $wf) { $wf = $Catalog.Workflows | Where-Object { $_.Id -eq $Catalog.Default } | Select-Object -First 1 }
    $custom = $null -ne $t.Steps
    $ids = if ($custom) { @($t.Steps) } else { @($wf.Steps) }
    $steps = @(); $missing = @(); $i = 0; $allEarlierDone = $true
    foreach ($id in $ids) {
        $a = $Catalog.Actions | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $a) { $missing += $id; continue }
        $i++
        $key = Get-VmmStepKey -Action $a
        $st = $Record.Steps.PSObject.Properties[$key]
        $status = if ($st) { "$($st.Value.Status)" } else { '' }
        $fin = $status -in 'Success', 'NotNeeded', 'Skipped'
        $ok = $true; $why = ''
        if ($Policy.Scope -eq 'ClientOs') { $ok = $false; $why = $Policy.Why }
        elseif ($a.Category -eq 'Change' -and $Policy.Scope -in 'AtTarget', 'NewerThanTarget') { $ok = $false; $why = $Policy.Why }
        elseif ($a.Category -eq 'Change' -and -not $allEarlierDone) { $ok = $false; $why = 'Finish the earlier steps first (a change step runs in order).' }
        elseif ($a.Category -eq 'Change' -and -not $Window.ChangesAllowed) { $ok = $false; $why = "Business hours: changes from $($Window.NextChangeAt.ToString('ddd HH:mm')) (OVERRIDE only with your manager's agreement)." }
        $steps += [pscustomobject]@{
            Index = $i; Action = $a; Key = $key; Status = $status; Finished = $fin; Allowed = $ok; Why = $why
            At = $(if ($st) { $st.Value.At }); Note = $(if ($st) { "$($st.Value.Note)" } else { '' })
        }
        if (-not $fin) { $allEarlierDone = $false }
    }
    $next = $steps | Where-Object { -not $_.Finished } | Select-Object -First 1
    [pscustomobject]@{
        Workflow = $wf; IsDefault = $isDefault; Custom = $custom; Steps = $steps; Next = $next
        Done = @($steps | Where-Object Finished).Count; Total = $steps.Count; Missing = $missing; Ticket = $t; Policy = $Policy
    }
}
