function New-VmmErrorRecord {
    # Builds a terminating error that says what failed, on which object, the raw error,
    # the likely cause and the fix. Cause/Fix fall back to Get-VmmErrorHint when not given.
    # Use: throw (New-VmmErrorRecord -Activity '...' -Target $x -Exception $_.Exception)
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Activity,
        [string]$Target,
        [System.Exception]$Exception,
        [string]$Cause,
        [string]$Fix,
        [System.Management.Automation.ErrorCategory]$Category = 'NotSpecified',
        [string]$ErrorId = 'VmmError'
    )
    if ($Exception -and (-not $Cause -or -not $Fix)) {
        $hint = Get-VmmErrorHint -Message $Exception.Message
        if ($hint) {
            if (-not $Cause) { $Cause = $hint.Cause }
            if (-not $Fix)   { $Fix   = $hint.Fix }
        }
    }

    $lines = @($Activity)
    if ($Target)    { $lines += "  Target : $Target" }
    if ($Exception) { $lines += "  Error  : " + ($Exception.Message -replace '\s+', ' ').Trim() }
    if ($Cause)     { $lines += "  Cause  : $Cause" }
    if ($Fix)       { $lines += "  Fix    : $Fix" }
    $text = $lines -join [Environment]::NewLine

    $ex = New-Object System.InvalidOperationException -ArgumentList $text, $Exception
    New-Object System.Management.Automation.ErrorRecord -ArgumentList $ex, $ErrorId, $Category, $Target
}
