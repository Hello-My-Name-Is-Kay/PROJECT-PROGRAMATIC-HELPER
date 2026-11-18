function Get-VmmStepKey {
    # Where a workflow action's result lives on a host record (record.Steps): the workflow step name for the
    # built-in maintenance steps (so the fleet stage, plan and reports agree), W:<action id> for the rest.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Action)
    if ($Action.Builtin) { return "$($Action.Builtin)" }
    "W:$($Action.Id)"
}
