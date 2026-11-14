function Assert-VmmWindow {
    # Enforces the time rules before a step. ReadOnly and Staging are always allowed.
    # Change during business hours is refused unless -Override with a reason; every override is
    # recorded in the fleet store and listed in the daily report.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('ReadOnly', 'Staging', 'Change')][string]$Class,
        [Parameter(Mandatory)][string]$Target,
        [switch]$Override,
        [string]$OverrideReason
    )
    if ($Class -ne 'Change') { return }
    $w = Get-VmmTimeWindow
    if ($w.ChangesAllowed) { return }

    if ($Override) {
        if (-not $OverrideReason -or $OverrideReason.Trim().Length -lt 10) {
            throw (New-VmmErrorRecord -Activity 'Override refused: a reason of at least 10 characters is required.' -Target $Target `
                -Fix "Add -OverrideReason 'who approved it and why'" -Category InvalidArgument -ErrorId 'VmmOverrideReason')
        }
        Write-VmmLog "OVERRIDE: changing '$Target' during business hours ($($w.ZoneTime.ToString('HH:mm')) $($w.ZoneLabel)). Reason: $OverrideReason" -Level Error
        $store = Read-VmmStore
        $store.Overrides = @($store.Overrides) + [pscustomobject]@{
            At = (Get-Date).ToUniversalTime().ToString('o'); Target = $Target; Reason = (Protect-VmmLogText $OverrideReason); Mode = $w.Mode
        }
        Save-VmmStore -Store $store
        return
    }
    throw (New-VmmErrorRecord -Activity "Blocked: '$Target' would change a host during business hours." `
        -Target "$($w.ZoneTime.ToString('ddd HH:mm')) $($w.ZoneLabel)" `
        -Cause "Mon-Fri $($w.BusinessStart)-$($w.BusinessEnd): hosts are in use. Only checks and staging files to C:\Temp are allowed." `
        -Fix "Wait until $($w.NextChangeAt.ToString('ddd HH:mm')) (in $($w.UntilChangeText)), or use the override (-Override -OverrideReason '...') only with your manager's agreement." `
        -Category PermissionDenied -ErrorId 'VmmWindowBlocked')
}
