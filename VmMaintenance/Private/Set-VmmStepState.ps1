function Set-VmmStepState {
    # Records a step result on a host record and appends it to the host history (UTC ISO times).
    # Status: Success, Failed, Blocked, Skipped, NotNeeded, Launched, Running.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Status,
        [string]$Note = '',
        [string]$Snapshot
    )
    $at = (Get-Date).ToUniversalTime().ToString('o')
    $state = [pscustomobject]@{ Status = $Status; At = $at; Note = (Protect-VmmLogText $Note); Snapshot = $Snapshot }
    $Record.Steps | Add-Member -NotePropertyName $Step -NotePropertyValue $state -Force
    $Record.History = @($Record.History) + [pscustomobject]@{ At = $at; Step = $Step; Result = $Status; Note = (Protect-VmmLogText $Note) }
    # Keep history bounded: last 200 entries per host
    if ($Record.History.Count -gt 200) { $Record.History = @($Record.History | Select-Object -Last 200) }
}
