function New-VmmGitHubPullRequest {
    <#
    .SYNOPSIS
        Opens a pull request from the current branch of the local clone, after the leak scan passes.
    .DESCRIPTION
        1. The clone must be on a branch other than GitHub.Branch, with everything committed.
        2. Tools\Test-Sanitized.ps1 runs against YOUR local config and server lists: any host, IP, ID or
           other local value in the branch stops the PR. [SEC]
        3. Shows the commits and the change summary; you confirm.
        4. Pushes the branch and opens the PR with gh (draft with -Draft).
        -NewBranch name creates the branch from the current state first (uncommitted changes are committed
        with -Message).
    .EXAMPLE
        New-VmmGitHubPullRequest -Title 'Add Hyper-V checkpoint support'
    .EXAMPLE
        vmm pr -NewBranch fix-staging -Message 'Fix staging hash check' -Title 'Fix staging hash check' -Draft
    #>
    [CmdletBinding()]
    param([string]$Title, [string]$Body = '', [switch]$Draft, [ValidatePattern('^[A-Za-z0-9._/-]{1,80}$')][string]$NewBranch, [string]$Message)
    $repo = Get-VmmGitHubRepo
    $base = Get-VmmSetting 'GitHub.Branch' -Default 'main'
    $clone = Get-VmmSourceClone

    if ($NewBranch) {
        $null = Invoke-VmmGit -Path $clone -Arguments @('switch', '-c', $NewBranch)
        if ((Invoke-VmmGit -Path $clone -Arguments @('status', '--porcelain')).Trim()) {
            if (-not $Message) { throw (New-VmmErrorRecord -Activity 'Uncommitted changes need a commit message.' -Fix "Add -Message 'what changed'" -Category InvalidArgument -ErrorId 'VmmGhMessage') }
            $null = Invoke-VmmGit -Path $clone -Arguments @('add', '-A')
            $null = Invoke-VmmGit -Path $clone -Arguments @('commit', '-q', '-m', ($Message -replace '"', "'"))
        }
    }
    $branch = (Invoke-VmmGit -Path $clone -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Trim()
    if ($branch -eq $base -or $branch -eq 'HEAD') {
        throw (New-VmmErrorRecord -Activity "The clone is on '$branch': a pull request needs its own branch." -Fix "vmm pr -NewBranch my-change -Message '...' -Title '...'" -Category InvalidOperation -ErrorId 'VmmGhBranch')
    }
    if ((Invoke-VmmGit -Path $clone -Arguments @('status', '--porcelain')).Trim()) {
        throw (New-VmmErrorRecord -Activity 'Uncommitted changes in the clone.' -Target $clone -Fix 'Commit them (git commit) or use -NewBranch with -Message.' -Category InvalidOperation -ErrorId 'VmmGhDirty')
    }

    Write-VmmLog 'Leak scan (your local values, GUIDs, IPs) on the branch...' -Level Info
    $rc = Invoke-VmmChildScript -Path (Join-Path $clone 'Tools\Test-Sanitized.ps1')
    if ($rc -ne 0) {
        throw (New-VmmErrorRecord -Activity 'Leak scan failed: pull request NOT created, nothing pushed.' -Target $branch `
            -Fix 'Remove the reported values from the files (they belong in your local config), commit, run vmm pr again.' -Category SecurityError -ErrorId 'VmmGhLeak')
    }

    $null = Invoke-VmmGit -Path $clone -Arguments @('fetch', '--quiet', 'origin', $base)
    $log = Invoke-VmmGit -Path $clone -Arguments @('log', '--oneline', '--no-decorate', "origin/$base..HEAD")
    if (-not $log.Trim()) { Write-VmmLog "No commits on '$branch' that are not on '$base'." -Level Warn; return }
    Write-VmmLog "Commits on $branch :" -Level Info
    Write-Host $log
    Invoke-VmmGit -Path $clone -Arguments @('diff', '--stat', "origin/$base...HEAD") | Out-VmmHost
    if (-not $Title) { $Title = Read-VmmPrompt 'Pull request title' }
    if (-not $Title) { return }
    $safeTitle = ($Title -replace '"', "'" -replace '[\r\n]+', ' ').Trim()
    if ((Read-VmmPrompt "Push '$branch' and open a $(if ($Draft) { 'draft ' })pull request into '$base'? (y/N)") -notmatch '^[yY]') { Write-VmmLog 'Cancelled - nothing pushed.' -Level Muted; return }

    $null = Invoke-VmmGit -Path $clone -Arguments @('push', '-u', 'origin', $branch)
    $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'vmm-pr-' + [guid]::NewGuid().ToString('N') + '.md')
    try {
        $text = (Protect-VmmLogText $Body) + "`n`n---`nOpened from vmm $((Get-Module VmMaintenance).Version); leak scan passed."
        [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($false)))
        $args2 = @('pr', 'create', '-R', $repo, '--base', $base, '--head', $branch, '--title', $safeTitle, '--body-file', $tmp)
        if ($Draft) { $args2 += '--draft' }
        $url = Invoke-VmmGh -Arguments $args2 -Activity 'Create pull request'
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    Write-VmmLog "Pull request: $($url.Trim())  (GitHub checks run on it automatically)" -Level Success
}
