function Get-VmmSqlUpdatePlan {
    # What one SQL Server build needs, from the dbatools build reference (Microsoft's list of every
    # SP and CU): nothing when it is current, else the KB(s) in install order - the service pack first
    # when the target CU belongs to a newer SP, then the CU. SqlUpdates.MaxBehind (e.g. '1CU') allows
    # being behind; empty = latest. Returns @{ Current; Target; Steps = @(@{ Kb; Kind; Label }); Warning }.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Build)
    $mb = "$(Get-VmmSetting 'SqlUpdates.MaxBehind' -Default '')"
    $t = if ($mb) { Test-DbaBuild -Build $Build -MaxBehind $mb -EnableException } else { Test-DbaBuild -Build $Build -Latest -EnableException }
    $t = @($t)[0]
    $cur = @(Get-DbaBuild -Build $Build -EnableException)[0]
    $kbName = { param($k) 'KB' + ("$(@($k)[0])" -replace '^(?i)KB', '') }
    $label = { param($b) (@($b.NameLevel, $b.SPLevel, $b.CULevel) | Where-Object { $_ }) -join ' ' }
    $res = [pscustomobject]@{ Current = (& $label $cur); Target = ''; Steps = @(); Warning = "$($t.Warning)" }
    if (-not $cur -or -not $cur.NameLevel) { $res.Warning = "Build $Build is not in the build reference (very new or unknown)."; return $res }
    if ($t.Compliant -or -not $t.BuildTarget) { $res.Target = $res.Current; return $res }
    $tgt = @(Get-DbaBuild -Build "$($t.BuildTarget)" -EnableException)[0]
    $res.Target = & $label $tgt
    $steps = @()
    if ($tgt.CULevel -and $tgt.SPLevel -and $tgt.SPLevel -ne 'RTM' -and $tgt.SPLevel -ne $cur.SPLevel) {
        # The CU installs on top of its service pack only: fetch that SP too
        $sp = $null
        foreach ($spv in @("$($tgt.SPLevel)", ("$($tgt.SPLevel)" -replace '^SP', ''))) {
            try { $sp = @(Get-DbaBuild -MajorVersion "$($cur.NameLevel)" -ServicePack $spv -EnableException | Where-Object { -not $_.CULevel })[0]; if ($sp) { break } } catch { }
        }
        if ($sp -and $sp.KBLevel) { $steps += [pscustomobject]@{ Kb = (& $kbName $sp.KBLevel); Kind = 'SP'; Label = "$($cur.NameLevel) $($tgt.SPLevel)" } }
        else { $res.Warning = "The service pack $($tgt.SPLevel) under the target CU was not found in the build reference: fetch it by hand." }
    }
    if ($tgt.KBLevel) {
        $steps += [pscustomobject]@{ Kb = (& $kbName $tgt.KBLevel); Kind = $(if ($tgt.CULevel) { 'CU' } else { 'SP' }); Label = $res.Target }
    }
    $res.Steps = @($steps)
    $res
}
