function Edit-VmmKnowledgeFromTui {
    # Records a known fix (new, or -EntryId to edit one): what happened (symptom), the cause, the fix steps and
    # commands. -ActionId ties it to an action ('*' = any step); -Symptom pre-fills the error that was just seen.
    # Host names, IPs, ids and secrets are removed before it is saved. Returns the entry or $null.
    [CmdletBinding()]
    param([string]$ActionId, [string]$EntryId, [string]$Symptom = '', [string]$HostName)
    $script:VmmEditedKb = $null
    [void](Invoke-VmmTuiAction -Title $(if ($EntryId) { 'Edit known fix' } else { 'Record a known fix for the next technician' }) -Action {
        $cat = Get-VmmWorkflowCatalog; $ws = $cat.Store
        $e = if ($EntryId) { $cat.Kb | Where-Object Id -eq $EntryId | Select-Object -First 1 } else { $null }
        if ($e -and $e.BuiltinItem) { throw (New-VmmErrorRecord -Activity 'Built-in known fixes are not editable.' -Fix 'Record a new one (N) for your case.' -Category InvalidOperation -ErrorId 'VmmKbBuiltin') }
        if (-not $ActionId) { $ActionId = if ($e) { $e.ActionId } else { '*' } }
        $a = $cat.Actions | Where-Object Id -eq $ActionId | Select-Object -First 1
        Write-VmmLog "For: $(if ($a) { $a.Name } else { 'any step' }). Write it for a colleague who sees this error for the first time." -Level Info
        Write-VmmLog 'Host names, IPs and ids are replaced with <HOST>, <IP>, <ID> automatically. Never type passwords.' -Level Muted
        $sym = Read-VmmField -Prompt 'What happened (the error or what you saw)' -Current $(if ($e) { $e.Symptom } else { $Symptom }) -Required
        $cause = Read-VmmField -Prompt 'Why it happened (if known)' -Current $(if ($e) { $e.Cause })
        $fix = @(Read-VmmLines -Prompt 'How you fixed it (steps in order)' -Current $(if ($e) { @($e.Fix) } else { @() }))
        if (-not $fix.Count) { Write-VmmLog 'No fix steps: nothing saved. A known fix needs at least one step.' -Level Warn; return }
        $cmd = @(Read-VmmLines -Prompt 'Commands used (optional)' -Current $(if ($e) { @($e.Commands) } else { @() }))
        $names = @(Get-VmmFleetName); if ($HostName) { $names += $HostName }
        if ($e) {
            $o = $ws.Kb | Where-Object Id -eq $e.Id | Select-Object -First 1
            $o.Symptom = ConvertTo-VmmShareableText $sym -Names $names; $o.Cause = ConvertTo-VmmShareableText $cause -Names $names
            $o.Fix = @($fix | ForEach-Object { ConvertTo-VmmShareableText $_ -Names $names }); $o.Commands = @($cmd | ForEach-Object { ConvertTo-VmmShareableText $_ -Names $names })
            $o.Updated = (Get-Date).ToUniversalTime().ToString('o')
        } else { $o = Add-VmmKnowledgeEntry -WorkflowStore $ws -ActionId $ActionId -Symptom $sym -Cause $cause -Fix $fix -Commands $cmd -Names $names }
        Save-VmmWorkflowStore -Store $ws
        Write-VmmLog 'Known fix saved. The next person whose step fails like this sees it as a suggested resolution.' -Level Success
        if (Get-VmmSetting 'Workflow.LibraryPath' -Default '') { Write-VmmLog 'Share it with the team: workflow manager (K) > X export.' -Level Muted }
        $script:VmmEditedKb = $o
    })
    $o = $script:VmmEditedKb; $script:VmmEditedKb = $null
    $o
}
