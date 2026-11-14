function Get-VmmHostAccess {
    # How this laptop last reached a host: the terminal route that answered, or why none did.
    # Terminal = $true (route works), $false (tried, no route), $null (never tried or older than Fleet.AccessMaxAgeHours).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    $a = if ($Record.PSObject.Properties['Access']) { $Record.Access } else { $null }
    if (-not $a -or -not $a.At) {
        return [pscustomobject]@{ Terminal = $null; Route = ''; AgeHours = $null; Why = 'not tried from this terminal yet'; Tried = '' }
    }
    $age = $null
    try { $age = [math]::Round(((Get-Date).ToUniversalTime() - ([datetime]$a.At).ToUniversalTime()).TotalHours, 1) } catch { }
    $max = [double](Get-VmmSetting 'Fleet.AccessMaxAgeHours' -Default 24)
    $works = "$($a.Route)" -and "$($a.Route)" -ne 'None'
    $terminal = if ($null -eq $age -or $age -gt $max) { $null } else { [bool]$works }
    $why = if ($works) { "$($a.Route) answered $age h ago" } elseif ($a.Why) { "$($a.Why)" } else { 'no terminal route' }
    if ($null -eq $terminal) { $why = "last tried $age h ago ($(if ($works) { $a.Route } else { 'no route' })): try again" }
    [pscustomobject]@{ Terminal = $terminal; Route = "$($a.Route)"; AgeHours = $age; Why = $why; Tried = "$($a.Tried)" }
}
