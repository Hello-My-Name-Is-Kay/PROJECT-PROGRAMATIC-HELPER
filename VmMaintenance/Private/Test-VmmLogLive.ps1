function Test-VmmLogLive {
    # Is the live log on? Session choice (F2) first, then --no-log, then the Log.Live setting (default on).
    [CmdletBinding()]
    param()
    if ($null -ne $script:VmmLogLive) { return [bool]$script:VmmLogLive }
    if ($script:VmmFlags -and $script:VmmFlags.NoLog) { return $false }
    $v = try { Get-VmmSetting 'Log.Live' -Default $true } catch { $true }
    if ($v -is [string]) { return ($v -notmatch '^(?i)\s*\$?(false|0|no|off)\s*$') }
    [bool]$v
}
