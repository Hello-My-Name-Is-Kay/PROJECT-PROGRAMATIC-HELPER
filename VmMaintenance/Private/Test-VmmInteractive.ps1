function Test-VmmInteractive {
    # True when someone can answer a prompt: an interactive session, not started with -NonInteractive,
    # and not switched off for tests/automation ($script:VmmNonInteractive).
    [CmdletBinding()]
    param()
    if ($script:VmmNonInteractive) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if (@([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' }).Count) { return $false }
    $true
}
