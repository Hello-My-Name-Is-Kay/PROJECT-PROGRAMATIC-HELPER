function Find-VmmPlaceholder {
    # Returns the first '<placeholder>' string found in a value (walks hashtables and arrays), or $null.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][AllowEmptyCollection()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if ($Value -match '^\s*<.+>\s*$') { return $Value }
        return $null
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) {
            $hit = Find-VmmPlaceholder -Value ([string]$k)
            if (-not $hit) { $hit = Find-VmmPlaceholder -Value $Value[$k] }
            if ($hit) { return $hit }
        }
        return $null
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            $hit = Find-VmmPlaceholder -Value $item
            if ($hit) { return $hit }
        }
    }
    $null
}
