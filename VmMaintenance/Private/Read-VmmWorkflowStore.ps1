function Read-VmmWorkflowStore {
    # Loads the user part of the workflow catalog (workflows.vmm in the data folder, encrypted like the fleet
    # store). Returns an empty store when none exists yet. Collections are normalised (JSON on 5.1 and 7 drop
    # empty and single arrays differently).
    [CmdletBinding()]
    param()
    $file = Join-Path (Get-VmmPath -Name Data) 'workflows.vmm'
    $store = [pscustomobject]@{ Version = 1; Updated = $null; Default = 'wf-default'; Actions = @(); Workflows = @(); Kb = @(); LibraryImported = $null }
    if (Test-Path -LiteralPath $file) {
        $plain = Unprotect-VmmBytes -Bytes ([System.IO.File]::ReadAllBytes($file)) -Source $file
        try { $store = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json }
        catch {
            throw (New-VmmErrorRecord -Activity 'Workflow store decrypted but is not valid JSON.' -Target $file -Exception $_.Exception `
                -Fix 'Restore workflows.vmm.bak next to it, or import the shared library again (workflow manager, I).' -Category InvalidData -ErrorId 'VmmWorkflowStore')
        } finally { [Array]::Clear($plain, 0, $plain.Length) }
    }
    foreach ($p in 'Default', 'LibraryImported') { if (-not $store.PSObject.Properties[$p]) { $store | Add-Member -NotePropertyName $p -NotePropertyValue $null } }
    if (-not $store.Default) { $store.Default = 'wf-default' }
    foreach ($p in 'Actions', 'Workflows', 'Kb') {
        if (-not $store.PSObject.Properties[$p]) { $store | Add-Member -NotePropertyName $p -NotePropertyValue @() }
        $store.$p = @($store.$p | Where-Object { $_ })
    }
    foreach ($a in $store.Actions) { foreach ($p in 'Steps', 'Commands') { $a.$p = @($a.$p | Where-Object { $_ }) } }
    foreach ($w in $store.Workflows) { $w.Steps = @($w.Steps | Where-Object { $_ }) }
    foreach ($k in $store.Kb) { foreach ($p in 'Fix', 'Commands') { $k.$p = @($k.$p | Where-Object { $_ }) } }
    $store
}
