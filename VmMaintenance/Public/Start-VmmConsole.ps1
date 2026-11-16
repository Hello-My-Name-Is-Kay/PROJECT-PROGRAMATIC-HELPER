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
    # A settings file that does not load stops here with its own error (exit code 1), not a silent return
    if (-not $script:VmmConfig) { Import-VmmConfig }

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
        } catch { Write-VmmLog "Update check skipped: $(("$($_.Exception.Message)" -split "`r?`n")[0])" -Level Muted -FileOnly }
    }
    # Log: session start; one encrypted fleet store backup per day
    Write-VmmLog ("vmm {0} started (PowerShell {1}, console {2}x{3}, live log {4})" -f (Get-Module VmMaintenance).Version, $PSVersionTable.PSVersion, [Console]::WindowWidth, [Console]::WindowHeight, $(if (Test-VmmLogLive) { 'on' } else { 'off' })) -Level Muted -FileOnly
    if (Get-VmmSetting 'Maintenance.AutoBackup' -Default $true) {
        try {
            $today = 'fleet_{0}_*.vmm' -f (Get-Date).ToString('yyyyMMdd')
            if (-not (Get-ChildItem -LiteralPath (Get-VmmPath -Name Backups) -Filter $today -File -ErrorAction SilentlyContinue)) { Invoke-VmmMaintenance -Action Backup -Quiet -Confirm:$false | Out-Null }
        } catch { Write-VmmLog "Daily backup skipped: $($_.Exception.Message)" -Level Warn -FileOnly }
    }
    # Extractor results copied to Desktop/Downloads are imported before the menu shows
    $script:VmmInboxNotice = ''
    if (Get-VmmSetting 'Collect.AutoImport' -Default $true) {
        # A failed import is shown on the menu and logged, never dropped (a rejected file can mean tampering)
        try { Import-VmmResultInbox -Quiet | Out-Null }
        catch {
            $why = ("$($_.Exception.Message)" -split "`r?`n")[0]
            $script:VmmInboxNotice = "Extractor results not imported: $why (E to retry)"
            Write-VmmLog "Extractor results not imported at start: $why" -Level Warn -FileOnly
            Write-VmmErrorLog -ErrorRecord $_ -Command 'ui: import extractor results'
        }
    }
    $oldFg = [Console]::ForegroundColor; $oldBg = [Console]::BackgroundColor
    try {
        $script:VmmTuiRunning = $true
        Initialize-VmmConsoleInput
        # Theme: deep iceberg background for the whole console while vmm runs (restored on exit)
        [void](Get-VmmTheme -Refresh)
        Set-VmmConsoleBackground
        try { [Console]::BackgroundColor = [ConsoleColor]::Black; [Console]::ForegroundColor = [ConsoleColor]::Gray } catch { }
        Clear-Host
        Show-VmmMainMenu
    } finally {
        $script:VmmTuiRunning = $false
        # [SEC] first, so a console that fails to restore below can never skip it
        Clear-VmmSessionCredentialStore
        foreach ($undo in @(
                { Suspend-VmmConsoleInput },
                { Set-VmmConsoleBackground -Restore },
                { [Console]::ForegroundColor = $oldFg; [Console]::BackgroundColor = $oldBg },
                { [Console]::CursorVisible = $true },
                { Clear-Host })) {
            try { & $undo } catch { }
        }
        Write-VmmLog 'vmm closed. Session credentials cleared from memory.' -Level Success
        Write-VmmLog "Log of this session: vmm log  (file: $(try { Get-VmmPath -Name Logs } catch { '?' }))" -Level Muted
    }
}
