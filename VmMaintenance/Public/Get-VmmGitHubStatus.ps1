function Get-VmmGitHubStatus {
    <#
    .SYNOPSIS
        GitHub integration status: gh installed and signed in, repository, installed vs latest version,
        latest commit on the branch and the result of its GitHub checks, local clone state.
    .EXAMPLE
        Get-VmmGitHubStatus
    .EXAMPLE
        vmm github
    #>
    [CmdletBinding()]
    param([switch]$Quiet)
    $o = [ordered]@{ GhInstalled = $false; SignedIn = $false; Repo = ''; Branch = ''; Installed = ''; Latest = ''; UpdateAvailable = $false
        LatestCommit = ''; Checks = ''; Clone = ''; CloneBehind = $null; Notes = @() }
    $o.Installed = "$((Get-Module VmMaintenance).Version)"
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { $o.Notes += 'GitHub CLI missing: winget install GitHub.cli' }
    else {
        $o.GhInstalled = $true
        $null = Invoke-VmmGh -Arguments @('auth', 'status', '--hostname', 'github.com') -AllowFailure
        $o.SignedIn = ($LASTEXITCODE -eq 0)
        if (-not $o.SignedIn) { $o.Notes += 'Not signed in: gh auth login' }
    }
    $o.Branch = Get-VmmSetting 'GitHub.Branch' -Default 'main'
    try { $o.Repo = Get-VmmGitHubRepo } catch { $o.Notes += 'GitHub.Repo not set (vmm setup -Page GitHub)' }

    if ($o.SignedIn -and $o.Repo) {
        try {
            $man = Invoke-VmmGh -Arguments @('api', "repos/$($o.Repo)/contents/VmMaintenance/VmMaintenance.psd1?ref=$($o.Branch)", '--jq', '.content') -Activity 'Read remote version'
            $txt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($man -replace '\s', '')))
            if ($txt -match "ModuleVersion\s*=\s*'([\d\.]+)'") { $o.Latest = $Matches[1] }
            if ($o.Latest -and $o.Installed) { $o.UpdateAvailable = ([version]$o.Latest -gt [version]$o.Installed) }
        } catch { $o.Notes += 'Could not read the remote version: ' + $_.Exception.Message.Split([Environment]::NewLine)[0] }
        try {
            # JSON parsed here, not with --jq: PS 5.1 mangles embedded double quotes in native arguments
            $c = Invoke-VmmGh -Arguments @('api', "repos/$($o.Repo)/commits/$($o.Branch)") -Activity 'Read latest commit' | ConvertFrom-Json
            $o.LatestCommit = "$($c.sha.Substring(0, 7)) $(("$($c.commit.message)" -split "`n")[0])"
            $runs = Invoke-VmmGh -Arguments @('run', 'list', '-R', $o.Repo, '-b', $o.Branch, '-L', '1', '--json', 'status,conclusion,headSha') -Activity 'Read checks'
            $r = @($runs | ConvertFrom-Json)
            $o.Checks = if (-not $r) { 'none' } elseif ($r[0].status -ne 'completed') { $r[0].status } else { $r[0].conclusion }
        } catch { $o.Notes += 'Could not read commit/checks: ' + $_.Exception.Message.Split([Environment]::NewLine)[0] }
    }
    $clone = Get-VmmSourceClone -Optional
    if ($clone) {
        $o.Clone = $clone
        try {
            $null = Invoke-VmmGit -Path $clone -Arguments @('fetch', '--quiet', 'origin', $o.Branch)
            $o.CloneBehind = [int](Invoke-VmmGit -Path $clone -Arguments @('rev-list', '--count', "HEAD..origin/$($o.Branch)")).Trim()
        } catch { $o.Notes += 'Local clone: ' + $_.Exception.Message.Split([Environment]::NewLine)[0] }
    } else { $o.Notes += 'No local clone (GitHub.SourcePath): needed for update and pull requests.' }

    $s = [pscustomobject]$o
    if (-not $Quiet) {
        $s | Format-List GhInstalled, SignedIn, Repo, Branch, Installed, Latest, UpdateAvailable, LatestCommit, Checks, Clone, CloneBehind | Out-VmmHost
        foreach ($n in $s.Notes) { Write-VmmLog $n -Level Warn }
        if ($s.UpdateAvailable) { Write-VmmLog "Update available: $($s.Installed) -> $($s.Latest). Run: vmm update" -Level Info }
        return
    }
    $s
}
