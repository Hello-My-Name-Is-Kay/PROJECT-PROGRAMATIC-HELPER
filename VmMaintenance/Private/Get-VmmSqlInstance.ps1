function Get-VmmSqlInstance {
    # SQL Server instances of one host from its last check: Instance, PatchLevel, Build, Edition, Lang
    # (ENU/FRA/...). Language from the instance's own setting when the check read it, else the OS
    # install language (older checks, Extractor results).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    $c = $Record.Check
    if (-not $c -or -not $c.Sql -or "$($c.Sql)" -eq 'none') { return }
    $lcid = @{}
    if ($c.PSObject.Properties['SqlLang'] -and $c.SqlLang) {
        foreach ($p in "$($c.SqlLang)" -split ';\s*') { if ($p -match '^(.+)=(\d+)$') { $lcid[$Matches[1].Trim()] = $Matches[2] } }
    }
    $osLang = if ($c.PSObject.Properties['Lang'] -and $c.Lang) { $c.Lang } elseif ($Record.Baseline -and $Record.Baseline.PSObject.Properties['Lang']) { $Record.Baseline.Lang } else { '' }
    foreach ($part in "$($c.Sql)" -split ';\s*') {
        if ($part -notmatch '^(?<i>\S+)\s+(?<v>\d+\.\d+\.\d+(?:\.\d+)?)\s*(?<e>.*)$') { continue }
        $i = $Matches['i']
        [pscustomobject]@{
            Host = $Record.Name; Instance = $i; PatchLevel = $Matches['v']; Build = (ConvertTo-VmmSqlBuild $Matches['v'])
            Edition = $Matches['e'].Trim()
            Lang = $(if ($lcid[$i]) { ConvertTo-VmmSqlLanguage $lcid[$i] } else { ConvertTo-VmmSqlLanguage $osLang })
            LangFrom = $(if ($lcid[$i]) { 'SQL setup' } elseif ($osLang) { 'OS language' } else { 'default' })
        }
    }
}
