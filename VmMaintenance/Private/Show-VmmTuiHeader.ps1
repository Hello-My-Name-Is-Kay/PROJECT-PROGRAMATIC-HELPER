function Show-VmmTuiHeader {
    # Rows 0-2: clock (zone + laptop), time window rule, daily progress, Azure context, credentials.
    [CmdletBinding()]
    param()
    $w = Get-VmmTimeWindow
    $now = Get-Date
    Write-VmmTuiLine -Row 0 -Text (" VMM fleet console | {0} {1} (laptop {2}) " -f $w.ZoneTime.ToString('ddd yyyy-MM-dd HH:mm:ss'), $w.ZoneLabel, $now.ToString('HH:mm:ss')) -Fg White -Bg DarkBlue

    if ($w.ChangesAllowed) {
        Write-VmmTuiLine -Row 1 -Text " MAINTENANCE WINDOW ($($w.Mode)): checks, staging and changes allowed" -Fg Green
    } else {
        Write-VmmTuiLine -Row 1 -Text " BUSINESS HOURS: checks + staging to C:\Temp only. Changes from $($w.NextChangeAt.ToString('ddd HH:mm')) (in $($w.UntilChangeText))" -Fg Yellow
    }

    if (-not $script:VmmProgCache -or ((Get-Date) - $script:VmmProgCache.At).TotalSeconds -gt 30) {
        try { $p = Get-VmmDailyProgress } catch { $p = $null }
        $az = 'not signed in'
        if (Get-Module Az.Accounts) { $c = Get-AzContext -ErrorAction SilentlyContinue; if ($c -and $c.Subscription) { $az = $c.Subscription.Name } }
        $script:VmmProgCache = @{ At = Get-Date; P = $p; Az = $az }
    }
    $p = $script:VmmProgCache.P
    if ($p) {
        $filled = if ($p.Target) { [math]::Min(10, [int][math]::Floor(10 * $p.Done / $p.Target)) } else { 0 }
        $bar = ('#' * $filled).PadRight(10, '-')
        $col = switch ($p.Status) { 'TargetMet' { 'Green' } 'OnTrack' { 'Cyan' } default { 'Red' } }
        $txt = " Today {0}/{1} [{2}] {3} (expected {4} by now, {5} h left) | Azure: {6} | {7}" -f $p.Done, $p.Target, $bar, $p.Status, $p.ExpectedByNow, $p.HoursLeft, $script:VmmProgCache.Az, (Get-VmmCredentialState)
        Write-VmmTuiLine -Row 2 -Text $txt -Fg $col
    } else {
        Write-VmmTuiLine -Row 2 -Text ' Progress unavailable (fleet store not readable) - see Help' -Fg Red
    }
}
