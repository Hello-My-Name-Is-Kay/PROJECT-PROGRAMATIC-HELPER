<#
.SYNOPSIS
    Rollback helper: creates managed disks from a VM's OS/data disk snapshots.
.DESCRIPTION
    Thin entry point for New-VmmDiskFromSnapshot (see: Get-Help New-VmmDiskFromSnapshot -Full after importing the module).
    Settings come from your local config; any parameter given here overrides it.
.EXAMPLE
    .\Snapshot2Disk.ps1 -VMName vm01 -WhatIf
.EXAMPLE
    .\Snapshot2Disk.ps1 -VMName vm01 -ResourceGroup rg-x
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string[]]$VMName,
    [string]$ResourceGroup,
    [string]$Location,
    [string]$SkuName,
    [switch]$PassThru,
    [string]$ConfigPath   # optional: a specific config file instead of the default search
)
. (Join-Path $PSScriptRoot '_Bootstrap.ps1')
[void]$PSBoundParameters.Remove('ConfigPath')

try { New-VmmDiskFromSnapshot @PSBoundParameters }
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.FullyQualifiedErrorId -notlike 'Vmm*') {
        Write-Host "  At     : $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    }
    exit 1
}
