function Get-VmmTimeWindow {
    <#
    .SYNOPSIS
        Current time on this laptop and in the working time zone, and whether hosts may be changed now.
    .DESCRIPTION
        Rules (Schedule.* in config, default Europe/Lisbon = Windows id 'GMT Standard Time'):
          Business hours (Mon-Fri 08:00-17:00): checks and staging to C:\Temp only.
          Weekdays outside business hours: changes allowed when Schedule.AllowChangesOffHoursWeekdays = $true.
          Weekends and Schedule.Holidays: changes allowed.
    .EXAMPLE
        Get-VmmTimeWindow
    #>
    [CmdletBinding()]
    param([datetime]$At = (Get-Date))

    $tzId = Get-VmmSetting 'Schedule.TimeZoneId' -Default 'GMT Standard Time'
    try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($tzId) }
    catch {
        throw (New-VmmErrorRecord -Activity "Unknown time zone id '$tzId'." -Target 'Schedule.TimeZoneId' -Exception $_.Exception `
            -Fix "Use a Windows zone id. Lisbon is 'GMT Standard Time'. List them: Get-TimeZone -ListAvailable | Select-Object Id, DisplayName" `
            -Category InvalidArgument)
    }
    $days     = @(Get-VmmSetting 'Schedule.BusinessDays' -Default @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'))
    $startTxt = Get-VmmSetting 'Schedule.BusinessStart' -Default '08:00'
    $endTxt   = Get-VmmSetting 'Schedule.BusinessEnd'   -Default '17:00'
    $start    = [timespan]::Parse($startTxt)
    $end      = [timespan]::Parse($endTxt)
    $holidays = @(Get-VmmSetting 'Schedule.Holidays' -Default @())
    $offHours = [bool](Get-VmmSetting 'Schedule.AllowChangesOffHoursWeekdays' -Default $true)

    $zone = [TimeZoneInfo]::ConvertTimeFromUtc($At.ToUniversalTime(), $tz)
    $rule = @{ BusinessDays = $days; Start = $start; End = $end; Holidays = $holidays; OffHoursWeekdays = $offHours }
    $allowed = Test-VmmChangeAllowed -ZoneTime $zone @rule

    $isBizDay = ($days -contains $zone.DayOfWeek.ToString()) -and -not ($holidays -contains $zone.ToString('yyyy-MM-dd'))
    $mode = if (-not $isBizDay) { 'Weekend' }
            elseif ($zone.TimeOfDay -ge $start -and $zone.TimeOfDay -lt $end) { 'Business' }
            else { 'OffHours' }

    # Next moment changes are allowed (15-minute steps, up to 8 days ahead)
    $next = $zone
    if (-not $allowed) {
        $next = $zone.Date.AddHours($zone.Hour).AddMinutes([math]::Ceiling($zone.Minute / 15) * 15)
        for ($i = 0; $i -lt 768 -and -not (Test-VmmChangeAllowed -ZoneTime $next @rule); $i++) { $next = $next.AddMinutes(15) }
    }
    $until = $next - $zone
    $untilText = if ($until.TotalMinutes -le 0) { 'now' } else { '{0}h{1:00}m' -f [int][math]::Floor($until.TotalHours), $until.Minutes }

    [pscustomobject]@{
        LaptopTime      = $At
        ZoneTime        = $zone
        ZoneId          = $tzId
        ZoneLabel       = if ($tzId -eq 'GMT Standard Time') { 'Lisbon' } else { $tzId }
        Mode            = $mode
        ChangesAllowed  = $allowed
        StagingAllowed  = $true
        BusinessStart   = $startTxt
        BusinessEnd     = $endTxt
        NextChangeAt    = $next
        UntilChangeText = $untilText
    }
}
