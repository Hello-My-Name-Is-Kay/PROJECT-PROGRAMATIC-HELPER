function Show-VmmStepDialog {
    # The step dialogue: guides a person through one workflow step on one host over RDP, line by line.
    #   Enter ticks an instruction, C copies the selected command (or all), L opens remote desktop.
    #   G  the gate for a step that is not read-only (Confirm-VmmChangeGate: time window / OVERRIDE, management
    #      warnings, SNAPSHOT TAKEN or BACKUP CONFIRMED, YES); commands of such a step are copied only after it.
    #   D  done (asks what you saw), F failed (failure dialogue with known fixes), S skip with a reason,
    #   K  known fixes, T ticket for the IT person who can fix a failure.
    # Built-in maintenance steps: R runs the step through vmm (its own checks and gates), D confirms it,
    # G opens its RDP guide.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][string]$ActionId)
    $sel = 0; $status = ''; $done = @{}; $gate = $null
    while ($true) {
        $store = Read-VmmStore; $rec = Get-VmmHostRecord -Store $store -Name $HostName
        $cat = Get-VmmWorkflowCatalog
        $res = Resolve-VmmHostWorkflow -Record $rec -Catalog $cat
        $s = $res.Steps | Where-Object { $_.Action.Id -eq $ActionId } | Select-Object -First 1
        $a = if ($s) { $s.Action } else { $cat.Actions | Where-Object Id -eq $ActionId | Select-Object -First 1 }
        if (-not $a) { return }
        $key = Get-VmmStepKey -Action $a
        $st = $rec.Steps.PSObject.Properties[$key]
        $builtin = [bool]$a.Builtin
        $needGate = -not $builtin -and $a.Category -ne 'ReadOnly'
        $kbN = @(Find-VmmKnowledge -Catalog $cat -ActionId $a.Id).Count
        $rows = @(); $meta = @()
        $add = { param($row, $m) $script:VmmDlgRows += , $row; $script:VmmDlgMeta += , $m }
        $script:VmmDlgRows = @(); $script:VmmDlgMeta = @()
        & $add @{ Text = "$($a.Category) | $($a.Mode)$(if ($builtin) { ' | maintenance step: vmm checks and records it' }) | status: $(if ($st) { "$($st.Value.Status) $($st.Value.Note)" } else { 'todo' })"; Header = $true } $null
        if ($s -and -not $s.Allowed) { & $add @{ Text = "NOT NOW: $($s.Why)"; Color = 'Yellow' } $null }
        if ($needGate) { & $add @{ Text = $(if ($gate) { "GATE PASSED: $($gate.Note)" } else { 'GATE: press G first (time window, rollback point, YES). Commands are copied only after it.' }); Color = $(if ($gate) { 'Green' } else { 'Yellow' }) } $null }
        $items = if ($builtin) { @(Get-VmmRdpGuide -HostName $rec.Name -Step $a.Builtin) } else {
            @(@($a.Steps | ForEach-Object { [pscustomobject]@{ Text = $_; Command = $null } }) + @($a.Commands | ForEach-Object { [pscustomobject]@{ Text = 'Paste on the host (PowerShell):'; Command = $_ } }))
        }
        & $add @{ Text = 'DO THIS (Enter ticks a line)'; Header = $true } $null
        for ($i = 0; $i -lt $items.Count; $i++) {
            $c = $items[$i].Command
            $cmdText = if ($c) { '   >> ' + (($c -split "`n")[0]) + $(if ($c -match "`n") { ' ...(C copies all)' }) } else { '' }
            & $add @{ Text = "$(if ($done[$i]) { '[x]' } else { '[ ]' }) $($i + 1). $($items[$i].Text)$cmdText"; Color = $(if ($done[$i]) { 'DarkGray' } else { 'Gray' }) } @{ Tick = $i; Cmd = $c }
        }
        if ($a.Expect) { & $add @{ Text = 'SUCCESS LOOKS LIKE'; Header = $true } $null; & $add @{ Text = "$($a.Expect)" } $null }
        & $add @{ Text = "KNOWN FIXES: $kbN (K)$(if ($kbN) { ' - F shows the ones that match your error' })"; Header = $true } $null
        $rows = $script:VmmDlgRows; $meta = $script:VmmDlgMeta
        $help = if ($builtin) { 'Enter tick | C copy | R run in vmm | D confirm done | G RDP guide | F failed | K fixes | L RDP | T IT ticket | Esc' }
                else { "Enter tick | C copy | $(if ($needGate) { 'G gate | ' })D done | F failed | S skip | K fixes | L RDP | T IT ticket | Esc" }
        $r = Invoke-VmmListView -Title "$($rec.Name) / step $(if ($s) { $s.Index }): $($a.Name) - $($a.Title)" -Rows $rows -Selected $sel -Status $status `
             -Hotkeys @('C', 'G', 'D', 'F', 'S', 'K', 'L', 'R', 'T') -Help $help
        $sel = $r.Index; $status = ''
        $m = $meta[$r.Index]
        $policyStop = $res.Policy.Scope -eq 'ClientOs'
        switch ($r.Action) {
            'Esc'   { return }
            'Enter' { if ($m -and $null -ne $m.Tick) { $done[$m.Tick] = -not $done[$m.Tick]; if ($done[$m.Tick]) { $sel++ } } }
            'C'     { if ($needGate -and -not $gate) { $status = 'Press G first: this step changes the host or writes files on it'; break }
                      $c = if ($m -and $m.Cmd) { $m.Cmd } else { @($items | Where-Object Command | ForEach-Object { $_.Command }) -join "`r`n" }
                      if ($c) { try { $c | Set-Clipboard; $status = 'Command copied - paste it in the RDP session (Ctrl+V / right-click)' } catch { $status = "Clipboard failed: $($_.Exception.Message)" } } else { $status = 'No command on this step' } }
            'G'     { if ($builtin) { Show-VmmGuideScreen -HostName $rec.Name -Step $a.Builtin }
                      elseif (-not $needGate) { $status = 'Read-only step: no gate needed' }
                      elseif ($s -and -not $s.Allowed -and $s.Why -notlike 'Business hours*') { $status = "Not now: $($s.Why)" }
                      else {
                          $g = $null
                          [void](Invoke-VmmTuiAction -Title "Gate - $($a.Name) on $($rec.Name)" -TicketHost $rec.Name -Action {
                              $script:VmmGate = Confirm-VmmChangeGate -Record $rec -Action $a -Policy $res.Policy
                              if ($script:VmmGate.Ok) { Set-VmmTicketStep -HostName $HostName -Key $key -Status Running -Note "gate: $($script:VmmGate.Note)" }
                          })
                          if ($script:VmmGate -and $script:VmmGate.Ok) { $gate = $script:VmmGate; $status = 'Gate passed: copy the commands (C), do the work, then D or F' }
                          $script:VmmGate = $null
                      } }
            'R'     { if (-not $builtin) { $status = 'R runs maintenance steps only; for this step follow the lines and press D or F' }
                      else { [void](Invoke-VmmTuiAction -Title "$($rec.Name) - $($a.Builtin)" -TicketHost $rec.Name -TicketStep $a.Builtin -Action { Invoke-VmmStepFromTui -HostName $HostName -Step $a.Builtin }) } }
            'D'     { if ($policyStop) { $status = "POLICY: $($res.Policy.Why)"; break }
                      if ($builtin) { [void](Invoke-VmmTuiAction -Title "$($rec.Name) - confirm $($a.Builtin) done" -TicketHost $rec.Name -TicketStep $a.Builtin -Action { Invoke-VmmStepFromTui -HostName $HostName -Step $a.Builtin -Confirmed }); break }
                      if ($needGate -and -not $gate) { $status = 'Press G first (the gate), then do the work, then D'; break }
                      if ($a.Category -eq 'Change' -and $s -and -not $s.Allowed -and $s.Why -notlike 'Business hours*') { $status = "Not now: $($s.Why)"; break }
                      [void](Invoke-VmmTuiAction -Title "$($rec.Name) - $($a.Name) done" -Action {
                          if ($a.Expect) { Write-VmmLog "Success looks like: $($a.Expect)" -Level Info }
                          $seen = Read-VmmPrompt 'What did you see? (short result, Enter = as expected; type N if it did not work)'
                          if ($seen -match '^[nN]$') { Write-VmmLog 'Not recorded as done: press F to record the failure.' -Level Warn; return }
                          $note = @(); if ($gate) { $note += "gate: $($gate.Note)" }; $note += $(if ($seen) { $seen } else { 'as expected' })
                          Set-VmmTicketStep -HostName $HostName -Key $key -Status Success -Note ($note -join ' | ')
                      })
                      $gate = $null }
            'S'     { if ($builtin) { $status = 'Maintenance steps are skipped only by their own rules (e.g. ManualCheck BYPASS via R)'; break }
                      [void](Invoke-VmmTuiAction -Title "$($rec.Name) - skip $($a.Name)" -Action {
                          $why = Read-VmmPrompt 'Why is this step skipped? (who decided, min 10 chars)'
                          if ("$why".Trim().Length -lt 10) { Write-VmmLog 'Not skipped: the reason needs at least 10 characters.' -Level Warn; return }
                          Set-VmmTicketStep -HostName $HostName -Key $key -Status Skipped -Note "SKIPPED: $why" }) }
            'F'     { $out = Show-VmmFailureDialog -HostName $rec.Name -ActionId $a.Id; if ($out) { $status = $out } }
            'K'     { Show-VmmKnowledgeScreen -ActionId $a.Id }
            'L'     { [void](Invoke-VmmTuiAction -Title "Remote desktop - $($rec.Name)" -TicketHost $rec.Name -Action { Start-VmmRemoteSession -HostName $HostName -Client Ask }) }
            'T'     { [void](Invoke-VmmTuiAction -Title "Ticket for IT - $($rec.Name) / $($a.Name)" -Action {
                          $e = if ($st -and $st.Value.Status -in 'Failed', 'Blocked' -and $st.Value.Note) { $st.Value.Note } else { Read-VmmPrompt 'Exact error (paste it)' }
                          if ($e) { [void](New-VmmFailureTicket -Message $e -Activity "$($a.Name): $($a.Title)" -HostName $HostName -Step $(if ($builtin) { $a.Builtin })) } }) }
        }
    }
}
