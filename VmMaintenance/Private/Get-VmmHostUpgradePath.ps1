function Get-VmmHostUpgradePath {
    # Upgrade path for ONE host from its last snapshot (Extractor result, fleet check or RDP collector): where
    # Windows and SQL Server are now, what blocks the way to the target OS, and the ordered steps with the exact
    # file and language for each. Read-only and offline: the data is Get-VmmSqlOsMatrix; the CU name comes from
    # the dbatools build list only when dbatools is installed and -NoBuildList is not given.
    # Order of the steps (smooth path, no unsupported state in between):
    #   1 run the snapshot        when nothing was read yet
    #   2 warn management         Server 2008 (not R2) / physical, until the notice is recorded (vmm policy -Notice)
    #   3 SQL blocker             a SQL version Microsoft does not support on the target OS: SQL upgrade/migration first
    #   4 restart                 pending reboot (blocks the SP and the OS setup)
    #   5 SQL service pack        before the first OS hop, up to the level every hop OS needs (the last SP)
    #   6 Windows in-place hop(s) ISO in the OS install language, same edition, one hop at a time
    #   7 SQL latest CU           after the last hop (language-neutral file, vmm fetch downloads it)
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [switch]$NoBuildList)
    $m = Get-VmmSqlOsMatrix
    $c = $Record.Check
    $pol = Get-VmmHostPolicy -Record $Record
    $steps = New-Object System.Collections.Generic.List[object]
    $add = {
        param($Kind, $Action, $File = '', $Lang = '', $Kb = '', $Link = '', $Note = '', [switch]$Blocking)
        $steps.Add([pscustomobject]@{ N = $steps.Count + 1; Kind = $Kind; Action = $Action; File = $File; Lang = $Lang; Kb = $Kb; Link = $Link; Note = $Note; Blocking = [bool]$Blocking })
    }
    $wfNext = Get-VmmNextStep -Record $Record
    $wfAll = @(Get-VmmWorkflowDefinition)
    $workflow = if ($wfNext) { "next workflow step $($wfNext.Order)/$($wfAll.Count) $($wfNext.Name)" } else { 'workflow finished' }
    $res = [pscustomobject]@{
        Host = $Record.Name; Platform = $Record.Platform; OS = ''; OsKey = ''; OsLang = ''; Policy = $pol.Scope; Warnings = @($pol.Warnings)
        Workflow = $workflow; Path = ''; Sql = @(); Steps = @(); NextStep = ''; CheckedAt = $(if ($c) { "$($c.CheckedAt)" } else { '' })
    }
    if (-not $c -or -not $c.OS) {
        & $add 'Snapshot' 'Read the host first: vmm snapshot, or run the Extractor on it and import the result (vmm inbox).' -Blocking
        $res.Steps = $steps.ToArray(); $res.NextStep = $steps[0].Action; return $res
    }
    $res.OS = ConvertTo-VmmOsName $c.OS
    $res.OsKey = ConvertTo-VmmOsKey -Caption $c.OS -Build $c.Build
    $osLang = if ($c.PSObject.Properties['Lang'] -and $c.Lang) { "$($c.Lang)" } else { '' }
    $res.OsLang = $osLang
    $osSqlLang = if ($osLang) { ConvertTo-VmmSqlLanguage $osLang } else { '' }
    $tPat = "$(Get-VmmSetting 'Policy.TargetOs' -Default '*Server 2019*')"
    $tKey = if ($tPat -match '(20\d\d)( R2)?') { "$($Matches[1])$(if ($Matches[2]) { 'R2' })" } else { '2019' }

    # Windows hops toward the target (none when at/above the target, client OS, or unknown)
    $hops = @()
    $reach = $true
    if ($pol.Scope -in 'InScope', 'Unknown', 'ClientOsOrdered' -and $res.OsKey -and $m.Os.Contains($res.OsKey)) {
        $k = $res.OsKey; $guard = 0
        while ($k -ne $tKey -and $guard -lt 6) {
            $n = $m.Os[$k].Next
            if (-not $n) { $reach = $false; break }
            $hops += $n; $k = $n; $guard++
        }
        if ($k -ne $tKey) { $reach = $false }
    }
    $res.Path = (@($res.OsKey) + $hops | Where-Object { $_ } | ForEach-Object { $m.Os[$_].Name -replace '^Windows Server ', '' }) -join ' -> '

    # SQL instances with their level against every hop OS
    $useBuildList = -not $NoBuildList -and [bool](Get-Command Get-DbaBuild -ErrorAction SilentlyContinue)
    $inst = foreach ($i in @(Get-VmmSqlInstance -Record $Record)) {
        $lvl = ConvertTo-VmmSqlLevel -Build $i.PatchLevel -Matrix $m
        $row = if ($lvl) { $m.Sql[$lvl.Key] } else { $null }
        $arch = if ($i.Edition -match '32-bit') { 'x86' } else { 'x64' }
        $cu = ''
        if ($useBuildList -and $lvl) { try { $cu = "$(@(Get-DbaBuild -Build $lvl.Build -EnableException)[0].CULevel)" } catch { } }
        $need = -1; $badOn = ''; $maxOs = $res.OsKey
        foreach ($h in $hops) {
            if (-not $row -or -not $row.MinSp.ContainsKey($h)) { if (-not $badOn) { $badOn = $h } ; continue }
            if (-not $badOn) { $maxOs = $h }
            if ($row.MinSp[$h] -gt $need) { $need = $row.MinSp[$h] }
        }
        [pscustomobject]@{
            Instance = $i.Instance; Product = $(if ($lvl) { $lvl.Name } else { 'unknown' }); Level = $(if ($lvl) { $lvl.Level } else { '' }); Cu = $cu
            Build = $(if ($lvl) { $lvl.Build } else { $i.PatchLevel }); Edition = ($i.Edition -replace '\s*\(32-bit\)', ''); Arch = $arch
            Lang = $i.Lang; LangFrom = $i.LangFrom; Sp = $(if ($lvl) { $lvl.Sp } else { 0 }); NeedSp = $need; BlockedOn = $badOn; MaxOs = $maxOs
            Known = [bool]($lvl -and $lvl.Known); Row = $row
        }
    }
    $inst = @($inst)
    $res.Sql = @($inst | Select-Object Instance, Product, Level, Cu, Build, Edition, Arch, Lang, LangFrom)

    # 1-2: policy
    if ($pol.Scope -eq 'ClientOs') { & $add 'None' "No change: $($pol.Why)" }
    elseif ($pol.Scope -eq 'NewerThanTarget') { & $add 'None' "No Windows change: $($pol.Why)" }
    $notified = $Record.PSObject.Properties['PolicyNotice'] -and $Record.PolicyNotice
    if ($pol.Warnings -and -not $notified) {
        & $add 'Management' "Warn management before any change and record it (vmm policy -Notice): $($pol.Warnings -join ' ')" -Blocking
    }
    if ($pol.Scope -eq 'ClientOs') { $res.Steps = $steps.ToArray(); $res.NextStep = $steps[0].Action; return $res }

    # 3: SQL that cannot live on the target OS (or an unknown version)
    foreach ($s in $inst) {
        if (-not $s.Known) {
            & $add 'Blocker' "$($s.Instance): SQL version $($s.Build) is not in the vmm table. Check it by hand before any Windows change." -Note 'Add the version to SqlMatrix settings or report it on GitHub (vmm issue).' -Blocking
        } elseif ($s.BlockedOn) {
            $maxName = if ($s.MaxOs) { $m.Os[$s.MaxOs].Name } else { 'the current OS' }
            & $add 'Blocker' ("{0}: {1} is not supported on {2}. Upgrade or migrate SQL Server first (a separate change, warn management). With this SQL, Windows can go up to {3}." -f $s.Instance, $s.Product, $m.Os[$s.BlockedOn].Name, $maxName) `
                -Link $m.Sources[0].Url -Blocking
        }
    }
    if (-not $reach -and $hops.Count -eq 0 -and $pol.Scope -eq 'InScope') {
        & $add 'Blocker' "No in-place path from '$($res.OS)' to the target ($tKey) in the vmm table: plan it by hand (rebuild or migration)." -Link $m.Sources[1].Url -Blocking
    }

    # 4: pending reboot
    if ("$($c.PendingReboot)" -eq 'Yes') { & $add 'Restart' 'Restart the host first: a pending reboot makes the SQL service pack and Windows setup fail.' -Blocking }

    # 5: SQL service pack before the first hop (or, at the target, the last SP to stay serviceable)
    $sqlBlocked = @($inst | Where-Object { -not $_.Known -or $_.BlockedOn }).Count -gt 0
    foreach ($s in $inst) {
        if (-not $s.Known -or $s.BlockedOn -or -not $s.Row.LastSp) { continue }
        $sp = $s.Row.LastSp
        $why = $null
        if ($hops.Count -and $s.NeedSp -gt $s.Sp) { $why = "required before the Windows upgrade: $($m.Os[$hops[-1]].Name) needs SP$($s.NeedSp) or later (now $($s.Level))" }
        elseif ($s.Sp -lt $sp.Sp) { $why = "last service pack, needed for the latest CU and for support (now $($s.Level))" }
        if (-not $why) { continue }
        $lang = if ($s.Lang) { $s.Lang } else { 'ENU' }
        $note = "Language $lang from $($s.LangFrom)."
        if ($osSqlLang -and $lang -ne $osSqlLang) { $note += " The OS language is $osSqlLang ($osLang): the service pack must match the SQL install language ($lang), not the OS." }
        & $add 'SqlServicePack' ("{0}: install {1} SP{2} ({3}) - {4}." -f $s.Instance, $s.Product, $sp.Sp, $sp.Kb, $why) `
            -File ($sp.File -f $s.Arch, $lang) -Lang $lang -Kb $sp.Kb -Link ("https://support.microsoft.com/help/{0}" -f ($sp.Kb -replace '^KB', '')) -Note $note -Blocking:($hops.Count -gt 0)
    }

    # 6: Windows hops (only when SQL does not block)
    $prev = $res.OsKey
    foreach ($h in $hops) {
        $ver = $h.ToUpper()
        $file = if ($osLang) { 'Win_Server_{0}_{1}.iso' -f $ver, $osLang.Replace('-', '_').ToUpper() } else { '' }
        $note = 'Same language and edition as the installed OS (Microsoft does not support a language change in place).'
        if ($m.Os[$prev].Legacy) { $note += " $($m.Os[$prev].Name) is not in Microsoft's current upgrade table (older guidance): warn management; a rebuild can be the better path." }
        $stage = "$(Get-VmmSetting 'Staging.OsMediaVersion' -Default '2019')".ToUpper()
        if ($stage -ne $ver) { $note += " Stage copies the $stage image (Staging.OsMediaVersion): copy this ISO by hand for this hop." }
        if (-not $osLang) { $note = 'OS install language not read: run the snapshot again. No ISO is picked without it (no fallback).' }
        $act = "In-place upgrade $($m.Os[$prev].Name) -> $($m.Os[$h].Name)$(if ($sqlBlocked) { ' (after the SQL blocker above is solved)' })."
        & $add 'WindowsUpgrade' $act -File $file -Lang $osLang -Link $m.Sources[1].Url -Note $note -Blocking:($sqlBlocked -or -not $osLang)
        $prev = $h
    }

    # 7: SQL latest CU after the last hop (or now, at the target)
    foreach ($s in $inst) {
        if (-not $s.Known -or $s.BlockedOn) { continue }
        $kb = ''; $file = ''
        if ($useBuildList -and -not $hops.Count) {
            try { $p = Get-VmmSqlUpdatePlan -Build $s.Build; $cuStep = @($p.Steps | Where-Object Kind -eq 'CU')[-1]; if ($cuStep) { $kb = $cuStep.Kb } elseif ($p.Target -eq $p.Current) { continue } } catch { }
        }
        $after = if ($hops.Count) { "after the last Windows hop ($($m.Os[$hops[-1]].Name))" } else { 'now' }
        $base = if ($s.Row.LastSp) { "$($s.Product) SP$($s.Row.LastSp.Sp)" } else { $s.Product }
        & $add 'SqlCumulativeUpdate' ("{0}: latest cumulative or security update (CU/GDR) for {1}, {2}." -f $s.Instance, $base, $after) `
            -Kb $kb -Lang 'neutral' -Link $(if ($kb) { "https://www.catalog.update.microsoft.com/Search.aspx?q=$kb" } else { $m.Sources[3].Url + [uri]::EscapeDataString($base + ' cumulative update') }) `
            -Note 'CU files are language-neutral. vmm fetch downloads it once into the share cache and copies it to the host folder.'
    }
    if (-not $steps.Count) { & $add 'None' $(if ($pol.Scope -eq 'AtTarget') { "Nothing to do: $($pol.Why) SQL is current." } else { 'Nothing to do.' }) }
    $res.Steps = $steps.ToArray()
    $first = @($steps | Where-Object { $_.Kind -ne 'None' })[0]
    if (-not $first) { $first = $steps[0] }
    $res.NextStep = "$($first.Action)$(if ($first.File) { " File: $($first.File)" })"
    $res
}
