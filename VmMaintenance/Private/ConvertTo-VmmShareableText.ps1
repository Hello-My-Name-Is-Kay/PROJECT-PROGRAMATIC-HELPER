function ConvertTo-VmmShareableText {
    # Makes text safe for the shared library and for other technicians: the given host names and FQDNs become
    # <HOST>, IPv4 addresses <IP>, UNC server parts \\<server>, GUIDs (tenant/subscription ids) <ID>, and
    # anything that looks like a secret is masked (Protect-VmmLogText). Known fixes never carry environment values.
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Text, [string[]]$Names = @())
    if (-not $Text) { return $Text }
    $t = Protect-VmmLogText $Text
    foreach ($n in @($Names | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object Length -Descending)) {
        $t = [regex]::Replace($t, '(?i)(?<![\w-])' + [regex]::Escape($n) + '(?:\.[\w-]+)*(?![\w-])', '<HOST>')
    }
    $t = [regex]::Replace($t, '\b(?:\d{1,3}\.){3}\d{1,3}\b', '<IP>')
    $t = [regex]::Replace($t, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '<ID>')
    $t = [regex]::Replace($t, '\\\\(?!<)[^\\\s]+', '\\<server>')
    $t
}
