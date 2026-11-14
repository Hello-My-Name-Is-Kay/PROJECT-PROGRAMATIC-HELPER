function ConvertTo-VmmNote {
    # One-line failure text for CSV Notes columns: what failed, the error, and the likely cause/fix.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Activity,
        [Parameter(Mandatory, Position = 1)]$ErrorRecord
    )
    $ex  = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    $msg = ("$($ex.Message)" -replace '\s+', ' ').Trim()

    # Messages built by New-VmmErrorRecord already carry Cause/Fix
    if ($msg -match 'Cause  :') { return "$Activity failed: $msg" }

    $hint = Get-VmmErrorHint -Message $msg
    if ($hint) { "$Activity failed: $msg (Likely: $($hint.Cause) Fix: $($hint.Fix))" }
    else       { "$Activity failed: $msg" }
}
