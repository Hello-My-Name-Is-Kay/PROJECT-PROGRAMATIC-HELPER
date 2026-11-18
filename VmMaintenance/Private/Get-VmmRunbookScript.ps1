function Get-VmmRunbookScript {
    # The host runbook text for one host: Resources\VmmRunbook.ps1 with its data block replaced by this host's
    # resolved workflow steps (with their current state), the known fixes of those steps and the time rules.
    # Known fixes are already shareable (no host names); the host's own name is in the file by design (the runbook
    # refuses to run on another computer without the name typed).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, $Catalog, $Resolved)
    if (-not $Catalog) { $Catalog = Get-VmmWorkflowCatalog }
    if (-not $Resolved) { $Resolved = Resolve-VmmHostWorkflow -Record $Record -Catalog $Catalog }
    $tpl = Join-Path $script:ModuleRoot 'Resources\VmmRunbook.ps1'
    $text = [IO.File]::ReadAllText($tpl)
    $q = { param($s) "'" + ("$s" -replace "[\r\n]+", ' ' -replace "'", "''") + "'" }
    $arr = { param($items) '@(' + (@($items | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { & $q $_ }) -join ', ') + ')' }
    $pol = $Resolved.Policy
    $noChange = if ($pol.Scope -in 'AtTarget', 'NewerThanTarget') { $pol.Why } else { '' }
    $ver = "$($MyInvocation.MyCommand.Module.Version)"
    $lines = @('# VMM-RUNBOOK-DATA-BEGIN')
    $lines += ('$Rb = @{{ Host = {0}; Workflow = {1}; Generated = {2}; Version = {3}; Zone = {4}; BizStart = {5}; BizEnd = {6}' -f (& $q $Record.Name), (& $q $Resolved.Workflow.Name),
               (& $q (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')), (& $q $ver), (& $q (Get-VmmSetting 'Schedule.TimeZoneId' -Default 'GMT Standard Time')),
               (& $q (Get-VmmSetting 'Schedule.BusinessStart' -Default '08:00')), (& $q (Get-VmmSetting 'Schedule.BusinessEnd' -Default '17:00')))
    $lines += ('         OffHoursWeekdays = ${0}; Days = {1}; Holidays = {2}; Azure = ${3}; Platform = {4}; Warnings = {5}; ClientOs = ${6}; NoChange = {7} }}' -f
               ([bool](Get-VmmSetting 'Schedule.AllowChangesOffHoursWeekdays' -Default $true)).ToString().ToLower(),
               (& $arr @(Get-VmmSetting 'Schedule.BusinessDays' -Default @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'))),
               (& $arr @(Get-VmmSetting 'Schedule.Holidays' -Default @())), ([bool]$Record.Azure -or $Record.Platform -eq 'Azure').ToString().ToLower(),
               (& $q $(if ($Record.Platform) { $Record.Platform } else { 'unknown' })), (& $arr @($pol.Warnings)), ($pol.Scope -eq 'ClientOs').ToString().ToLower(), (& $q $noChange))
    $lines += '$Steps = @('
    $ids = @()
    foreach ($s in $Resolved.Steps) {
        $a = $s.Action; $ids += $a.Id
        $lines += ('    @{{ Id = {0}; Key = {1}; Name = {2}; Title = {3}; Category = {4}; Builtin = ${5}; RunOnHost = ${6}; Status = {7}' -f (& $q $a.Id), (& $q $s.Key), (& $q $a.Name), (& $q $a.Title), (& $q $a.Category),
                   ([bool]$a.Builtin).ToString().ToLower(), ([bool]($a.RunOnHost -and $a.Category -eq 'ReadOnly')).ToString().ToLower(), (& $q $s.Status))
        $hostLines = if ($a.Builtin) { @("vmm runs and records this maintenance step from the laptop (the ticket on the laptop: Enter on the step, R). Nothing to do here: S moves on.") } else { @($a.Steps) }
        $lines += ('       Lines = {0}; Commands = {1}; Expect = {2}; Gated = $false }}' -f (& $arr $hostLines), (& $arr $(if ($a.Builtin) { @() } else { @($a.Commands) })), (& $q $a.Expect))
    }
    $lines += ')'
    $lines += '$Kb = @('
    foreach ($k in @($Catalog.Kb | Where-Object { $_.ActionId -eq '*' -or $ids -contains $_.ActionId })) {
        $lines += ('    @{{ Id = {0}; Action = {1}; Symptom = {2}; Cause = {3}; Fix = {4}; Commands = {5}; Helped = {6} }}' -f (& $q $k.Id), (& $q $k.ActionId), (& $q $k.Symptom), (& $q $k.Cause), (& $arr @($k.Fix)), (& $arr @($k.Commands)), [int]$k.Helped)
    }
    $lines += ')'
    $lines += '# VMM-RUNBOOK-DATA-END'
    $rx = '(?s)# VMM-RUNBOOK-DATA-BEGIN.*?# VMM-RUNBOOK-DATA-END'
    if ($text -notmatch $rx) { throw (New-VmmErrorRecord -Activity 'Runbook template has no data block.' -Target $tpl -Fix 'Restore Resources\VmmRunbook.ps1 from the repository.' -Category InvalidData -ErrorId 'VmmRunbookTemplate') }
    $data = ($lines -join "`r`n")
    [regex]::Replace($text, $rx, { param($m) $data })
}
