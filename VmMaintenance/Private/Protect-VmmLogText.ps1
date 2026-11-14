function Protect-VmmLogText {
    # Masks anything that looks like a secret before text reaches the console, a log, a report or the store.
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Text)
    if (-not $Text) { return $Text }
    $t = $Text
    $t = $t -replace '(?i)(password|pwd|passwd|secret|token|apikey|api_key|client_secret)\s*[=:]\s*[^;\s]+', '$1=***'
    $t = $t -replace '(?i)(Bearer\s+)[A-Za-z0-9\-\._~\+/]+=*', '$1***'
    $t = $t -replace '(?i)(sig|sv|se|sp)=[A-Za-z0-9%\-]{16,}', '$1=***'
    $t
}
