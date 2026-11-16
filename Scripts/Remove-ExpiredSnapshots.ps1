<#
.SYNOPSIS
    Deletes tagged Azure snapshots older than their RetentionDays tag.
.DESCRIPTION
    Thin entry point for Remove-VmmExpiredSnapshot (see: Get-Help Remove-VmmExpiredSnapshot -Full after importing the module).
    Settings come from your local config; any parameter given here overrides it.
.EXAMPLE
    .\Remove-ExpiredSnapshots.ps1 -WhatIf                 # dry run
.EXAMPLE
    .\Remove-ExpiredSnapshots.ps1                         # for real
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ResourceGroup,
    [switch]$PassThru,
    [string]$ConfigPath   # optional: a specific config file instead of the default search
)
. (Join-Path $PSScriptRoot '_Bootstrap.ps1')
[void]$PSBoundParameters.Remove('ConfigPath')

Invoke-VmmEntryScript -Command 'Remove-VmmExpiredSnapshot' -Parameters $PSBoundParameters -Name ([IO.Path]::GetFileName($PSCommandPath))
