function Get-VmmAgentHealth {
    <#
    .SYNOPSIS
        Health and version of the security and monitoring agents on each host (Qualys, CrowdStrike,
        Zabbix, Ivanti, Lansweeper), from the last check or Extractor result.
    .DESCRIPTION
        OK   = service running, starts automatically, driver/port/log checks pass, version new enough.
        WARN = start type not Automatic, port not listening (or not reachable from the laptop), log
               not written for Agents.LogMaxAgeHours (48), version below Agents.MinVersion.<Agent>.
        FAIL = not installed, service not running, or a required driver is not running.
        What is checked per agent is in Resources\InventoryFields.psd1 (Agent = @{ ... }). Read-only.
    .EXAMPLE
        vmm agents                 # every host
    .EXAMPLE
        vmm agents -Problems       # only WARN and FAIL
    .EXAMPLE
        Get-VmmAgentHealth -HostName srv01
    #>
    [CmdletBinding()]
    param([string[]]$HostName, [switch]$Problems, [switch]$PassThru)
    $heads = @{}
    foreach ($f in (Get-VmmInventoryCatalog)) { $heads[$f.Key] = $f.Header }
    $rows = foreach ($h in @((Read-VmmStore).Hosts | Where-Object { -not $HostName -or $HostName -contains $_.Name } | Sort-Object Name)) {
        $c = $h.Check
        if (-not $c -or -not $c.PSObject.Properties['Agents'] -or -not $c.Agents) {
            if (-not $Problems) { [pscustomobject]@{ Host = $h.Name; Agent = '(all)'; Status = '?'; State = 'not read yet'; Start = ''; Version = ''; Issues = 'run Check (3) or the Extractor on the host'; Checked = '' } }
            continue
        }
        foreach ($p in $c.Agents.PSObject.Properties) {
            $a = $p.Value
            if ($Problems -and $a.Status -eq 'OK') { continue }
            [pscustomobject]@{ Host = $h.Name; Agent = $(if ($heads[$p.Name]) { $heads[$p.Name] } else { $p.Name }); Status = $a.Status; State = $a.State
                               Start = $a.StartMode; Version = $a.Version; Issues = $a.Issues; Checked = "$($c.CheckedAt)".Substring(0, [math]::Min(16, "$($c.CheckedAt)".Length)) }
        }
    }
    $rows = @($rows)
    if ($PassThru) { return $rows }
    if (-not $rows) { Write-VmmLog $(if ($Problems) { 'No agent problems in the last checks.' } else { 'No hosts in the fleet.' }) -Level Success; return }
    foreach ($r in $rows) {
        $lvl = switch ($r.Status) { 'OK' { 'Success' } 'WARN' { 'Warn' } 'FAIL' { 'Error' } default { 'Muted' } }
        $line = '{0,-18} {1,-20} {2,-5} {3,-14} {4,-9} {5,-16} {6}' -f $r.Host, $r.Agent, $r.Status, $r.State, $r.Start, $r.Version, $r.Issues
        # Status colour without the WARNING:/ERROR: prefix of log lines
        Add-VmmLogEntry -Text $line -Level $lvl
        Write-VmmColor $line -Role $(switch ($r.Status) { 'OK' { 'Ok' } 'WARN' { 'Warn' } 'FAIL' { 'Fail' } default { 'Muted' } })
    }
    $bad = @($rows | Where-Object { $_.Status -in 'WARN', 'FAIL' })
    Write-VmmLog ("{0} agent row(s): {1} FAIL, {2} WARN." -f $rows.Count, @($bad | Where-Object Status -eq 'FAIL').Count, @($bad | Where-Object Status -eq 'WARN').Count) -Level Info
}
