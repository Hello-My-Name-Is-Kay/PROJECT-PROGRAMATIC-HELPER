function Invoke-VmmGh {
    # Runs the GitHub CLI and returns its stdout as text. Throws a specific error on failure.
    # [SEC] vmm never reads or stores the GitHub token: gh keeps its own sign-in (Windows Credential Manager).
    # Arguments are passed as an array (no string concatenation into a command line).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$Activity = 'GitHub CLI call', [switch]$AllowFailure)
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        throw (New-VmmErrorRecord -Activity 'GitHub CLI (gh) not found.' -Fix 'Install it: winget install GitHub.cli   then open a new terminal and run: gh auth login' -Category ObjectNotFound -ErrorId 'VmmGhMissing')
    }
    $out = & $gh.Source @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0 -and -not $AllowFailure) {
        $hint = 'Check the repository name (GitHub.Repo) and your access.'
        if ($text -match 'auth login|not logged|authentication') { $hint = 'Sign in once: gh auth login   (U > A in the console).' }
        elseif ($text -match 'Could not resolve|404|Not Found') { $hint = "Repository '$(Get-VmmSetting 'GitHub.Repo' -Default '')' not found or no access: check GitHub.Repo (owner/name)." }
        elseif ($text -match 'proxy|timeout|connect') { $hint = 'Network: check the VPN/proxy; github.com must be reachable.' }
        throw (New-VmmErrorRecord -Activity "$Activity failed (gh exit $code)." -Cause (Protect-VmmLogText ($text -replace '\s+', ' ')) -Fix $hint -Category ConnectionError -ErrorId 'VmmGhFailed')
    }
    $text
}
