function Remove-VmmFleetHost {
    <#
    .SYNOPSIS
        Removes hosts from the fleet store (their history goes with them).
    .EXAMPLE
        Remove-VmmFleetHost -Name srv01 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string[]]$Name)
    $store = Read-VmmStore
    $names = @(Read-VmmServerList -Name $Name -ListKey 'Fleet' -Case Upper)
    $keep = foreach ($h in $store.Hosts) {
        if ($names -contains $h.Name -and $PSCmdlet.ShouldProcess($h.Name, 'Remove from fleet')) { Write-VmmLog "Removed $($h.Name)" -Level Warn; continue }
        $h
    }
    $store.Hosts = @($keep)
    Save-VmmStore -Store $store
}
