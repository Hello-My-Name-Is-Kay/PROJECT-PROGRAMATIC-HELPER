function Get-VmmGitHubRepo {
    # Validated 'owner/name' from GitHub.Repo, or a clear error.
    [CmdletBinding()]
    param()
    $r = Get-VmmSetting 'GitHub.Repo' -Default ''
    if ($r -notmatch '^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$') {
        throw (New-VmmErrorRecord -Activity 'GitHub repository not set.' -Target "$r" -Fix 'Set it: vmm setup -Page GitHub   or   vmm set -Name GitHub.Repo -Value owner/name' -Category InvalidData -ErrorId 'VmmGhRepo')
    }
    $r
}
