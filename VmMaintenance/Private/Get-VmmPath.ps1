function Get-VmmPath {
    # Well-known local folders, created on first use. All live in the user profile, never in the repo.
    #   Config  = %APPDATA%\VmMaintenance                 (settings, roams with the profile)
    #   Data    = %LOCALAPPDATA%\VmMaintenance\data       (encrypted fleet store + DPAPI-protected key)
    #   Reports = %LOCALAPPDATA%\VmMaintenance\Reports    (daily CSV/HTML, blocker reports - plaintext by design)
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Config', 'Data', 'Reports', 'Blockers', 'Daily', 'Agents', 'Logs')][string]$Name)
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $path = switch ($Name) {
        'Config'   { Split-Path -Path (Get-VmmDefaultConfigPath) -Parent }
        'Data'     { Get-VmmSetting 'Paths.DataDir'   -Default (Join-Path $local 'VmMaintenance\data') }
        'Reports'  { Get-VmmSetting 'Paths.ReportDir' -Default (Join-Path $local 'VmMaintenance\Reports') }
        'Blockers' { Join-Path (Get-VmmPath -Name Reports) 'Blockers' }
        'Daily'    { Join-Path (Get-VmmPath -Name Reports) 'Daily' }
        'Agents'   { Join-Path (Split-Path -Path (Get-VmmPath -Name Data) -Parent) 'agents' }   # generated host agents (short-lived)
        'Logs'     { Join-Path (Split-Path -Path (Get-VmmPath -Name Data) -Parent) 'logs' }     # sanitized error log
    }
    Resolve-VmmWorkDir -Path $path
}
