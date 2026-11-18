function Format-VmmUpgradePath {
    # Text lines for one Get-VmmHostUpgradePath result: used by the host screen (N), vmm path and the report file.
    # Plain ASCII so it pastes into an e-mail as it is.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Path)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("Host $($Path.Host) [$(if ($Path.Platform) { $Path.Platform } else { 'platform unknown' })]  policy: $($Path.Policy)  |  $($Path.Workflow)")
    $l.Add("  Windows : $(if ($Path.OS) { $Path.OS } else { 'not read yet' })$(if ($Path.OsLang) { "  language $($Path.OsLang)" })$(if ($Path.Path -and $Path.Path -match '->') { "  path: $($Path.Path)" })")
    if (@($Path.Sql).Count) {
        foreach ($s in $Path.Sql) {
            $name = (@($s.Product, $s.Level, $s.Cu) | Where-Object { $_ }) -join ' '
            $l.Add(("  SQL     : {0} = {1} (build {2}) {3} {4}, language {5} ({6})" -f $s.Instance, $name, $s.Build, $s.Edition, $s.Arch, $s.Lang, $s.LangFrom))
        }
    } elseif ($Path.OS) { $l.Add('  SQL     : none') }
    foreach ($w in $Path.Warnings) { $l.Add("  WARNING : $w") }
    $l.Add("  NEXT    : $($Path.NextStep)")
    foreach ($s in $Path.Steps) {
        $l.Add(("  {0}. [{1}] {2}" -f $s.N, $s.Kind, $s.Action))
        if ($s.File) { $l.Add("       file : $($s.File)$(if ($s.Lang) { "   (language $($s.Lang))" })") }
        if ($s.Note) { $l.Add("       note : $($s.Note)") }
        if ($s.Link) { $l.Add("       ref  : $($s.Link)") }
    }
    , $l.ToArray()
}
