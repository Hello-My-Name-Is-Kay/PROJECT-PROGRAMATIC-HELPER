function ConvertFrom-VmmDbNull {
    # DBNull -> $null so empty SQL fields stay empty in the output.
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()]$Value)
    if ($Value -is [System.DBNull]) { return $null }
    $Value
}
