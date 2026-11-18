function Read-VmmField {
    # One field of an edit dialogue: shows the current value, Enter keeps it. -Allowed limits the answer
    # (case-insensitive, returned in the listed spelling); a wrong answer is asked again.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt, [AllowEmptyString()][string]$Current = '', [string[]]$Allowed, [switch]$Required)
    while ($true) {
        $a = Read-VmmPrompt ("{0}{1}{2}" -f $Prompt, $(if ($Allowed) { " ($($Allowed -join '/'))" }), $(if ($Current) { " [$Current]" }))
        if (-not $a) { $a = $Current }
        if ($Required -and -not $a) { Write-VmmLog 'A value is required.' -Level Warn; continue }
        if ($Allowed -and $a) {
            $m = $Allowed | Where-Object { $_ -eq $a } | Select-Object -First 1
            if (-not $m) { Write-VmmLog "One of: $($Allowed -join ', ')" -Level Warn; continue }
            $a = $m
        }
        return $a
    }
}
