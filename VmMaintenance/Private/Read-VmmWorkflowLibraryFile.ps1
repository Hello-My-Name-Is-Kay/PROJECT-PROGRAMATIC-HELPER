function Read-VmmWorkflowLibraryFile {
    # Reads a shared library file (VMMLIB1 JSON) and checks its shape. Item ids must look like vmm ids
    # (a-, wf-, kb- + hex): a library cannot replace built-in items.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try { $lib = [IO.File]::ReadAllText($Path) | ConvertFrom-Json }
    catch { throw (New-VmmErrorRecord -Activity 'The library file is not valid JSON.' -Target $Path -Exception $_.Exception -Fix 'Export it again from a vmm that has the entries.' -Category InvalidData -ErrorId 'VmmLibraryInvalid') }
    if ("$($lib.Format)" -ne 'VMMLIB1') { throw (New-VmmErrorRecord -Activity 'Not a vmm workflow library (Format VMMLIB1 missing).' -Target $Path -Fix 'Pick the file written by Export-VmmWorkflowLibrary.' -Category InvalidData -ErrorId 'VmmLibraryInvalid') }
    $okId = @{ Actions = '^a-[0-9a-f]{10}$'; Workflows = '^wf-[0-9a-f]{10}$'; Kb = '^kb-[0-9a-f]{10}$' }
    foreach ($p in 'Actions', 'Workflows', 'Kb') {
        if (-not $lib.PSObject.Properties[$p]) { $lib | Add-Member -NotePropertyName $p -NotePropertyValue @() }
        $lib.$p = @($lib.$p | Where-Object { $_ -and "$($_.Id)" -match $okId[$p] })
    }
    foreach ($a in $lib.Actions) {
        foreach ($p in 'Steps', 'Commands') { $a.$p = @($a.$p | Where-Object { $_ }) }
        if ($a.Category -notin 'ReadOnly', 'Staging', 'Change') { $a.Category = 'Change' }   # unknown = the strictest gates
        if ($a.Category -ne 'ReadOnly') { $a.RunOnHost = $false }
        $a.Builtin = $null
    }
    foreach ($w in $lib.Workflows) { $w.Steps = @($w.Steps | Where-Object { $_ }) }
    foreach ($k in $lib.Kb) { foreach ($p in 'Fix', 'Commands') { $k.$p = @($k.$p | Where-Object { $_ }) } }
    $lib
}
