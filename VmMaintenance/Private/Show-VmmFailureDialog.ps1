function Show-VmmFailureDialog {
    # A step failed: 1. you paste what happened (recorded, step = Failed); 2. vmm shows the known fixes that match,
    # best first, each as a dialogue (Y fixed it -> the step goes back to Pending to do again, N did not help ->
    # the next one); 3. nothing helped: advice from the error text, then record how you fixed it (for the next
    # person), a ticket for the IT person who can fix it, or Blocked (ticket + step Blocked) and move on.
    # Returns a status line for the calling screen.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][string]$ActionId)
    $cat = Get-VmmWorkflowCatalog
    $a = $cat.Actions | Where-Object Id -eq $ActionId | Select-Object -First 1
    if (-not $a) { return '' }
    $key = Get-VmmStepKey -Action $a
    $script:VmmFailText = $null
    [void](Invoke-VmmTuiAction -Title "$HostName - $($a.Name) failed" -NoPause -Action {
        Write-VmmLog 'Paste the exact error, or describe what you saw. It is recorded on the ticket.' -Level Info
        $t = Read-VmmPrompt 'What happened'
        if (-not $t) { Write-VmmLog 'Nothing typed: nothing recorded.' -Level Muted; return }
        Set-VmmTicketStep -HostName $HostName -Key $key -Status Failed -Note $t
        $script:VmmFailText = $t
    })
    $err = $script:VmmFailText; $script:VmmFailText = $null
    if (-not $err) { return '' }
    $tried = @()
    while ($true) {
        $matches2 = @(Find-VmmKnowledge -Catalog (Get-VmmWorkflowCatalog) -ActionId $a.Id -Text $err | Where-Object { $tried -notcontains $_.Entry.Id })
        if (-not $matches2.Count) { break }
        $pick = Select-VmmFromList -Title "Suggested resolutions for '$($a.Name)' ($($matches2.Count)) - recorded by technicians before you" -Items $matches2 `
                -Label { param($x) '+{0,-3} -{1,-3} {2}' -f [int]$x.Entry.Helped, [int]$x.Entry.NotHelped, $x.Entry.Symptom } `
                -Help 'Enter open the fix | Esc none of these' -Status "Your error: $err"
        if (-not $pick) { break }
        $tried += $pick.Entry.Id
        $o = Show-VmmKnowledgeEntry -EntryId $pick.Entry.Id -Ask
        if ($o -eq 'Fixed') {
            Set-VmmTicketStep -HostName $HostName -Key $key -Status Pending -Note "fixed with known fix: $($pick.Entry.Symptom) - do the step again" 6>$null
            return "Fixed with a known fix: do '$($a.Name)' again, then D"
        }
    }
    $script:VmmFailOut = ''
    [void](Invoke-VmmTuiAction -Title "$HostName - $($a.Name): no known fix solved it" -TicketHost $HostName -Action {
        $h = Get-VmmErrorHint -Message $err
        if ($h) { Write-VmmLog "Likely cause: $($h.Cause)" -Level Info; Write-VmmLog "Try: $($h.Fix)" -Level Info }
        $req = Get-VmmAccessRequirement -Message $err -Target $HostName
        if ($req) { Write-VmmLog "This needs access you cannot give yourself: $($req.Needed)" -Level Warn }
        Write-VmmLog 'R = you fixed it: record how, for the next technician (the step goes to Pending, do it again)' -Level Plain
        Write-VmmLog 'T = write a ticket for the IT person who can fix it (file + clipboard, you send it)' -Level Plain
        Write-VmmLog 'B = blocked: write that ticket AND mark the step Blocked, then move on to the next host' -Level Plain
        Write-VmmLog 'Enter = leave it Failed for now' -Level Muted
        switch -Regex ((Read-VmmPrompt 'Choice').Trim()) {
            '^[rR]$' { $script:VmmFailOut = 'R' }
            '^[tT]$' { [void](New-VmmFailureTicket -Message $err -Activity "$($a.Name): $($a.Title)" -HostName $HostName -Step $(if ($a.Builtin) { $a.Builtin })); $script:VmmFailOut = 'T' }
            '^[bB]$' { $f = New-VmmFailureTicket -Message $err -Activity "$($a.Name): $($a.Title)" -HostName $HostName -Step $(if ($a.Builtin) { $a.Builtin })
                       Set-VmmTicketStep -HostName $HostName -Key $key -Status Blocked -Note "waiting for IT: $([IO.Path]::GetFileName($f.File)) - $err"; $script:VmmFailOut = 'B' }
        }
    })
    $choice = $script:VmmFailOut; $script:VmmFailOut = $null
    switch ($choice) {
        'R' { $e = Edit-VmmKnowledgeFromTui -ActionId $a.Id -Symptom $err -HostName $HostName
              if ($e) { Set-VmmTicketStep -HostName $HostName -Key $key -Status Pending -Note "fixed: $($e.Symptom) - do the step again" 6>$null; return 'Known fix recorded: do the step again, then D' }
              return 'Left Failed' }
        'T' { return 'Ticket for IT written (Reports\Tickets, on the clipboard). Step stays Failed.' }
        'B' { return 'Step Blocked, ticket for IT written: move on to the next host' }
    }
    'Left Failed: K shows known fixes, T writes a ticket for IT'
}
