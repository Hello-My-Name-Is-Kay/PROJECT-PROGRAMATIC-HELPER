function Protect-VmmDpapi {
    # Windows DPAPI, CurrentUser scope: only this Windows account on this machine can decrypt.
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $type = Get-VmmDpapiType
    $entropy = [Text.Encoding]::UTF8.GetBytes('VmMaintenance.store.v1')
    $blob = $type::Protect($Bytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return , $blob
}
