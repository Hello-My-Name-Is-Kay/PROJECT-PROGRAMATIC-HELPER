function Save-VmmStore {
    # Encrypts and writes the fleet store atomically (temp file + replace), keeping one .bak.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store)
    # One writer: takes the single-instance lock if this process does not hold it yet (throws when another
    # vmm has it), and keeps it until the command or the PowerShell session ends.
    [void](Enter-VmmInstanceLock -Owner 'module')
    $dir  = Get-VmmPath -Name Data
    $file = Join-Path $dir 'fleet.vmm'
    $Store.Updated = (Get-Date).ToUniversalTime().ToString('o')
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Store | ConvertTo-Json -Depth 12 -Compress))
    try { $blob = Protect-VmmBytes -Bytes $bytes } finally { [Array]::Clear($bytes, 0, $bytes.Length) }

    $tmp = "$file.tmp"
    try {
        [System.IO.File]::WriteAllBytes($tmp, $blob)
        if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination "$file.bak" -Force }
        Move-Item -LiteralPath $tmp -Destination $file -Force
    } catch {
        throw (New-VmmErrorRecord -Activity 'Could not save the fleet store.' -Target $file -Exception $_.Exception `
            -Cause 'Disk full, the file is locked by another vmm window, or no write access to the data folder.' `
            -Fix 'Close other vmm windows and retry. Check free space on the profile drive.' -Category WriteError)
    }
}
