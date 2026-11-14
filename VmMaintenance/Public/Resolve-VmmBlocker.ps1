function Resolve-VmmBlocker {
    <#
    .SYNOPSIS
        Marks a host's open blockers as resolved (access granted) so its step can run again.
    .EXAMPLE
        Resolve-VmmBlocker -HostName srv01
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName, [string]$Step)
    $store = Read-VmmStore
    $rec = Get-VmmHostRecord -Store $store -Name $HostName
    $n = 0
    foreach ($b in $rec.Blockers) {
        if (-not $b.Resolved -and (-not $Step -or $b.Step -eq $Step)) { $b.Resolved = $true; $n++ }
    }
    foreach ($p in $rec.Steps.PSObject.Properties) {
        if ($p.Value.Status -eq 'Blocked' -and (-not $Step -or $p.Name -eq $Step)) { $p.Value.Status = 'Pending'; $p.Value.Note = 'Blocker resolved - ready to retry' }
    }
    Save-VmmStore -Store $store
    Write-VmmLog "$($rec.Name): $n blocker(s) resolved." -Level Success
}
