<#
.SYNOPSIS
    Read-only: subscription and up to four disks (type, size) for a list of Azure VMs.
.DESCRIPTION
    Thin entry point for Get-VmmAzureVmDisk (see: Get-Help Get-VmmAzureVmDisk -Full after importing the module).
    Settings come from your local config; any parameter given here overrides it.
.EXAMPLE
    .\Get-AzureVmDisks.ps1
.EXAMPLE
    .\Get-AzureVmDisks.ps1 -LansweeperCsv 'C:\Temp\VmMaintenance\LansweeperDiskSpace_20260101-090000.csv'
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$ServerList,
    [string]$LansweeperCsv,
    [string[]]$SubscriptionId,
    [string]$OutCsv,
    [switch]$PassThru,
    [string]$ConfigPath   # optional: a specific config file instead of the default search
)
. (Join-Path $PSScriptRoot '_Bootstrap.ps1')
[void]$PSBoundParameters.Remove('ConfigPath')

try { Get-VmmAzureVmDisk @PSBoundParameters }
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    try { & (Get-Module VmMaintenance) { param($e, $c) Write-VmmErrorLog -ErrorRecord $e -Command $c -DayLog } $_ ([IO.Path]::GetFileName($PSCommandPath)) } catch { }
    if ($_.FullyQualifiedErrorId -notlike 'Vmm*') {
        Write-Host "  At     : $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    }
    exit 1
}
