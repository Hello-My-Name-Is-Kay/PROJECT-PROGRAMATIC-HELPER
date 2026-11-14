function Suspend-VmmConsoleInput {
    # Restores the normal console mode (for Read-Host, Get-Credential, browser sign-in).
    [CmdletBinding()]
    param()
    if ($script:VmmMouse -and ('VmmConsoleInput' -as [type])) { [VmmConsoleInput]::Restore() }
}
