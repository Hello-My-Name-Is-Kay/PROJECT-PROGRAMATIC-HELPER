function Get-VmmHostHealth {
    # OK / Warn / Critical / Unreachable from a check result, using the Lansweeper thresholds and agent health.
    [CmdletBinding()]
    param([AllowNull()]$Check)
    if (-not $Check) { return 'Unknown' }
    if ($Check.Reachable -ne 'Yes') { return 'Unreachable' }
    $crit = [double](Get-VmmSetting 'Lansweeper.CriticalGB' -Default 32)
    $ok   = [double](Get-VmmSetting 'Lansweeper.OkGB' -Default 40)
    if ($null -ne $Check.CFreeGB -and [double]$Check.CFreeGB -lt $crit) { return 'Critical' }
    if (($null -ne $Check.CFreeGB -and [double]$Check.CFreeGB -lt $ok) -or $Check.PendingReboot -eq 'Yes' -or $Check.Error) { return 'Warn' }
    # A security/monitoring agent that is missing or stopped (FAIL) makes the host Warn (Agents.AffectHealth)
    if ((Get-VmmSetting 'Agents.AffectHealth' -Default $true) -and $Check.PSObject.Properties['Agents'] -and $Check.Agents) {
        foreach ($p in $Check.Agents.PSObject.Properties) { if ($p.Value.Status -eq 'FAIL') { return 'Warn' } }
    }
    'OK'
}
