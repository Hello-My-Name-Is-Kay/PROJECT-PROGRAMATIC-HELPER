function Save-VmmWorkflowStore {
    # Encrypts and writes workflows.vmm atomically (temp file + replace), keeping one .bak. Takes the
    # single-instance lock like the fleet store. Built-in items are never written: they live in code.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store)
    [void](Enter-VmmInstanceLock -Owner 'module')
    $file = Join-Path (Get-VmmPath -Name Data) 'workflows.vmm'
    $Store.Updated = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($p in 'Actions', 'Workflows', 'Kb') { $Store.$p = @($Store.$p | Where-Object { $_ -and -not ($_.PSObject.Properties['BuiltinItem'] -and $_.BuiltinItem) }) }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Store | ConvertTo-Json -Depth 8 -Compress))
    try { $blob = Protect-VmmBytes -Bytes $bytes } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
    $tmp = "$file.tmp"
    try {
        [System.IO.File]::WriteAllBytes($tmp, $blob)
        if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination "$file.bak" -Force }
        Move-Item -LiteralPath $tmp -Destination $file -Force
    } catch {
        throw (New-VmmErrorRecord -Activity 'Could not save the workflow store.' -Target $file -Exception $_.Exception `
            -Cause 'Disk full, the file is locked, or no write access to the data folder.' -Fix 'Close other vmm windows and retry.' -Category WriteError)
    }
}
