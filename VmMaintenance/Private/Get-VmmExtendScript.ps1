function Get-VmmExtendScript {
    # Script run INSIDE the VM by Run Command. PowerShell 2.0 compatible (Server 2008 R2 and later).
    # Prints BEFORE/AFTER size of C: in GB; prints the diskpart output only when C: did not grow.
    [CmdletBinding()]
    param()
    @'
$before = [math]::Round((Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'").Size / 1GB, 1)
$f = Join-Path $env:TEMP "extend_c.txt"
"rescan", "select volume c", "extend" | Set-Content -Path $f -Encoding ASCII
$dp = diskpart /s $f 2>&1 | Out-String
Remove-Item $f -Force -ErrorAction SilentlyContinue
$after = [math]::Round((Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'").Size / 1GB, 1)
"BEFORE=$before AFTER=$after"
if ($after -le $before) { $dp }
'@
}
