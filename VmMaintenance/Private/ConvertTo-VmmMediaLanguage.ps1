function ConvertTo-VmmMediaLanguage {
    # Normalizes a language code from a host ('fr-FR') or a file name ('FR_FR', 'ES-ES') to 'FR-FR'.
    # Empty or malformed input returns $null (caller treats that as "language unknown").
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $v = "$Value".Trim().Replace('_', '-').ToUpperInvariant()
    if ($v -match '^[A-Z]{2,3}(-[A-Z0-9]{2,8}){1,2}$') { $v } else { $null }
}
