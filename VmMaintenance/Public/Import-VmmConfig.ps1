function Import-VmmConfig {
    <#
    .SYNOPSIS
        Loads the local settings file (tenant, subscription, SQL instance, server list paths...).
    .DESCRIPTION
        Search order when -Path is not given:
          1. $env:VMM_CONFIG
          2. %APPDATA%\VmMaintenance\config.psd1      (created by Initialize-VmmConfig)
          3. <repo>\config\config.local.psd1          (gitignored)
        Public functions load the config on first use, so calling this is only needed to pick a
        specific file.
    .EXAMPLE
        Import-VmmConfig -Path 'D:\secure\vmm-prod.psd1'
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$PassThru
    )
    if ($Path) {
        $resolved = [Environment]::ExpandEnvironmentVariables($Path)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw (New-VmmErrorRecord -Activity 'Config file not found.' -Target $resolved `
                -Cause 'The path passed with -Path / -ConfigPath is wrong.' `
                -Fix 'Check the path, or run Initialize-VmmConfig to create the default one.' `
                -Category ObjectNotFound -ErrorId 'VmmConfigNotFound')
        }
    } else {
        $resolved = Resolve-VmmConfigPath
        if (-not $resolved) {
            throw (New-VmmErrorRecord -Activity 'No local config file found.' -Target ((Get-VmmConfigCandidate) -join ' ; ') `
                -Cause 'Tenant, subscription, host and SQL instance names live only in a local file that is not shipped with the toolkit.' `
                -Fix 'Run Initialize-VmmConfig (or Scripts\Initialize-Config.ps1), then edit the file it creates. Or point $env:VMM_CONFIG at your file.' `
                -Category ObjectNotFound -ErrorId 'VmmConfigNotFound')
        }
    }

    try { $data = Import-PowerShellDataFile -LiteralPath $resolved -ErrorAction Stop }
    catch {
        throw (New-VmmErrorRecord -Activity 'Could not parse the config file.' -Target $resolved -Exception $_.Exception `
            -Cause 'The file is not valid PowerShell data syntax (unbalanced quotes or braces, or code instead of literal values).' `
            -Fix "Compare it with config\config.example.psd1. Test with: Import-PowerShellDataFile -LiteralPath '$resolved'" `
            -Category ParserError -ErrorId 'VmmConfigParse')
    }

    $script:VmmConfig     = $data
    $script:VmmConfigPath = $resolved
    Write-VmmLog "Config: $resolved" -Level Muted
    if ($PassThru) { $data }
}
