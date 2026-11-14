function Install-VmmSourceClone {
    <#
    .SYNOPSIS
        Clones the repository (GitHub.Repo) with the GitHub CLI and saves the folder as GitHub.SourcePath.
        The clone is what 'vmm update' pulls into and what 'vmm pr' pushes from.
    .EXAMPLE
        Install-VmmSourceClone -Path C:\Src\VmMaintenance
    .EXAMPLE
        vmm clone -Path C:\Src\VmMaintenance
    #>
    [CmdletBinding()]
    param([string]$Path = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Source\VmMaintenance'))
    $repo = Get-VmmGitHubRepo
    if (Test-Path -LiteralPath (Join-Path $Path '.git')) {
        Write-VmmLog "Already a git clone: $Path" -Level Muted
    } else {
        if ((Test-Path -LiteralPath $Path) -and @(Get-ChildItem -LiteralPath $Path -Force).Count) {
            throw (New-VmmErrorRecord -Activity 'Target folder is not empty.' -Target $Path -Fix 'Choose an empty or new folder.' -Category ResourceExists -ErrorId 'VmmGhCloneTarget')
        }
        Write-VmmLog "Cloning $repo to $Path ..." -Level Info
        $null = Invoke-VmmGh -Arguments @('repo', 'clone', $repo, $Path) -Activity 'Clone repository'
    }
    Set-VmmSetting -Name 'GitHub.SourcePath' -Value $Path | Out-Null
    Write-VmmLog "Local clone ready: $Path" -Level Success
}
