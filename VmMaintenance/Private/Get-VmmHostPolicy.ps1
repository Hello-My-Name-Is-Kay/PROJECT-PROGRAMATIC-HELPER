function Get-VmmHostPolicy {
    # Fleet OS policy for one host (config section Policy):
    #   - goal: every machine on Policy.TargetOs (Windows Server 2019)
    #   - client OS (Windows 10/11...) is never touched unless the host carries an order (Set-VmmHostOrder)
    #   - management is warned about Windows Server 2008 (not R2) and about physical machines
    # Scope: Unknown (no check yet) | InScope | AtTarget | NewerThanTarget | ClientOs (excluded) | ClientOsOrdered
    # The OS before the upgrade (Baseline) decides the scope, so an upgraded host stays InScope until Verify.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    $target  = Get-VmmSetting 'Policy.TargetOs' -Default '*Server 2019*'
    $newer   = @(Get-VmmSetting 'Policy.NewerOs' -Default @('*Server 2022*', '*Server 2025*'))
    $client  = @(Get-VmmSetting 'Policy.ClientOs' -Default @('*Windows 10*', '*Windows 11*', '*Windows 8*', '*Windows 7*', '*Windows XP*', '*Windows Vista*'))
    $warnOs  = @(Get-VmmSetting 'Policy.WarnOs' -Default @('*Server 2008*'))
    $okOs    = @(Get-VmmSetting 'Policy.WarnOsExcept' -Default @('*2008 R2*'))
    $warnPhy = [bool](Get-VmmSetting 'Policy.WarnPhysical' -Default $true)

    $os = if ($Record.Baseline -and $Record.Baseline.OS) { "$($Record.Baseline.OS)" } elseif ($Record.Check -and $Record.Check.OS) { "$($Record.Check.OS)" } else { '' }
    $like = { param($v, $pats) foreach ($p in $pats) { if ($p -and $v -like $p) { return $true } }; $false }
    $ordered = $Record.PSObject.Properties['Order'] -and $Record.Order -and -not $Record.Order.Cleared

    $scope = 'InScope'; $why = "Upgrade to $target."
    if (-not $os) { $scope = 'Unknown'; $why = 'OS not known yet: run Precheck (read-only).' }
    elseif (& $like $os $client -or $os -notlike '*Server*') {
        if ($ordered) { $scope = 'ClientOsOrdered'; $why = "Client OS ($os) - in scope by order: $($Record.Order.Reason)" }
        else { $scope = 'ClientOs'; $why = "Client OS ($os): not touched without orders (vmm order -HostName $($Record.Name) -Reason '...')." }
    }
    elseif ($os -like $target) { $scope = 'AtTarget'; $why = "Already on the target OS ($os): nothing to upgrade." }
    elseif (& $like $os $newer) { $scope = 'NewerThanTarget'; $why = "Newer than the target ($os): never downgraded." }

    $warn = @()
    if ($os -and (& $like $os $warnOs) -and -not (& $like $os $okOs)) {
        $warn += "Windows Server 2008 (not R2): $os. Warn management: no direct in-place path to 2019 (needs 2008 R2 / 2012 R2 hops or a rebuild)."
    }
    if ($warnPhy -and $Record.Platform -eq 'Physical') {
        $warn += 'Physical machine: warn management. No Azure snapshot or disk resize; rollback depends on the backup tool and on-site access.'
    }
    [pscustomobject]@{
        Scope    = $scope
        Workable = $scope -in 'Unknown', 'InScope', 'ClientOsOrdered'
        Why      = $why
        Warnings = $warn
        Os       = $os
    }
}
