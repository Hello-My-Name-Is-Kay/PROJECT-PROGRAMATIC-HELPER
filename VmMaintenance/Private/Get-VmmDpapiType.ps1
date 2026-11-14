function Get-VmmDpapiType {
    # Returns [System.Security.Cryptography.ProtectedData] (Windows PowerShell 5.1 and PowerShell 7 on Windows).
    [CmdletBinding()]
    param()
    $t = 'System.Security.Cryptography.ProtectedData' -as [type]
    if (-not $t) {
        try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
        $t = 'System.Security.Cryptography.ProtectedData' -as [type]
    }
    if (-not $t) {
        throw (New-VmmErrorRecord -Activity 'Windows DPAPI is not available in this PowerShell session.' `
            -Cause 'The ProtectedData class could not be loaded (non-Windows host or a trimmed PowerShell build).' `
            -Fix 'Run the tool in Windows PowerShell 5.1 (powershell.exe) or PowerShell 7 on Windows.' `
            -Category NotImplemented -ErrorId 'VmmDpapiMissing')
    }
    $t
}
