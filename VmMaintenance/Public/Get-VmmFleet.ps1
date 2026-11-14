function Get-VmmFleet {
    <#
    .SYNOPSIS
        Lists the fleet with health, furthest step, OS, SQL and C: free space.
    .EXAMPLE
        Get-VmmFleet | Where-Object Health -ne 'OK'
    #>
    [CmdletBinding()]
    param([string]$Filter = '*', [switch]$Raw)
    $store = Read-VmmStore
    $hosts = @($store.Hosts | Where-Object { $_.Name -like $Filter } | Sort-Object Name)
    if ($Raw) { return $hosts }
    foreach ($h in $hosts) {
        $c = $h.Check
        [pscustomobject]@{
            Name      = $h.Name
            Platform  = $h.Platform
            Health    = $h.Health
            Stage     = Get-VmmHostStage -Record $h
            NextStep  = (Get-VmmNextStep -Record $h).Name
            OS        = if ($c) { $c.OS } else { $null }
            CFreeGB   = if ($c) { $c.CFreeGB } else { $null }
            Sql       = if ($c) { $c.Sql } else { $null }
            Reboot    = if ($c) { $c.PendingReboot } else { $null }
            Blockers  = @($h.Blockers | Where-Object { -not $_.Resolved }).Count
            LastCheck = if ($c) { $c.CheckedAt } else { $null }
            Hold      = $h.Hold
        }
    }
}
