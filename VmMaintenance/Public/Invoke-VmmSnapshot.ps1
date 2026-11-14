function Invoke-VmmSnapshot {
    <#
    .SYNOPSIS
        Informational snapshot of hosts, terminal first. Hands-on is proposed only for hosts the terminal
        cannot read, with the Extractor built and the steps listed.
    .DESCRIPTION
        1. Reads every host from this terminal (the read-only fleet check: DCOM, then WinRM, then WinRM-SSL).
        2. Hosts that answered are done: nothing to do by hand.
        3. For the others it says why each route failed, builds the any-host Extractor (snapshot only, no
           code that changes a host) and lists the hands-on steps. Results come back as VMM_<HOST>_*.vmm
           files that vmm imports by itself.
        Read-only everywhere, allowed any time.
    .PARAMETER NoExtractor
        Do not build the Extractor for the hosts that need hands-on; only report them.
    .EXAMPLE
        vmm snapshot                       # all hosts not on hold
    .EXAMPLE
        vmm snapshot -Name srv01
    #>
    [CmdletBinding()]
    param([string[]]$Name, [switch]$Azure, [switch]$NoExtractor, [switch]$PassThru)
    $p = @{ PassThru = $true; Azure = [bool]$Azure }
    if ($Name) { $p.Name = $Name }
    $results = @(Invoke-VmmFleetCheck @p)
    $manual = @($results | Where-Object { -not $_.Route -or $_.Route -eq 'None' } | Sort-Object Name)
    if (-not $manual) {
        Write-VmmLog 'Snapshot complete from the terminal. No hands-on needed.' -Level Success
    } else {
        Write-VmmLog '' -Level Plain
        Write-VmmLog "HANDS-ON NEEDED FOR $($manual.Count) HOST(S) - the terminal could not read them:" -Level Warn
        foreach ($m in $manual) { Write-VmmLog ("  {0,-18} {1}" -f $m.Name, $m.Error) -Level Plain }
        $down = @($manual | Where-Object { $_.Reachable -eq 'No' })
        if ($down) { Write-VmmLog "$($down.Count) of them gave no answer at all (no ping, no port): check they are up and on this VPN before opening RDP." -Level Info }
        if (-not $NoExtractor) {
            try { Export-VmmHostAgent -Generic | Out-Null }
            catch { Write-VmmLog "Extractor not built: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -Level Error }
            Write-VmmLog '4. Same file for every host in the list above. When done on a host: F in the Extractor removes it and its result file.' -Level Info
        }
    }
    if ($PassThru) { $results }
}
