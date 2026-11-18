function Get-VmmUpgradePath {
    <#
    .SYNOPSIS
        Next step per host for SQL Server and Windows, from the last snapshot (Extractor result, fleet check or
        RDP collector): current Windows and SQL state, workflow position, and the ordered path to the target OS
        with the exact file and language for each step.
    .DESCRIPTION
        Read-only and offline. Cross-references each SQL instance's service pack with Microsoft's support table
        for every Windows hop on the way (Get-VmmSqlOsMatrix), so no step leaves SQL on an unsupported OS:
        SQL service pack first, then the Windows in-place hop(s) with the ISO in the OS install language, then
        the latest SQL CU. A SQL version that the target OS does not support is a blocker (SQL upgrade or
        migration first). Management warnings (Server 2008 non-R2, physical) come first until recorded.
        With dbatools installed the CU level and the latest CU KB are added (-NoBuildList skips that).
        Export it for the manager with Export-VmmUpgradePathReport (vmm path-report).
    .EXAMPLE
        Get-VmmUpgradePath -HostName srv01
    .EXAMPLE
        vmm path
    #>
    [CmdletBinding()]
    param([string[]]$HostName, [switch]$NoBuildList, [switch]$PassThru)
    $store = Read-VmmStore
    $recs = if ($HostName) { foreach ($n in $HostName) { Get-VmmHostRecord -Store $store -Name $n } } else { @($store.Hosts | Sort-Object Name) }
    $out = foreach ($r in @($recs)) { Get-VmmHostUpgradePath -Record $r -NoBuildList:$NoBuildList }
    $out = @($out)
    if ($PassThru) { return $out }
    foreach ($p in $out) {
        $lines = Format-VmmUpgradePath -Path $p
        Write-VmmColor $lines[0] -Role Accent
        foreach ($x in $lines[1..($lines.Count - 1)]) {
            $role = if ($x -match '\[Blocker\]') { 'Fail' } elseif ($x -match '^\s+(WARNING|NEXT)\b' -or $x -match '\[(Management|Restart)\]') { 'Warn' } elseif ($x -match '^\s+(file|note|ref)\s+:' -or $x -match '\[None\]') { 'Muted' } else { 'Text' }
            Write-VmmColor $x -Role $role
        }
        Write-Host ''
    }
    $blocked = @($out | Where-Object { @($_.Steps | Where-Object Kind -in 'Blocker', 'Management').Count })
    if ($blocked) { Write-VmmLog "$($blocked.Count) host(s) need a decision or a warning to management first: $(@($blocked.Host) -join ', ')" -Level Warn }
    Write-VmmLog 'For the manager e-mail: vmm path-report (text + CSV in Reports\UpgradePath).' -Level Muted
}
