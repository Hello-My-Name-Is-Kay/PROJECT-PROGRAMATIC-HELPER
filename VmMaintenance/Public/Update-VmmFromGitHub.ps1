function Update-VmmFromGitHub {
    <#
    .SYNOPSIS
        Updates vmm from the GitHub repository: fetch, show what changed, check the GitHub checks of the new
        commit, fast-forward the local clone, run the smoke test, reinstall the module.
    .DESCRIPTION
        Safe order: nothing is installed unless the smoke test passes on the new code. A commit whose GitHub
        checks did not pass needs YES typed. If the smoke test fails, the clone is moved back to the previous
        commit. Your config, encrypted data and reports are not touched.
    .PARAMETER CheckOnly
        Show what would be updated and stop.
    .EXAMPLE
        Update-VmmFromGitHub
    .EXAMPLE
        vmm update -CheckOnly
    #>
    [CmdletBinding()]
    param([switch]$CheckOnly, [switch]$Force)
    $repo = Get-VmmGitHubRepo
    $branch = Get-VmmSetting 'GitHub.Branch' -Default 'main'
    $clone = Get-VmmSourceClone
    $dirty = Invoke-VmmGit -Path $clone -Arguments @('status', '--porcelain')
    if ($dirty.Trim()) {
        throw (New-VmmErrorRecord -Activity 'Local clone has uncommitted changes; update stopped.' -Target $clone `
            -Fix 'Commit them on a branch (and open a PR with vmm pr), or discard them, then run vmm update again.' -Category InvalidOperation -ErrorId 'VmmGhDirty')
    }
    $cur = (Invoke-VmmGit -Path $clone -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Trim()
    if ($cur -ne $branch) {
        throw (New-VmmErrorRecord -Activity "Local clone is on branch '$cur', not '$branch'." -Target $clone -Fix "git -C `"$clone`" switch $branch" -Category InvalidOperation -ErrorId 'VmmGhBranch')
    }
    Write-VmmLog "Fetching $repo ($branch)..." -Level Info
    $null = Invoke-VmmGit -Path $clone -Arguments @('fetch', '--quiet', 'origin', $branch)
    $prev = (Invoke-VmmGit -Path $clone -Arguments @('rev-parse', 'HEAD')).Trim()
    $new  = (Invoke-VmmGit -Path $clone -Arguments @('rev-parse', "origin/$branch")).Trim()
    $installed = [version]"$((Get-Module VmMaintenance).Version)"
    $man = Import-PowerShellDataFile (Join-Path $clone 'VmMaintenance\VmMaintenance.psd1')

    if ($prev -eq $new) {
        Write-VmmLog "Clone is up to date ($($new.Substring(0, 7)), version $($man.ModuleVersion)); installed: $installed." -Level Success
        if ([version]$man.ModuleVersion -le $installed -and -not $Force) { return }
    } else {
        Write-VmmLog 'New commits:' -Level Info
        Invoke-VmmGit -Path $clone -Arguments @('log', '--oneline', '--no-decorate', "HEAD..origin/$branch") | Out-Host
        Invoke-VmmGit -Path $clone -Arguments @('diff', '--stat', "HEAD..origin/$branch") | Select-Object -Last 1 | Out-Host
    }

    # GitHub checks for the commit being installed
    $check = 'unknown'
    try {
        $runs = @(Invoke-VmmGh -Arguments @('run', 'list', '-R', $repo, '-b', $branch, '-L', '10', '--json', 'headSha,status,conclusion') -Activity 'Read checks' | ConvertFrom-Json)
        $r = $runs | Where-Object { $_.headSha -eq $new } | Select-Object -First 1
        if ($r) { $check = if ($r.status -ne 'completed') { "still running ($($r.status))" } else { $r.conclusion } }
    } catch { Write-VmmLog "Could not read GitHub checks: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -Level Warn }
    if ($check -eq 'success') { Write-VmmLog 'GitHub checks: passed.' -Level Success }
    else { Write-VmmLog "GitHub checks for $($new.Substring(0, 7)): $check." -Level Warn }
    if ($CheckOnly) { return }

    if ($check -ne 'success') {
        if ((Read-VmmPrompt 'Checks did not pass (or are unknown). Type YES to install anyway') -cne 'YES') { Write-VmmLog 'Update cancelled.' -Level Muted; return }
    } elseif ((Read-VmmPrompt 'Install this update? (y/N)') -notmatch '^[yY]') { Write-VmmLog 'Update cancelled.' -Level Muted; return }

    if ($prev -ne $new) {
        $null = Invoke-VmmGit -Path $clone -Arguments @('merge', '--ff-only', "origin/$branch")
        $man = Import-PowerShellDataFile (Join-Path $clone 'VmMaintenance\VmMaintenance.psd1')
    }
    Write-VmmLog 'Running the smoke test on the new code...' -Level Info
    $rc = Invoke-VmmChildScript -Path (Join-Path $clone 'Tools\Invoke-SmokeTest.ps1')
    if ($rc -ne 0) {
        if ($prev -ne $new) { $null = Invoke-VmmGit -Path $clone -Arguments @('reset', '--keep', $prev) }
        throw (New-VmmErrorRecord -Activity 'Smoke test failed on the new version: NOT installed.' -Target $new.Substring(0, 7) `
            -Cause 'The new code does not pass the offline checks on this laptop.' `
            -Fix "The clone was moved back to $($prev.Substring(0, 7)). Report it: vmm issue -FromErrorLog" -Category InvalidResult -ErrorId 'VmmUpdateSmoke')
    }
    $rc = Invoke-VmmChildScript -Path (Join-Path $clone 'Install.ps1') -Arguments @('-Update')
    if ($rc -ne 0) { throw (New-VmmErrorRecord -Activity "Install step failed (exit $rc)." -Fix "Run: $clone\Install.ps1 -Update" -Category InvalidResult -ErrorId 'VmmUpdateInstall') }
    Write-VmmLog "Updated to $($man.ModuleVersion) ($($new.Substring(0, 7))). Close vmm and open it again to use the new version." -Level Success
}
