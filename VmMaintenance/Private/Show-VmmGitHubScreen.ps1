function Show-VmmGitHubScreen {
    # GitHub menu: status, update, sign in, clone, issue, pull request. Every action uses the GitHub CLI's
    # own sign-in; vmm never sees the token.
    [CmdletBinding()]
    param()
    $items = @(
        @{ K = 'S'; T = 'Status            gh sign-in, repo, installed vs latest version, GitHub checks' }
        @{ K = 'U'; T = 'Update vmm        fetch, show changes, verify checks + smoke test, reinstall' }
        @{ K = 'A'; T = 'Sign in to GitHub gh auth login (GitHub CLI keeps the login, not vmm)' }
        @{ K = 'C'; T = 'Clone repository  local copy used for updates and pull requests' }
        @{ K = 'I'; T = 'Report an issue   from the error log or your own text (sanitized, preview)' }
        @{ K = 'P'; T = 'Pull request      from a branch of the clone, after the leak scan' }
        @{ K = 'W'; T = 'GitHub settings   repository, branch, clone folder, check on start' }
    )
    $sel = 0; $status = ''
    while ($true) {
        $rows = @($items | ForEach-Object { @{ Text = "[$($_.K)] $($_.T)"; Color = 'Gray' } })
        $r = Invoke-VmmListView -Title "GitHub - $(Get-VmmSetting 'GitHub.Repo' -Default '(repository not set)')" -Rows $rows -Selected $sel -Status $status `
             -Help 'Letter or Up/Down + Enter or click | Esc back' -Hotkeys @($items | ForEach-Object { $_.K })
        $sel = $r.Index; $status = ''
        $key = if ($r.Action -eq 'Enter') { $items[$r.Index].K } else { $r.Action }
        switch ($key) {
            'Esc' { return }
            'S' { [void](Invoke-VmmTuiAction -Title 'GitHub status' -Action { Get-VmmGitHubStatus }) }
            'U' { [void](Invoke-VmmTuiAction -Title 'Update vmm' -Action { Update-VmmFromGitHub }) }
            'A' { [void](Invoke-VmmTuiAction -Title 'GitHub sign-in' -Action {
                      if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Write-VmmLog 'GitHub CLI missing: winget install GitHub.cli (then reopen the terminal).' -Level Warn; return }
                      & gh auth login --hostname github.com --git-protocol https --web
                      & gh auth status --hostname github.com }) }
            'C' { [void](Invoke-VmmTuiAction -Title 'Clone repository' -Action {
                      $def = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Source\VmMaintenance'
                      $p = Read-VmmPrompt "Folder for the clone (Enter = $def)"
                      if (-not $p) { $p = $def }
                      Install-VmmSourceClone -Path $p }) }
            'I' { [void](Invoke-VmmTuiAction -Title 'Report an issue' -Action {
                      $fromLog = (Read-VmmPrompt 'Use the last errors from the error log? (Y/n)') -notmatch '^[nN]'
                      New-VmmGitHubIssue -FromErrorLog:$fromLog }) }
            'P' { [void](Invoke-VmmTuiAction -Title 'Pull request' -Action {
                      $nb = Read-VmmPrompt 'New branch name (Enter = use the current branch)'
                      if ($nb) { New-VmmGitHubPullRequest -NewBranch $nb -Message (Read-VmmPrompt 'Commit message for uncommitted changes (if any)') }
                      else { New-VmmGitHubPullRequest } }) }
            'W' { [void](Invoke-VmmTuiAction -Title 'GitHub settings' -Action { Start-VmmSetupWizard -Page GitHub }) }
        }
    }
}
