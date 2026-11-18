function Edit-VmmActionFromTui {
    # Create (no -ActionId) or edit one action of the library, field by field (Enter keeps a value). Built-in
    # actions are copied first (-Copy). Returns the saved action, $null when cancelled.
    #   Category  ReadOnly (reads only) | Staging (writes into C:\Temp only) | Change (changes the host: after
    #             hours, rollback point + YES).  Mode: Guided (a person does it) | Auto (only built-ins run alone).
    #   RunOnHost read-only actions only: the host runbook may run the commands on the host when you say so.
    [CmdletBinding()]
    param([string]$ActionId, [switch]$Copy)
    $result = $null; $script:VmmEditedAction = $null
    [void](Invoke-VmmTuiAction -Title $(if (-not $ActionId) { 'New action' } elseif ($Copy) { 'Copy action' } else { 'Edit action' }) -Action {
        $cat = Get-VmmWorkflowCatalog; $ws = $cat.Store
        $src = if ($ActionId) { $cat.Actions | Where-Object Id -eq $ActionId | Select-Object -First 1 } else { $null }
        if ($ActionId -and -not $src) { throw (New-VmmErrorRecord -Activity "Action $ActionId not found." -Category ObjectNotFound -ErrorId 'VmmActionUnknown') }
        $isNew = -not $src -or $Copy -or $src.BuiltinItem
        if ($src -and $src.BuiltinItem -and $src.Builtin) { throw (New-VmmErrorRecord -Activity "'$($src.Name)' is a maintenance workflow step: vmm runs it with its own checks." -Fix 'Create a new guided action instead (N).' -Category InvalidOperation -ErrorId 'VmmActionBuiltin') }
        if ($src -and $src.BuiltinItem -and -not $Copy) { Write-VmmLog "'$($src.Name)' is built-in: you are editing a copy." -Level Warn }
        Write-VmmLog 'Enter keeps the value in [brackets]. Never type host names, IPs, ids or passwords: write <HOST>, <IP>.' -Level Muted
        $v = @{}
        $v.Name = Read-VmmField -Prompt 'Name (short)' -Current $(if ($src) { if ($isNew) { "$($src.Name) (copy)" } else { $src.Name } }) -Required
        $v.Title = Read-VmmField -Prompt 'What it does (one line)' -Current $(if ($src) { $src.Title })
        Write-VmmLog 'Category: ReadOnly = only reads | Staging = writes into C:\Temp only (allowed in business hours) | Change = changes the host (after hours, rollback point + YES)' -Level Muted
        $v.Category = Read-VmmField -Prompt 'Category' -Current $(if ($src) { $src.Category } else { 'ReadOnly' }) -Allowed 'ReadOnly', 'Staging', 'Change' -Required
        $v.Group = Read-VmmField -Prompt 'Group (e.g. OS, Disk, SQL, Services, Agents)' -Current $(if ($src) { $src.Group } else { 'General' })
        $v.Steps = @(Read-VmmLines -Prompt 'Instructions (what the person does, in order)' -Current $(if ($src) { @($src.Steps) } else { @() }))
        $v.Commands = @(Read-VmmLines -Prompt 'Commands to paste on the host (PowerShell, one per line; optional)' -Current $(if ($src) { @($src.Commands) } else { @() }))
        $v.Expect = Read-VmmField -Prompt 'What success looks like' -Current $(if ($src) { $src.Expect })
        $v.RunOnHost = $false
        if ($v.Category -eq 'ReadOnly' -and $v.Commands.Count) {
            $cur = if ($src -and $src.RunOnHost) { 'y' } else { 'n' }
            $v.RunOnHost = (Read-VmmField -Prompt 'Read-only commands: may the host runbook run them on the host when the person says so? (y/n)' -Current $cur -Allowed 'y', 'n') -eq 'y'
        }
        $names = @(Get-VmmFleetName)
        $clean = { param($s) ConvertTo-VmmShareableText -Text $s -Names $names }
        $at = (Get-Date).ToUniversalTime().ToString('o')
        $obj = if ($isNew) { [pscustomobject]@{ Id = (New-VmmId -Prefix a); Name = ''; Title = ''; Category = ''; Group = ''; Mode = 'Guided'; Builtin = $null; RunOnHost = $false; Steps = @(); Commands = @(); Expect = ''; Created = $at; Updated = $at } }
               else { $ws.Actions | Where-Object Id -eq $src.Id | Select-Object -First 1 }
        foreach ($k in 'Name', 'Title', 'Group', 'Expect') { $obj.$k = & $clean $v[$k] }
        $obj.Category = $v.Category; $obj.RunOnHost = $v.RunOnHost; $obj.Updated = $at
        $obj.Steps = @($v.Steps | ForEach-Object { & $clean $_ }); $obj.Commands = @($v.Commands | ForEach-Object { & $clean $_ })
        if ($isNew) { $ws.Actions = @($ws.Actions) + $obj }
        Save-VmmWorkflowStore -Store $ws
        Write-VmmLog "Action '$($obj.Name)' saved ($($obj.Category))." -Level Success
        $script:VmmEditedAction = $obj
    })
    $result = $script:VmmEditedAction; $script:VmmEditedAction = $null
    $result
}
