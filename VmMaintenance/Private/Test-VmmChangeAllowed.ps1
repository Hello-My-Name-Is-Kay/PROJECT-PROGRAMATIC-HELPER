function Test-VmmChangeAllowed {
    # Pure rule: may hosts be changed at this zone-local time? Used by Get-VmmTimeWindow.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$ZoneTime,
        [Parameter(Mandatory)][string[]]$BusinessDays,
        [Parameter(Mandatory)][timespan]$Start,
        [Parameter(Mandatory)][timespan]$End,
        [string[]]$Holidays = @(),
        [bool]$OffHoursWeekdays = $true
    )
    $isHoliday = $Holidays -contains $ZoneTime.ToString('yyyy-MM-dd')
    $isBizDay  = ($BusinessDays -contains $ZoneTime.DayOfWeek.ToString()) -and -not $isHoliday
    if (-not $isBizDay) { return $true }
    $inHours = $ZoneTime.TimeOfDay -ge $Start -and $ZoneTime.TimeOfDay -lt $End
    if ($inHours) { return $false }
    $OffHoursWeekdays
}
