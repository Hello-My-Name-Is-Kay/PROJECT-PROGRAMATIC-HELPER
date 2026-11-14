<#
.SYNOPSIS
    Grows Azure VM OS disks to the next tier, extends C:, restores power state. Report only unless -Apply.
.DESCRIPTION
    Thin entry point for Expand-VmmOsDisk (see: Get-Help Expand-VmmOsDisk -Full after importing the module).
    Settings come from your local config; any parameter given here overrides it.
.EXAMPLE
    .\Expand-AzOsDisk.ps1                                 # plan only (always do this first)
.EXAMPLE
    .\Expand-AzOsDisk.ps1 -Apply                          # make changes, asks for confirmation
.EXAMPLE
    .\Expand-AzOsDisk.ps1 -Apply -ExtendOnly -ComputerName srv01, srv02
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string[]]$ComputerName,
    [string]$ServerList,
    [switch]$Apply,
    [switch]$ExtendOnly,
    [switch]$PassThru,
    [string]$ConfigPath   # optional: a specific config file instead of the default search
)
. (Join-Path $PSScriptRoot '_Bootstrap.ps1')
[void]$PSBoundParameters.Remove('ConfigPath')

try { Expand-VmmOsDisk @PSBoundParameters }
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    try { & (Get-Module VmMaintenance) { param($e, $c) Write-VmmErrorLog -ErrorRecord $e -Command $c -DayLog } $_ ([IO.Path]::GetFileName($PSCommandPath)) } catch { }
    if ($_.FullyQualifiedErrorId -notlike 'Vmm*') {
        Write-Host "  At     : $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    }
    exit 1
}
