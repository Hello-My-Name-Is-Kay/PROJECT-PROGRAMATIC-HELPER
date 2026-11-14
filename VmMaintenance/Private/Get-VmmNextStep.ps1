function Get-VmmNextStep {
    # First step that is not finished (Success/NotNeeded/Skipped). $null when the host is done.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    foreach ($s in Get-VmmWorkflowDefinition) {
        $st = $Record.Steps.PSObject.Properties[$s.Name]
        if (-not $st -or $st.Value.Status -notin 'Success', 'NotNeeded', 'Skipped') { return $s }
    }
    $null
}
