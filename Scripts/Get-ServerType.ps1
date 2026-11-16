<#
.SYNOPSIS
    Asks each server over WMI (DCOM) whether it is VMware, Azure VM, Hyper-V VM or physical, plus its OS.
.DESCRIPTION
    Thin entry point for Get-VmmServerPlatform (see: Get-Help Get-VmmServerPlatform -Full after importing the module).
    Settings come from your local config; any parameter given here overrides it.
.EXAMPLE
    .\Get-ServerType.ps1
.EXAMPLE
    .\Get-ServerType.ps1 -ComputerName srv01 -Credential (Get-Credential)
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$ServerList,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$OutCsv,
    [switch]$PassThru,
    [string]$ConfigPath   # optional: a specific config file instead of the default search
)
. (Join-Path $PSScriptRoot '_Bootstrap.ps1')
[void]$PSBoundParameters.Remove('ConfigPath')

Invoke-VmmEntryScript -Command 'Get-VmmServerPlatform' -Parameters $PSBoundParameters -Name ([IO.Path]::GetFileName($PSCommandPath))
