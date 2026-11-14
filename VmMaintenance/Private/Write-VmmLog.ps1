function Write-VmmLog {
    # One coloured console line. Info = cyan, Success = green, Warn = yellow, Error = red,
    # Muted = dark grey (skipped/no-op), Plain = default colour. Also lands in transcripts.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][ValidateSet('Info', 'Success', 'Warn', 'Error', 'Muted', 'Plain')]
        [string]$Level = 'Plain'
    )
    $Message = Protect-VmmLogText $Message
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
        default   { Write-Host $Message }
    }
}
