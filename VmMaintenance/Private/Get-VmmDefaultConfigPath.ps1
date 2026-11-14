function Get-VmmDefaultConfigPath {
    # Per-user config location, outside any repository: %APPDATA%\VmMaintenance\config.psd1
    [CmdletBinding()]
    param()
    Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'VmMaintenance\config.psd1'
}
