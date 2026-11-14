<#
.SYNOPSIS
    Creates the Windows Server upgrade-media disk from the marketplace image and attaches it to each VM.
.DESCRIPTION
    Thin entry point for Mount-VmmUpgradeMedia (see: Get-Help Mount-VmmUpgradeMedia -Full after importing the module).
    Settings come from your local config; any parameter given here overrides it.
.EXAMPLE
    .\AzureMountISO.ps1 -WhatIf
.EXAMPLE
    .\AzureMountISO.ps1 -VMName vm01, vm02
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$VMName,
    [string]$ServerList,
    [string]$ResourceGroup,
    [int]$Lun,
    [string]$ConfigPath   # optional: a specific config file instead of the default search
)
. (Join-Path $PSScriptRoot '_Bootstrap.ps1')
[void]$PSBoundParameters.Remove('ConfigPath')

try { Mount-VmmUpgradeMedia @PSBoundParameters }
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.FullyQualifiedErrorId -notlike 'Vmm*') {
        Write-Host "  At     : $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    }
    exit 1
}
