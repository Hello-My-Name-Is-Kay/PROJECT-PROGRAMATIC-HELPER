<#
.SYNOPSIS
    C: size/free space, domain, IP and VM platform from the Lansweeper database, worst first.
.DESCRIPTION
    Thin entry point for Get-VmmLansweeperDiskSpace (see: Get-Help Get-VmmLansweeperDiskSpace -Full after importing the module).
    Settings come from your local config; any parameter given here overrides it.
.EXAMPLE
    .\Get-LansweeperDiskSpace.ps1
.EXAMPLE
    .\Get-LansweeperDiskSpace.ps1 -ComputerName srv01, srv02 -Credential (Get-Credential)
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$ServerList,
    [int]$CriticalGB,
    [int]$OkGB,
    [string]$OutCsv,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$PassThru,
    [string]$ConfigPath   # optional: a specific config file instead of the default search
)
. (Join-Path $PSScriptRoot '_Bootstrap.ps1')
[void]$PSBoundParameters.Remove('ConfigPath')

Invoke-VmmEntryScript -Command 'Get-VmmLansweeperDiskSpace' -Parameters $PSBoundParameters -Name ([IO.Path]::GetFileName($PSCommandPath))
