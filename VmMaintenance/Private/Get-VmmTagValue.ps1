function Get-VmmTagValue {
    # Case-insensitive tag lookup (Azure tag names are case-insensitive; the .NET dictionary is not).
    [CmdletBinding()]
    param([AllowNull()]$Tags, [Parameter(Mandatory)][string]$Name)
    if (-not $Tags) { return $null }
    foreach ($k in $Tags.Keys) {
        if ($k -eq $Name) { return $Tags[$k] }   # -eq on strings is case-insensitive
    }
    $null
}
