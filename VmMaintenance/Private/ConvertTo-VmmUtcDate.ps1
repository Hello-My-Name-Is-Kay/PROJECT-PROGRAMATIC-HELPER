function ConvertTo-VmmUtcDate {
    # Store timestamps are ISO-8601 strings. PowerShell 7 turns them into DateTime on load; 5.1 keeps strings.
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()]$Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
