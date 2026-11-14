<#
.SYNOPSIS
    Pre-upgrade rollback copies: tagged snapshots of every disk of each VM.
.DESCRIPTION
    Thin entry point for New-VmmSnapshot (see: Get-Help New-VmmSnapshot -Full after importing the module).
    Settings come from your local config; any parameter given here overrides it.
.EXAMPLE
    .\CreateSnapshots.ps1 -WhatIf
.EXAMPLE
    .\CreateSnapshots.ps1 -VMName vm01, vm02
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$VMName,
    [string]$ServerList,
    [string]$OutCsv,
    [switch]$PassThru,
    [string]$ConfigPath   # optional: a specific config file instead of the default search
)
. (Join-Path $PSScriptRoot '_Bootstrap.ps1')
[void]$PSBoundParameters.Remove('ConfigPath')

try { New-VmmSnapshot @PSBoundParameters }
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.FullyQualifiedErrorId -notlike 'Vmm*') {
        Write-Host "  At     : $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    }
    exit 1
}
