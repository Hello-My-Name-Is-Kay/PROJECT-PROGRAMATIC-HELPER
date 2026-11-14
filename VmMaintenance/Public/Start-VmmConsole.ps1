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
