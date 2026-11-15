function Show-VmmHostScreen {
    # One host: facts + the six workflow steps. Run steps, open the RDP guide, paste collector output,
    # raise a blocker and move on, open RDP/RDM/RDCMan, stage by hand with checks (T), hold/unhold.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName)
    $sel = 0; $status = ''
    while ($true) {
        $store = Read-VmmStore
        $rec = Get-VmmHostRecord -Store $store -Name $HostName
        $w = Get-VmmTimeWindow
        $steps = @(Get-VmmWorkflowDefinition)
        $c = $rec.Check
        $acc = Get-VmmHostAccess -Record $rec
        $via = if ($acc.Terminal -eq $true) { "terminal: $($acc.Route)" } elseif ($acc.Terminal -eq $false) { 'terminal: NO ROUTE (hands-on)' } else { 'terminal: not tried' }
        $facts = "$($rec.Name) | $($rec.Platform) | $($rec.Health) | $via | $(if ($c) { "$($c.OS) b$($c.Build) | C: $($c.CFreeGB) GB free | SQL: $($c.Sql) | reboot pending: $($c.PendingReboot)" } else { 'not checked yet' })$(if ($rec.Hold) { ' | ON HOLD' })"
        $rows = foreach ($s in $steps) {
            $st = $rec.Steps.PSObject.Properties[$s.Name]
            $state = if ($st) { $st.Value.Status } else { '-' }
            $note  = if ($st) { $st.Value.Note } else { $s.Title }
            $allowed = $s.Class -ne 'Change' -or $w.ChangesAllowed
            $col = switch -Regex ($state) { '^(Success|NotNeeded)$' { 'Green' } '^(Failed|Blocked)$' { 'Red' } '^(Launched|Skipped|Pending)$' { 'Yellow' } default { if ($allowed) { 'Gray' } else { 'DarkGray' } } }
            $mode = if ($s.Mode -eq 'Hybrid') { if ($rec.Azure) { 'auto' } else { 'guided' } } else { $s.Mode.ToLower() }
            @{ Text = ('{0}. {1,-12} {2,-10} {3,-7} {4,-8} {5}' -f $s.Order, $s.Name, $state, $mode, $(if ($allowed) { 'now' } else { 'window' }), $note); Color = $col }
        }
        $pol = Get-VmmHostPolicy -Record $rec
        if (-not $status) {
            if (-not $pol.Workable) { $status = "POLICY: $($pol.Why)" }
            elseif ($pol.Warnings) { $status = "WARN MANAGEMENT: $($pol.Warnings -join ' | ') (vmm policy -Notice)" }
        }
        if (-not $status -and $acc.Terminal -eq $false) { $status = "No terminal route: $($acc.Why)" }
        if (-not $status -and $null -eq $acc.Terminal) { $status = 'Press S: snapshot from the terminal first. Hands-on (X) only if that fails.' }
        if (-not $status -and $c -and $c.PSObject.Properties['Problems'] -and $c.Problems) { $status = "Snapshot gaps: $($c.Problems)" }
        if (-not $status -and $c -and $c.PSObject.Properties['Agents'] -and $c.Agents) {
            $ab = @($c.Agents.PSObject.Properties | Where-Object { $_.Value.Status -ne 'OK' } | ForEach-Object { "$($_.Name) $($_.Value.Status)" })
            if ($ab) { $status = "Agents: $($ab -join ', ') (A for detail)" }
        }
        $open = @($rec.Blockers | Where-Object { -not $_.Resolved })
        if ($open) { $status = "Open blocker: $($open[-1].Step) - $($open[-1].Summary) (contact: $($open[-1].Contact))" }
        $r = Invoke-VmmListView -Title $facts -ColumnHeader ('   {0,-12} {1,-10} {2,-7} {3,-8} {4}' -f 'Step', 'Status', 'Mode', 'Allowed', 'Note') `
             -Rows @($rows) -Selected $sel -Status $status -Hotkeys @('G', 'P', 'B', 'R', 'L', 'H', 'C', 'Y', 'X', 'I', 'A', 'S', 'T') `
             -Help 'Enter run | S snapshot (terminal first) | G guide | X extractor | Y confirm | P import result | B blocker | R resolve | L remote desktop | T stage by hand (RDP/RDM) | H hold | C check | I inventory | A agents | Esc'
        $sel = $r.Index; $status = ''
        $step = $steps[$r.Index].Name
        switch ($r.Action) {
            'Esc'   { return }
            'Enter' { [void](Invoke-VmmTuiAction -Title "$HostName - $step" -Action { Invoke-VmmStepFromTui -HostName $HostName -Step $step }) }
            'Y'     { [void](Invoke-VmmTuiAction -Title "$HostName - confirm $step done" -Action { Invoke-VmmStepFromTui -HostName $HostName -Step $step -Confirmed }) }
            'G'     { Show-VmmGuideScreen -HostName $HostName -Step $step }
            'X'     { [void](Invoke-VmmTuiAction -Title "Extractor for $HostName" -Action { Export-VmmHostAgent -HostName $HostName }) }
            'P'     { [void](Invoke-VmmTuiAction -Title 'Paste collector result' -Action {
                          $clip = try { (Get-Clipboard) -join '' } catch { '' }
                          if ($clip -match '^VMM[12]\|') { Import-VmmCollectorResult -Line $clip; return }
                          $r = Import-VmmResultInbox -PassThru
                          if (@($r.Imported | Where-Object Host -eq $HostName).Count) { return }
                          $clip = Read-VmmPrompt 'No result file for this host on Desktop/Downloads. Paste the VMM2|... line, or a .vmm file path'
                          if ($clip -and (Test-Path -LiteralPath $clip.Trim('"') -PathType Leaf)) { Import-VmmCollectorResult -Path $clip.Trim('"') }
                          elseif ($clip) { Import-VmmCollectorResult -Line $clip } }) }
            'B'     { [void](Invoke-VmmTuiAction -Title "Blocker report - $HostName / $step" -Action {
                          $m = Read-VmmPrompt 'Exact error or what is missing (paste it)'
                          if ($m) { New-VmmBlockerReport -HostName $HostName -Step $step -Message $m | Out-Null } }); return }
            'R'     { [void](Invoke-VmmTuiAction -Title 'Resolve blockers' -Action { Resolve-VmmBlocker -HostName $HostName }) }
            'L'     { [void](Invoke-VmmTuiAction -Title "Remote desktop - $HostName" -Action { Start-VmmRemoteSession -HostName $HostName -Client Ask }) }
            'T'     { [void](Invoke-VmmTuiAction -Title "Stage by hand over remote desktop - $HostName" -Action { Start-VmmRemoteHandoff -HostName $HostName | Select-Object HostName, Client, Verified, VerifiedBy }) }
            'H'     { $rec.Hold = -not $rec.Hold; Save-VmmStore -Store $store; $status = "Hold = $($rec.Hold)" }
            'S'     { [void](Invoke-VmmTuiAction -Title "Snapshot $HostName (terminal first)" -Action { Invoke-VmmSnapshot -Name $HostName }) }
            'C'     { [void](Invoke-VmmTuiAction -Title "Check $HostName" -Action { Invoke-VmmFleetCheck -Name $HostName }) }
            'I'     { Show-VmmInventoryScreen -HostName $HostName }
            'A'     { [void](Invoke-VmmTuiAction -Title "Agent health - $HostName" -Action { Get-VmmAgentHealth -HostName $HostName }) }
        }
    }
}
