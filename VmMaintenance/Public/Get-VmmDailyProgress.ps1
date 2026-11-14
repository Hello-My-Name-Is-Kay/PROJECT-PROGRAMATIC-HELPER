function Get-VmmDailyProgress {
    <#
    .SYNOPSIS
        Machines done today against the daily target (default 10 per 9-hour workday), with pace.
    .DESCRIPTION
        A machine counts once per day when any step listed in Target.CountedSteps succeeded today
        (zone date). Default: Stage (weekday prep done) or Verify (upgrade verified).
        Pace = done vs. the share of the workday already elapsed. Honest numbers only: skipped or
        overridden steps never count.
    .EXAMPLE
        Get-VmmDailyProgress
    #>
    [CmdletBinding()]
    param($Store)
    if (-not $Store) { $Store = Read-VmmStore }
    $w       = Get-VmmTimeWindow
    $target  = [int](Get-VmmSetting 'Target.MachinesPerDay' -Default 10)
    $hours   = [double](Get-VmmSetting 'Target.WorkdayHours' -Default 9)
    $counted = @(Get-VmmSetting 'Target.CountedSteps' -Default @('Stage', 'Verify'))
    $tz      = [TimeZoneInfo]::FindSystemTimeZoneById($w.ZoneId)
    $today   = $w.ZoneTime.Date

    $done = @()
    foreach ($h in $Store.Hosts) {
        foreach ($e in $h.History) {
            if ($e.Result -ne 'Success' -or $counted -notcontains $e.Step) { continue }
            $d = [TimeZoneInfo]::ConvertTimeFromUtc((ConvertTo-VmmUtcDate $e.At), $tz).Date
            if ($d -eq $today) { $done += $h.Name; break }
        }
    }
    $done = @($done | Select-Object -Unique)

    $dayStart = $today.Add([timespan]::Parse($w.BusinessStart))
    $elapsed  = [math]::Max(0, [math]::Min(1, ($w.ZoneTime - $dayStart).TotalHours / $hours))
    $expected = [int][math]::Ceiling($target * $elapsed)
    $status = if ($done.Count -ge $target) { 'TargetMet' } elseif ($done.Count -ge $expected) { 'OnTrack' } else { 'AtRisk' }

    [pscustomobject]@{
        Date          = $today.ToString('yyyy-MM-dd')
        Done          = $done.Count
        Target        = $target
        ExpectedByNow = $expected
        Status        = $status
        HoursLeft     = [math]::Round([math]::Max(0, $hours - ($w.ZoneTime - $dayStart).TotalHours), 1)
        Hosts         = $done
    }
}
