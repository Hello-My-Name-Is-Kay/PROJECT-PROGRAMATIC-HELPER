function ConvertTo-VmmSqlLevel {
    # SQL Server build (13.0.5026.0) or registry PatchLevel (13.2.5026.0) -> major version key, product name,
    # service pack number and label (RTM, SP1...), offline from Get-VmmSqlOsMatrix. The CU inside a service pack
    # needs the build list (dbatools): Get-VmmUpgradePath adds it when dbatools is installed.
    # $null for text that is not a build number.
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Build, $Matrix)
    if ($Build -notmatch '^\s*(\d+)\.(\d+)\.(\d+)') { return $null }
    $maj = [int]$Matches[1]; $min = [int]$Matches[2]; $b = [int]$Matches[3]
    $key = if ($maj -eq 10) { if ($min -ge 50) { '10.50' } else { '10.0' } } else { "$maj" }
    if (-not $Matrix) { $Matrix = Get-VmmSqlOsMatrix }
    $row = $Matrix.Sql[$key]
    $sp = 0
    if ($row) { for ($i = 0; $i -lt @($row.SpBuilds).Count; $i++) { if ($b -ge $row.SpBuilds[$i]) { $sp = $i + 1 } } }
    [pscustomobject]@{
        Key = $key
        Name = $(if ($row) { $row.Name } else { "SQL Server (version $maj, unknown to vmm)" })
        Known = [bool]$row
        Sp = $sp
        Level = $(if (-not $row -or -not @($row.SpBuilds).Count) { '' } elseif ($sp) { "SP$sp" } else { 'RTM' })
        Build = (ConvertTo-VmmSqlBuild $Build)
    }
}
