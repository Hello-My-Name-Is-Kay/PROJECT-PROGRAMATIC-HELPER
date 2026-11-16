<#
.SYNOPSIS
    Creates your local config (%APPDATA%\VmMaintenance\config.psd1) and empty server lists from the example.
.DESCRIPTION
    Thin entry point for Initialize-VmmConfig (see: Get-Help Initialize-VmmConfig -Full after importing the module).
    Settings come from your local config; any parameter given here overrides it.
.EXAMPLE
    .\Initialize-Config.ps1
    notepad "$env:APPDATA\VmMaintenance\config.psd1"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Destination,
    [switch]$Force,
    [string]$ConfigPath   # optional: a specific config file instead of the default search
)
. (Join-Path $PSScriptRoot '_Bootstrap.ps1')
[void]$PSBoundParameters.Remove('ConfigPath')

Invoke-VmmEntryScript -Command 'Initialize-VmmConfig' -Parameters $PSBoundParameters -Name ([IO.Path]::GetFileName($PSCommandPath))
