function Unprotect-VmmDpapi {
    # Reverse of Protect-VmmDpapi. Fails when the blob belongs to another user/machine or the
    # user's DPAPI master key was lost (for example a password reset by an administrator).
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes, [string]$Source = 'key file')
    $type = Get-VmmDpapiType
    $entropy = [Text.Encoding]::UTF8.GetBytes('VmMaintenance.store.v1')
    try { $plain = $type::Unprotect($Bytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser) }
    catch {
        throw (New-VmmErrorRecord -Activity 'Could not decrypt the local data key.' -Target $Source -Exception $_.Exception `
            -Cause 'The key was created by another Windows account or machine, or your DPAPI master key changed (password reset by an administrator).' `
            -Fix 'Run as the Windows user who installed the tool. If the key is really lost, the fleet store cannot be recovered: run Uninstall.ps1 -RemoveData, reinstall and re-import your host list.' `
            -Category SecurityError -ErrorId 'VmmDpapi')
    }
    return , $plain
}
