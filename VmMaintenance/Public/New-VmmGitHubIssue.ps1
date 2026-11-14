function New-VmmGitHubIssue {
    <#
    .SYNOPSIS
        Opens a GitHub issue in the vmm repository - for example from the last errors in the local error log.
    .DESCRIPTION
        [SEC] Title and body pass the same masking as the AI assistant (secrets, IPs, shares, e-mails,
        accounts, your user name; host names become HOST01...). You see the exact text and confirm before
        it is sent. The body goes through a temporary file that is deleted afterwards.
    .PARAMETER FromErrorLog
        Uses the last -Last lines of %LOCALAPPDATA%\VmMaintenance\logs\errors.log as the body.
    .EXAMPLE
        New-VmmGitHubIssue -FromErrorLog -Last 3
    .EXAMPLE
        vmm issue -Title 'Fleet check hangs on hosts without RPC' -Body 'Steps: ...'
    #>
    [CmdletBinding()]
    param([string]$Title, [string]$Body, [switch]$FromErrorLog, [ValidateRange(1, 50)][int]$Last = 5)
    $repo = Get-VmmGitHubRepo
    if ($FromErrorLog) {
        $log = Join-Path (Get-VmmPath -Name Logs) 'errors.log'
        if (-not (Test-Path -LiteralPath $log)) { Write-VmmLog 'The error log is empty.' -Level Muted; return }
        $lines = @(Get-Content -LiteralPath $log -Tail $Last)
        if (-not $Title) { $Title = 'vmm error: ' + (($lines[-1] -split '\|')[-1]).Trim() }
        $Body = "$Body`n`nLast $($lines.Count) error log line(s):`n``````n$($lines -join "`n")`n``````"
    }
    if (-not $Title) { $Title = Read-VmmPrompt 'Issue title' }
    if (-not $Title) { return }
    if (-not $Body) { $Body = Read-VmmPrompt 'Description (what you did, what happened, what you expected)' }
    $env = "vmm $((Get-Module VmMaintenance).Version) | PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition) | Windows $([Environment]::OSVersion.Version)"
    $map = @{}
    $t = (ConvertTo-VmmAiSafeText -Text $Title -Map $map)
    $b = (ConvertTo-VmmAiSafeText -Text "$Body`n`n---`n$env`nOpened from vmm (sanitized)." -Map $t.Map)
    $safeTitle = ($t.Text -replace '"', "'" -replace '[\r\n]+', ' ').Trim()
    if ($safeTitle.Length -gt 200) { $safeTitle = $safeTitle.Substring(0, 200) }

    Write-VmmLog "This will be posted to $repo (private repo; visible to its collaborators):" -Level Info
    Write-Host "Title: $safeTitle"
    Write-VmmColor $b.Text -Role Text
    if ((Read-VmmPrompt 'Create the issue? (y/N)') -notmatch '^[yY]') { Write-VmmLog 'Not sent.' -Level Muted; return }
    $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'vmm-issue-' + [guid]::NewGuid().ToString('N') + '.md')
    try {
        [IO.File]::WriteAllText($tmp, $b.Text, (New-Object Text.UTF8Encoding($false)))
        $url = Invoke-VmmGh -Arguments @('issue', 'create', '-R', $repo, '--title', $safeTitle, '--body-file', $tmp) -Activity 'Create issue'
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    Write-VmmLog "Issue created: $($url.Trim())" -Level Success
}
