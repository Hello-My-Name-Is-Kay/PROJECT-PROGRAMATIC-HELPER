function Write-VmmLog {
    # One coloured console line, also kept in the live log pane and the day's log file (Add-VmmLogEntry).
    # Success = green, Warn = orange, Error = red, Muted = grey (skipped/no-op), Info and Plain = body text,
    # Trace = live progress (time-stamped, grey; shown only while the
    # live log is on - F2 - but always written to the file). -FileOnly: file and pane, no console.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][ValidateSet('Info', 'Success', 'Warn', 'Error', 'Muted', 'Plain', 'Trace')]
        [string]$Level = 'Plain',
        [switch]$FileOnly
    )
    $Message = Protect-VmmLogText $Message
    Add-VmmLogEntry -Text $Message -Level $Level
    if ($FileOnly) { return }
    if ($Level -eq 'Trace') {
        if ($script:VmmTuiListActive -or -not (Test-VmmLogLive)) { return }   # a list screen shows it in its pane
        $Message = '[' + (Get-Date).ToString('HH:mm:ss') + '] ' + $Message
    }
    # Colour only where it carries a status: success green, warning orange, error red. Info is plain text,
    # Muted and Trace are grey. --no-color: Write-VmmColor prints plain text.
    $role = ConvertTo-VmmColorRole $Level
    switch ($Level) {
        'Warn'  { Write-VmmColor "WARNING: $Message" -Role $role }
        'Error' { Write-VmmColor "ERROR: $Message" -Role $role }
        default { Write-VmmColor $Message -Role $role }
    }
}
