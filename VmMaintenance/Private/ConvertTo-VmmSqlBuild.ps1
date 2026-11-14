function ConvertTo-VmmSqlBuild {
    # Registry PatchLevel -> SQL Server build number as Microsoft lists it.
    # PatchLevel keeps the service pack in the 2nd part (13.2.5026.0 = 2016 SP2); the build is 13.0.5026.0.
    # SQL 2008 R2 (10.5x) keeps 10.50.
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$PatchLevel)
    if ($PatchLevel -notmatch '^\s*(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?') { return $null }
    $maj = [int]$Matches[1]; $min = [int]$Matches[2]; $b = $Matches[3]; $rev = if ($Matches[4]) { $Matches[4] } else { '0' }
    $min = if ($maj -eq 10 -and $min -ge 50) { 50 } else { 0 }
    '{0}.{1}.{2}.{3}' -f $maj, $min, $b, $rev
}
