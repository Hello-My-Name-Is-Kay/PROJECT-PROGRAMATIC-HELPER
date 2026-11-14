function Get-VmmHostStage {
    # Short state label: New, <LastStep>, Blocked:<Step>, Failed:<Step>, Done.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    $next = Get-VmmNextStep -Record $Record
    if (-not $next) { return 'Done' }
    $st = $Record.Steps.PSObject.Properties[$next.Name]
    if ($st -and $st.Value.Status -in 'Blocked', 'Failed', 'Launched') { return "$($st.Value.Status):$($next.Name)" }
    $prev = Get-VmmWorkflowDefinition | Where-Object { $_.Order -eq ($next.Order - 1) }
    if ($prev) { return "$($prev.Name) ok" }
    'New'
}
