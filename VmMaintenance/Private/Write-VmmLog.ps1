function Write-VmmLog {
    # One coloured console line, also kept in the live log pane and the day's log file (Add-VmmLogEntry).
    # Info = cyan, Success = green, Warn = yellow, Error = red, Muted = dark grey (skipped/no-op),
    # Plain = default colour, Trace = live progress (time-stamped, dark cyan; shown only while the
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
    if ($script:VmmFlags -and $script:VmmFlags.NoColor) {   # --no-color
        switch ($Level) { 'Warn' { Write-Host "WARNING: $Message" } 'Error' { Write-Host "ERROR: $Message" } default { Write-Host $Message } }
        return
    }
    switch ($Level) {
        'Info'    { Write-Host $Message -ForegroundColor Cyan }
        'Success' { Write-Host $Message -ForegroundColor Green }
        'Warn'    { Write-Host "WARNING: $Message" -ForegroundColor Yellow }
        'Error'   { Write-Host "ERROR: $Message" -ForegroundColor Red }
        'Muted'   { Write-Host $Message -ForegroundColor DarkGray }
        'Trace'   { Write-Host $Message -ForegroundColor DarkCyan }
        default   { Write-Host $Message }
    }
}
