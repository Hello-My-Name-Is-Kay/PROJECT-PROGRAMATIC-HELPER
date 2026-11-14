function Start-VmmConsole {
    <#
    .SYNOPSIS
        Opens the terminal UI (keyboard + mouse). On exit, session credentials are disposed.
    .EXAMPLE
        Start-VmmConsole     # or just: vmm
    #>
    [CmdletBinding()]
    param()
    if ($Host.Name -ne 'ConsoleHost') {
        Write-VmmLog "The console UI needs a real console (Windows Terminal, conhost). This host is '$($Host.Name)'. Use the CLI here: vmm help" -Level Warn
        return
    }
    if (-not (Resolve-VmmConfigPath)) {
        Write-VmmLog 'No settings found: starting the setup wizard (first run).' -Level Info
        Start-VmmSetupWizard
    }
    try { if (-not $script:VmmConfig) { Import-VmmConfig } }
    catch { Write-VmmLog $_.Exception.Message -Level Error; return }

    # Update notice (one quick GitHub call, never blocks the start)
    $script:VmmUpdateNotice = ''
    if ((Get-VmmSetting 'GitHub.CheckOnStart' -Default $true) -and (Get-VmmSetting 'GitHub.Repo' -Default '') -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        try {
            $repo = Get-VmmGitHubRepo; $br = Get-VmmSetting 'GitHub.Branch' -Default 'main'
            $c = Invoke-VmmGh -Arguments @('api', "repos/$repo/contents/VmMaintenance/VmMaintenance.psd1?ref=$br", '--jq', '.content') -Activity 'Update check'
            $t = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($c -replace '\s', '')))
            if ($t -match "ModuleVersion\s*=\s*'([\d\.]+)'" -and [version]$Matches[1] -gt (Get-Module VmMaintenance).Version) {
                $script:VmmUpdateNotice = "Update available: $($Matches[1]) - press U, then U (or: vmm update)"
            }
        } catch { }
    }
    # Extractor results copied to Desktop/Downloads are imported before the menu shows
    $script:VmmInboxNotice = ''
    if (Get-VmmSetting 'Collect.AutoImport' -Default $true) { try { Import-VmmResultInbox -Quiet | Out-Null } catch { } }
    $oldFg = [Console]::ForegroundColor; $oldBg = [Console]::BackgroundColor
    $script:VmmTuiRunning = $true
    Initialize-VmmConsoleInput
    try {
        Clear-Host
        Show-VmmMainMenu
    } finally {
        $script:VmmTuiRunning = $false
        Suspend-VmmConsoleInput
        Clear-VmmSessionCredentialStore
        [Console]::ForegroundColor = $oldFg; [Console]::BackgroundColor = $oldBg
        [Console]::CursorVisible = $true
        Clear-Host
        Write-VmmLog 'vmm closed. Session credentials cleared from memory.' -Level Success
    }
}
