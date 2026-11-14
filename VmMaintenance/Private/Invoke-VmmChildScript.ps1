function Invoke-VmmChildScript {
    # Runs a repository script in a NEW PowerShell process of the same edition (so a fresh module copy
    # is loaded) and returns its exit code. Output streams to this console.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string[]]$Arguments = @())
    if (-not (Test-Path -LiteralPath $Path)) { throw (New-VmmErrorRecord -Activity 'Script not found.' -Target $Path -Category ObjectNotFound) }
    $exe = (Get-Process -Id $PID).Path
    if ($exe -notmatch '(?i)(powershell|pwsh)\.exe$') { $exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' } }
    & $exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments
    $LASTEXITCODE
}
