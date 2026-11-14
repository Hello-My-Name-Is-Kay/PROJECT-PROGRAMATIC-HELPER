function Get-VmmVmPlatform {
    # VM platform from Lansweeper data only. Manufacturer/model first; the primary NIC's MAC prefix
    # tells Azure from on-prem Hyper-V (both report "Virtual Machine").
    # "(MAC only)" = manufacturer/model said nothing, only the MAC was used.
    [CmdletBinding()]
    param($Manufacturer, $Model, $Mac)

    $ouiAzure  = @('000D3A', '002248', '6045BD', '7C1E52')   # Microsoft prefixes used by Azure
    $ouiHyperV = @('00155D')                                 # on-prem Hyper-V
    $ouiVMware = @('005056', '000C29', '000569', '001C14')   # VMware

    $mfr = "$Manufacturer".Trim()
    $mdl = "$Model".Trim()
    $hex = ("$Mac" -replace '[^0-9A-Fa-f]', '').ToUpper()
    $oui = if ($hex.Length -ge 6) { $hex.Substring(0, 6) } else { '' }

    # 1. Manufacturer/model is the most reliable signal
    if ($mfr -like 'VMware*' -or $mdl -like 'VMware*') { return 'VMware' }

    if ($mdl -eq 'Virtual Machine' -or ($mfr -like 'Microsoft*' -and $mdl -like '*Virtual*')) {
        if ($ouiAzure  -contains $oui) { return 'Azure' }
        if ($ouiHyperV -contains $oui) { return 'Hyper-V' }
        return 'Hyper-V or Azure'
    }

    if ($mdl -match 'KVM|QEMU|HVM domU|VirtualBox|OpenStack' -or $mfr -match 'QEMU|Xen|innotek|Red Hat|Nutanix') {
        return 'Other virtual'
    }

    # 2. No manufacturer/model clue - fall back to the MAC prefix alone
    if ($ouiVMware -contains $oui) { return 'VMware (MAC only)' }
    if ($ouiAzure  -contains $oui) { return 'Azure (MAC only)' }
    if ($ouiHyperV -contains $oui) { return 'Hyper-V (MAC only)' }

    # 3. Real hardware vendor/model with no virtual markers
    if ($mfr -or $mdl) { return 'Physical' }
    'Unknown'
}
