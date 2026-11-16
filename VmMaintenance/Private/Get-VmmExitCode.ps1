function Get-VmmExitCode {
    # Exit code for the error that ended a vmm command or an entry script (Scripts\*.ps1), from its error id:
    # 1 error | 2 usage | 3 time window | 4 VPN down | 5 security check failed | 6 another vmm is running
    [CmdletBinding()]
    param($ErrorRecord)
    $id = "$($ErrorRecord.FullyQualifiedErrorId)"
    if ($id -like 'VmmCli*')            { return 2 }
    if ($id -like 'VmmWindowBlocked*')  { return 3 }
    if ($id -like 'VmmVpnDown*')        { return 4 }
    if ($id -like 'VmmStoreIntegrity*') { return 5 }
    if ($id -like 'VmmAgentResult*')    { return 5 }
    if ($id -like 'VmmInstanceLocked*') { return 6 }
    1
}
