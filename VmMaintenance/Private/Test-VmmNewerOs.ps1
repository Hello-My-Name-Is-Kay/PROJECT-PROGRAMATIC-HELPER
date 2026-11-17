function Test-VmmNewerOs {
    # $true when a Windows Server caption/build is newer than the target pattern (Policy.TargetOs, e.g. *Server 2019*).
    # No version list to keep up to date: the year in the name decides (2022, 2025, 2028...), else the build number
    # (a Semi-Annual Channel "Windows Server Datacenter" has no year). Same rules as Test-NewerOs in the Extractor.
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Caption, [AllowEmptyString()][AllowNull()][string]$Build, [string]$Target = '*Server 2019*')
    $tb = @{ '2008' = 6002; '2008R2' = 7601; '2012' = 9200; '2012R2' = 9600; '2016' = 14393; '2019' = 17763; '2022' = 20348; '2025' = 26100 }
    if ($Target -notmatch '(20\d\d)( R2)?') { return $false }
    $ty = [int]$Matches[1]; $tr = [bool]$Matches[2]
    $os = ConvertTo-VmmOsName $Caption
    if (-not $os -or $os -notlike '*Server*' -or $os -like $Target) { return $false }
    if ($os -match 'Server (20\d\d)( R2)?') {
        $y = [int]$Matches[1]
        if ($y -ne $ty) { return ($y -gt $ty) }
        return ([bool]$Matches[2] -and -not $tr)
    }
    $b = 0; [void][int]::TryParse("$Build", [ref]$b)
    $key = "$ty$(if ($tr) { 'R2' })"
    if ($b -gt 0 -and $tb.ContainsKey($key)) { return ($b -gt $tb[$key]) }
    $false
}
