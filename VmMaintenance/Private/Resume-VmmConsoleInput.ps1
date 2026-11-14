function Resume-VmmConsoleInput {
    # Re-enables mouse input after a prompt, only while the TUI is running.
    [CmdletBinding()]
    param()
    if ($script:VmmMouse -and $script:VmmTuiRunning -and ('VmmConsoleInput' -as [type])) { [void][VmmConsoleInput]::Enable() }
}
