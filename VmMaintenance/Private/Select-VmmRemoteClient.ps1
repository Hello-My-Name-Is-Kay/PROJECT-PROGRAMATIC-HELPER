function Select-VmmRemoteClient {
    # Picks the remote desktop client for a host: -Client Rdp|Rdm|RdcMan|None, or Ask (numbered choice of
    # what is installed), or Default (= Handoff.Client, 'Ask' when not set). Returns the Get-VmmRemoteClient
    # row, or $null for None ("I connect myself").
    [CmdletBinding()]
    param([ValidateSet('Default', 'Ask', 'Rdp', 'Rdm', 'RdcMan', 'None')][string]$Client = 'Default', [string]$For = 'the host')
    if ($Client -eq 'Default') { $Client = "$(Get-VmmSetting 'Handoff.Client' -Default 'Ask')" }
    if ($Client -notin 'Ask', 'Rdp', 'Rdm', 'RdcMan', 'None') { $Client = 'Ask' }
    if ($Client -eq 'None') { return $null }
    $all = @(Get-VmmRemoteClient)
    if ($Client -ne 'Ask') {
        $c = $all | Where-Object Name -eq $Client
        if (-not $c.Available) {
            throw (New-VmmErrorRecord -Activity "$($c.Label) is not available on this laptop." -Cause $c.Why `
                -Fix 'Pick another client (-Client Rdp | Rdm | RdcMan | None), or set its path in Settings (Handoff).' -Category ObjectNotFound -ErrorId 'VmmRemoteClientMissing')
        }
        return $c
    }
    $first = $all | Where-Object Available | Select-Object -First 1
    if (-not (Test-VmmInteractive)) { return $first }
    Write-VmmLog "How do you want to open $For?" -Level Info
    for ($i = 0; $i -lt $all.Count; $i++) {
        $c = $all[$i]
        Write-VmmLog ('  {0}  {1}{2}' -f ($i + 1), $c.Label, $(if (-not $c.Available) { "  - not available: $($c.Why)" })) -Level $(if ($c.Available) { 'Plain' } else { 'Muted' })
    }
    Write-VmmLog '  0  None: I open the session myself (vmm still shows the steps and verifies)' -Level Plain
    $def = if ($first) { [array]::IndexOf($all, $first) + 1 } else { 0 }
    while ($true) {
        $a = "$(Read-VmmPrompt "Choice [default $def]")".Trim()
        if (-not $a) { $a = "$def" }
        if ($a -eq '0') { Write-VmmLog 'Remote client: none (operator connects)' -Level Muted -FileOnly; return $null }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $all.Count) {
            if ($all[$n - 1].Available) { Write-VmmLog "Remote client: $($all[$n - 1].Name)" -Level Muted -FileOnly; return $all[$n - 1] }
            Write-VmmLog "$($all[$n - 1].Label) is not available: $($all[$n - 1].Why)" -Level Warn
        } else { Write-VmmLog "Type a number from 0 to $($all.Count)." -Level Warn }
    }
}
