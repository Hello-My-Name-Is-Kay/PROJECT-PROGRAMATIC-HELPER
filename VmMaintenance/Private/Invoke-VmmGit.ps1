function Invoke-VmmGit {
    # Runs git in the local clone (GitHub.SourcePath). Returns stdout text; throws on failure.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { throw (New-VmmErrorRecord -Activity 'git not found.' -Fix 'Install Git for Windows: winget install Git.Git' -Category ObjectNotFound -ErrorId 'VmmGitMissing') }
    $out = & $git.Source -C $Path @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0 -and -not $AllowFailure) {
        throw (New-VmmErrorRecord -Activity "git $($Arguments[0]) failed in the local clone." -Target $Path -Cause (Protect-VmmLogText ($text -replace '\s+', ' ')) `
            -Fix 'Open the folder in a terminal and run git status to see why (local changes, conflicts, no network).' -Category InvalidOperation -ErrorId 'VmmGitFailed')
    }
    $text
}
