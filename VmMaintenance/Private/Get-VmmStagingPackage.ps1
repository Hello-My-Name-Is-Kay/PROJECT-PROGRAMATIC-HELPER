function Get-VmmStagingPackage {
    # Package definitions from Staging.Packages, filtered to those whose AppliesTo matches the host OS.
    [CmdletBinding()]
    param([AllowNull()]$Record)
    $pk = @(Get-VmmSetting 'Staging.Packages' -Required)
    foreach ($p in $pk) {
        $applies = if ($p.AppliesTo) { $p.AppliesTo } else { '*' }
        $os = if ($Record -and $Record.Check -and $Record.Check.OS) { $Record.Check.OS } else { '' }
        if (-not $Record -or $applies -eq '*' -or $os -like $applies) {
            [pscustomobject]@{ Name = $p.Name; Path = $p.Path; Sha256 = "$($p.Sha256)".ToUpper(); Source = $p.Source; AppliesTo = $applies }
        }
    }
}
