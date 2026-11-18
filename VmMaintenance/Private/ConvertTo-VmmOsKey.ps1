function ConvertTo-VmmOsKey {
    # Windows Server caption (and build) -> the key used by Get-VmmSqlOsMatrix and the ISO names: 2008, 2008R2,
    # 2012, 2012R2, 2016, 2019, 2022, 2025. A caption without a year (Semi-Annual Channel) is placed by build.
    # '' for a client OS or text that is not a Windows Server name.
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Caption, [AllowEmptyString()][AllowNull()][string]$Build)
    $os = ConvertTo-VmmOsName $Caption
    if ($os -notlike '*Server*') { return '' }
    if ($os -match 'Server (20\d\d)( R2)?') { return "$($Matches[1])$(if ($Matches[2]) { 'R2' })" }
    $b = 0; [void][int]::TryParse("$Build", [ref]$b)
    if ($b -le 0) { return '' }
    $key = ''
    foreach ($p in (Get-VmmSqlOsMatrix).Os.GetEnumerator()) { if ($b -ge $p.Value.Build) { $key = $p.Key } }
    $key
}
