function Import-VmmRunbookResult {
    <#
    .SYNOPSIS
        Records what a host runbook reported (VMMW_<HOST>_<time>.txt, or its text from the clipboard).
    .DESCRIPTION
        Lines: VMMW1 header, S (step result), G (gate passed), O (override), K (new known fix), H (a known fix
        helped or not). Rules: only steps of this host's current workflow are recorded; the vmm maintenance steps
        (Precheck, SnapStart, ...) are never set from a host file (vmm records those itself, as for the
        Extractor) - they go to the history as a note. A Change step reported done without a gate line is
        recorded as Pending (confirm it on the laptop). Overrides are added to the daily report. New known fixes
        are made shareable (no host names) and added to your library.
    .EXAMPLE
        Import-VmmRunbookResult -Path "$env:USERPROFILE\Desktop\VMMW_SRV01_20261117-2130.txt"
    #>
    [CmdletBinding()]
    param([string]$Path, [string]$Text)
    if ($Path) { $Text = [IO.File]::ReadAllText(($Path.Trim().Trim('"'))) }
    if (-not $Text) { $Text = try { (Get-Clipboard) -join "`n" } catch { '' } }
    $lines = @("$Text" -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $hi = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -like 'VMMW1|*') { $hi = $i; break } }
    if ($hi -lt 0) { throw (New-VmmErrorRecord -Activity 'No runbook result (VMMW1 line) found.' -Fix 'Copy the whole VMMW_*.txt file from the host, or give -Path.' -Category InvalidData -ErrorId 'VmmRunbookResult') }
    $h = $lines[$hi] -split '\|'
    $dec = { param($s) if (-not $s) { return '' }; try { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) } catch { '' } }
    $store = Read-VmmStore
    $rec = Get-VmmHostRecord -Store $store -Name $h[1]
    $cat = Get-VmmWorkflowCatalog
    $res = Resolve-VmmHostWorkflow -Record $rec -Catalog $cat
    $byKey = @{}; foreach ($s in $res.Steps) { $byKey[$s.Key] = $s }
    $gated = @{}; $n = @{ Steps = 0; Ignored = 0; Kb = 0; Overrides = 0 }
    $ws = $cat.Store; $wsDirty = $false
    $names = @(Get-VmmFleetName -Store $store)
    $body = if ($hi + 1 -lt $lines.Count) { @($lines[($hi + 1)..($lines.Count - 1)]) } else { @() }
    foreach ($l in $body) { $f = $l -split '\|'; if ($f[0] -eq 'G' -and $f.Count -ge 3) { $gated[$f[1]] = & $dec $f[2] } }   # gates first: order in the file does not matter
    foreach ($l in $body) {
        $f = $l -split '\|'
        switch ($f[0]) {
            'O' {
                $store.Overrides = @($store.Overrides) + [pscustomobject]@{ At = (Get-Date).ToUniversalTime().ToString('o'); Target = "$($rec.Name)/$($f[1] -replace '^W:', '') (runbook on host)"; Reason = (Protect-VmmLogText (& $dec $f[2])); Mode = 'runbook' }
                $n.Overrides++
            }
            'S' {
                $key = $f[1]; $status = $f[2]; $note = Protect-VmmLogText (& $dec $f[4])
                $s = $byKey[$key]
                if (-not $s -or $status -notin 'Success', 'Failed', 'Skipped') { $n.Ignored++; Write-VmmLog "Ignored: '$key' is not a step of this ticket's workflow now." -Level Warn; continue }
                if ($s.Action.Builtin) {
                    $rec.History = @($rec.History) + [pscustomobject]@{ At = (Get-Date).ToUniversalTime().ToString('o'); Step = 'Runbook'; Result = 'Note'; Note = "host runbook reported $key $status (not applied: vmm records maintenance steps itself): $note" }
                    $n.Ignored++; continue
                }
                if ($status -eq 'Success' -and $s.Action.Category -ne 'ReadOnly' -and -not $gated.ContainsKey($key)) { $status = 'Pending'; $note = "reported done on the host WITHOUT the gate - confirm it here (D): $note" }
                elseif ($gated.ContainsKey($key)) { $note = "gate: $($gated[$key]) | $note" }
                Set-VmmStepState -Record $rec -Step $key -Status $status -Note "$note (host runbook)"
                $n.Steps++
            }
            'K' {
                $fx = @((& $dec $f[4]) -split "`n" | Where-Object { $_ })
                if ($fx -and ($cat.Actions | Where-Object Id -eq $f[1])) { [void](Add-VmmKnowledgeEntry -WorkflowStore $ws -ActionId $f[1] -Symptom (& $dec $f[2]) -Cause (& $dec $f[3]) -Fix $fx -Names ($names + $rec.Name)); $n.Kb++; $wsDirty = $true }
            }
            'H' {
                $k = $ws.Kb | Where-Object Id -eq $f[1] | Select-Object -First 1
                if ($k) { if ($f[2] -eq '1') { $k.Helped = [int]$k.Helped + 1 } else { $k.NotHelped = [int]$k.NotHelped + 1 }; $wsDirty = $true }
            }
        }
    }
    (Initialize-VmmTicket -Record $rec).Updated = (Get-Date).ToUniversalTime().ToString('o')
    Save-VmmStore -Store $store
    if ($wsDirty) { Save-VmmWorkflowStore -Store $ws }
    Write-VmmLog ("Runbook result for {0}: {1} step(s) recorded, {2} not applied, {3} known fix(es) added, {4} override(s)." -f $rec.Name, $n.Steps, $n.Ignored, $n.Kb, $n.Overrides) -Level $(if ($n.Ignored) { 'Warn' } else { 'Success' })
    Get-VmmTicket -Filter $rec.Name -Store $store -Catalog (Get-VmmWorkflowCatalog)
}
