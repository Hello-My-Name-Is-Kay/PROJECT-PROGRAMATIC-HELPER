function ConvertTo-VmmPsd1 {
    # Serialises a hashtable to PowerShell data-file text (literal values only, keys sorted).
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$InputObject, [int]$Depth = 0)
    $pad = '    ' * $Depth
    $q = { param($s) "'" + ("$s" -replace "'", "''") + "'" }
    if ($null -eq $InputObject) { return '$null' }
    if ($InputObject -is [bool]) { if ($InputObject) { return '$true' } else { return '$false' } }
    if ($InputObject -is [int] -or $InputObject -is [long] -or $InputObject -is [double] -or $InputObject -is [decimal]) {
        return ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $InputObject))
    }
    if ($InputObject -is [string]) { return (& $q $InputObject) }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Count -eq 0) { return '@{}' }
        $lines = @('@{')
        foreach ($k in ($InputObject.Keys | Sort-Object)) {
            $key = if ("$k" -match '^[A-Za-z_][A-Za-z0-9_]*$') { "$k" } else { & $q $k }
            $lines += "$pad    $key = " + (ConvertTo-VmmPsd1 -InputObject $InputObject[$k] -Depth ($Depth + 1))
        }
        $lines += "$pad}"
        return ($lines -join [Environment]::NewLine)
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = @($InputObject)
        if (-not $items.Count) { return '@()' }
        if (@($items | Where-Object { $_ -is [System.Collections.IDictionary] }).Count) {
            $lines = @('@(')
            foreach ($i in $items) { $lines += "$pad    " + (ConvertTo-VmmPsd1 -InputObject $i -Depth ($Depth + 1)) }
            $lines += "$pad)"
            return ($lines -join [Environment]::NewLine)
        }
        return '@(' + (($items | ForEach-Object { ConvertTo-VmmPsd1 -InputObject $_ -Depth ($Depth + 1) }) -join ', ') + ')'
    }
    & $q $InputObject
}
