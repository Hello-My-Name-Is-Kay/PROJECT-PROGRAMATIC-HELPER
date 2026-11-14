function Read-VmmPrompt {
    # Read-Host that works inside the TUI (console mouse mode is paused while typing).
    [CmdletBinding()]
    param([string]$Prompt = '>', [switch]$AsSecureString)
    Suspend-VmmConsoleInput
    try {
        [Console]::CursorVisible = $true
        if ($AsSecureString) { Read-Host -Prompt $Prompt -AsSecureString } else { Read-Host -Prompt $Prompt }
    } finally { Resume-VmmConsoleInput }
}
