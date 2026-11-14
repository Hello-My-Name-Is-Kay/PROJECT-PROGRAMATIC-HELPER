<#
.SYNOPSIS
    Detaches and deletes the upgrade-media disk from each VM, then verifies nothing is left.
.DESCRIPTION
    Thin entry point for Dismount-VmmUpgradeMedia (see: Get-Help Dismount-VmmUpgradeMedia -Full after importing the module).
    Settings come from your local config; any parameter given here overrides it.
.EXAMPLE
    .\AzureUnmountISO.ps1 -WhatIf
.EXAMPLE
    .\AzureUnmountISO.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$VMName,
    [string]$ServerList,
    [string]$ResourceGroup,
    [string]$ConfigPath   # optional: a specific config file instead of the default search
)
. (Join-Path $PSScriptRoot '_Bootstrap.ps1')
[void]$PSBoundParameters.Remove('ConfigPath')

try { Dismount-VmmUpgradeMedia @PSBoundParameters }
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.FullyQualifiedErrorId -notlike 'Vmm*') {
        Write-Host "  At     : $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    }
    exit 1
}
