function Get-VmmConfigCandidate {
    # Config search order: $env:VMM_CONFIG, then %APPDATA%\VmMaintenance\config.psd1,
    # then <repo>\config\config.local.psd1 (gitignored).
    [CmdletBinding()]
    param()
    $list = @()
    if ($env:VMM_CONFIG) { $list += [Environment]::ExpandEnvironmentVariables($env:VMM_CONFIG) }
    $list += Get-VmmDefaultConfigPath
    $list += Join-Path (Split-Path -Path $script:ModuleRoot -Parent) 'config\config.local.psd1'
    $list
}
