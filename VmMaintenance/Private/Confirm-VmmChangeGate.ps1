function Confirm-VmmChangeGate {
    # The questions a person answers before a guided step that is not read-only. In this order:
    #   policy     client OS without orders: nothing; at/over the target OS: no Change step
    #   Staging    reminder that only C:\Temp may be written in business hours, then y/N
    #   Change     time window (business hours: OVERRIDE + reason, recorded and reported), management warnings
    #              (MANAGEMENT INFORMED), rollback point (Azure: SNAPSHOT TAKEN, other platforms: BACKUP
    #              CONFIRMED), then YES.
    # Returns @{ Ok; Note } - Note says what was confirmed (it goes into the step history). ReadOnly: Ok at once.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)]$Action, $Policy)
    if (-not $Policy) { $Policy = Get-VmmHostPolicy -Record $Record }
    $no = { param($m) Write-VmmLog $m -Level Muted; @{ Ok = $false; Note = '' } }
    if ($Policy.Scope -eq 'ClientOs') { Write-VmmLog "POLICY: $($Policy.Why)" -Level Error; return @{ Ok = $false; Note = '' } }
    if ($Action.Category -eq 'ReadOnly') { return @{ Ok = $true; Note = '' } }
    $what = "$($Action.Name) on $($Record.Name)"
    if ($Action.Category -eq 'Staging') {
        Write-VmmLog "$what writes files on the host. In business hours only into C:\Temp, nothing else." -Level Warn
        if ((Read-VmmPrompt 'Continue? (y/N)') -notmatch '^[yY]') { return (& $no 'Cancelled - nothing recorded.') }
        return @{ Ok = $true; Note = 'staging confirmed (C:\Temp only)' }
    }
    if ($Policy.Scope -in 'AtTarget', 'NewerThanTarget') { Write-VmmLog "POLICY: $($Policy.Why) No change step on this host." -Level Error; return @{ Ok = $false; Note = '' } }
    $notes = @()
    $w = Get-VmmTimeWindow
    if (-not $w.ChangesAllowed) {
        Write-VmmLog "IMPORTANT: it is business hours ($($w.ZoneTime.ToString('HH:mm')) $($w.ZoneLabel)). '$what' changes the host while people use it." -Level Error
        Write-VmmLog "Allowed from $($w.NextChangeAt.ToString('ddd HH:mm')) (in $($w.UntilChangeText)). Override only with your manager's agreement - it is recorded and reported." -Level Warn
        if ((Read-VmmPrompt 'Type OVERRIDE to continue, anything else to cancel') -cne 'OVERRIDE') { return (& $no 'Cancelled - nothing changed.') }
        $reason = Read-VmmPrompt 'Reason (who approved, why; min 10 chars)'
        Assert-VmmWindow -Class Change -Target "$($Record.Name)/$($Action.Name)" -Override -OverrideReason $reason   # throws on a short reason, records the override
        $notes += 'OVERRIDE (business hours)'
    }
    if ($Policy.Warnings) {
        Write-VmmLog "Management warnings: $($Policy.Warnings -join ' ')" -Level Warn
        if ((Read-VmmPrompt 'Type MANAGEMENT INFORMED to confirm') -cne 'MANAGEMENT INFORMED') { return (& $no 'Cancelled - management not informed.') }
        $notes += 'management informed'
    }
    $azure = [bool]$Record.Azure -or $Record.Platform -eq 'Azure'
    $phrase = if ($azure) { 'SNAPSHOT TAKEN' } else { 'BACKUP CONFIRMED' }
    if ($azure) { Write-VmmLog "Azure VM: a snapshot of every disk (OS and SQL data) must exist before this change (vmm takes them at the snapshot points; the portal works too)." -Level Warn }
    else { Write-VmmLog "Platform $(if ($Record.Platform) { $Record.Platform } else { 'unknown' }): a full backup or platform snapshot of this host must exist before this change." -Level Warn }
    if ((Read-VmmPrompt "Type $phrase to confirm the rollback point") -cne $phrase) { return (& $no 'Cancelled - no rollback point confirmed.') }
    $notes += "rollback point confirmed ($phrase)"
    if ((Read-VmmPrompt "Type YES to do '$what' now") -cne 'YES') { return (& $no 'Cancelled.') }
    @{ Ok = $true; Note = ($notes + 'YES') -join ', ' }
}
