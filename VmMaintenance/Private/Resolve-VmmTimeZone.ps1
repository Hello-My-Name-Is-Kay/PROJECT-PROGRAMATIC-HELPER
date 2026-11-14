function Resolve-VmmTimeZone {
    # Turns what a person types into a Windows time zone id. Accepts, case-insensitively:
    #   - a Windows id ('GMT Standard Time'), an IANA id on PowerShell 7 ('Europe/Lisbon')
    #   - a city/country/alias ('Lisbon', 'Portugal', 'London', 'UTC', 'WET')
    #   - any text found in the Windows display names ('Dublin', 'Madrid', 'UTC+01:00')
    # Returns @{ Id; Matches } : Id = the single match (or $null); Matches = candidates when ambiguous.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $t = $Text.Trim()
    $none = [pscustomobject]@{ Id = $null; Matches = @() }
    if (-not $t) { return $none }
    $alias = @{
        'lisbon' = 'GMT Standard Time'; 'lisboa' = 'GMT Standard Time'; 'portugal' = 'GMT Standard Time'; 'porto' = 'GMT Standard Time'
        'europe/lisbon' = 'GMT Standard Time'; 'wet' = 'GMT Standard Time'; 'west' = 'GMT Standard Time'
        'london' = 'GMT Standard Time'; 'uk' = 'GMT Standard Time'; 'europe/london' = 'GMT Standard Time'; 'dublin' = 'GMT Standard Time'; 'gmt' = 'GMT Standard Time'
        'madrid' = 'Romance Standard Time'; 'paris' = 'Romance Standard Time'; 'brussels' = 'Romance Standard Time'
        'berlin' = 'W. Europe Standard Time'; 'amsterdam' = 'W. Europe Standard Time'; 'cet' = 'W. Europe Standard Time'
        'utc' = 'UTC'; 'azores' = 'Azores Standard Time'
    }
    $all = @([TimeZoneInfo]::GetSystemTimeZones())
    if ($alias.ContainsKey($t.ToLower())) { $id = $alias[$t.ToLower()]; if ($all | Where-Object Id -eq $id) { return [pscustomobject]@{ Id = $id; Matches = @() } } }
    $exact = $all | Where-Object { $_.Id -ieq $t } | Select-Object -First 1
    if ($exact) { return [pscustomobject]@{ Id = $exact.Id; Matches = @() } }
    try { $z = [TimeZoneInfo]::FindSystemTimeZoneById($t); if ($z) { return [pscustomobject]@{ Id = $z.Id; Matches = @() } } } catch { }   # IANA ids on PS 7
    $found = @($all | Where-Object { $_.DisplayName -like "*$t*" -or $_.Id -like "*$t*" -or $_.StandardName -like "*$t*" })
    if ($found.Count -eq 1) { return [pscustomobject]@{ Id = $found[0].Id; Matches = @() } }
    [pscustomobject]@{ Id = $null; Matches = @($found | Select-Object -First 10) }
}
