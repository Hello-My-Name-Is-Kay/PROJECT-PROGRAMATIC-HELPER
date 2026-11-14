function Switch-VmmLogLive {
    # F2 on any screen: live log pane and live progress lines on/off. Saved as Log.Live so the
    # choice survives a restart; the log file is written either way.
    [CmdletBinding()]
    param([Nullable[bool]]$On)
    $new = if ($null -ne $On) { [bool]$On } else { -not (Test-VmmLogLive) }
    $script:VmmLogLive = $new
    Add-VmmLogEntry -Text ("Live log turned {0} (F2). The log file is still written." -f $(if ($new) { 'on' } else { 'off' })) -Level Muted
    if ($script:VmmConfigPath) { try { Set-VmmSetting -Name 'Log.Live' -Value $new -WhatIf:$false 6>$null | Out-Null } catch { } }
    $new
}
