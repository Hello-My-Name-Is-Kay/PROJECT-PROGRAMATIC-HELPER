function Get-VmmQueue {
    # Work queue: hosts not done and not on hold, with next step, state, whether allowed now and
    # whether the tool can do it alone. Allowed-now first, then blocked last, then step order.
    [CmdletBinding()]
    param($Store)
    if (-not $Store) { $Store = Read-VmmStore }
    $w = Get-VmmTimeWindow
    $queue = foreach ($h in ($Store.Hosts | Where-Object { -not $_.Hold })) {
        $n = Get-VmmNextStep -Record $h
        if (-not $n) { continue }
        $st = $h.Steps.PSObject.Properties[$n.Name]
        $guided = $n.Mode -eq 'Guided' -or ($n.Mode -eq 'Hybrid' -and -not $h.Azure)
        if ($n.Name -eq 'Upgrade' -and $h.Azure -and (Get-VmmSetting 'Upgrade.Mode' -Default 'Guided') -eq 'RunCommand') { $guided = $false }
        [pscustomobject]@{
            Host = $h.Name; Step = $n; State = $(if ($st) { $st.Value.Status } else { 'todo' })
            Allowed = ($n.Class -ne 'Change' -or $w.ChangesAllowed); Guided = $guided; Health = $h.Health
        }
    }
    @($queue | Sort-Object @{ e = { -not $_.Allowed } }, @{ e = { $_.State -in 'Blocked', 'Failed' } }, @{ e = { $_.Step.Order } }, Host)
}
