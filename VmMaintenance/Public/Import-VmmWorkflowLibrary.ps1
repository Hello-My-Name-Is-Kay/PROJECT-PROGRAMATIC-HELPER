function Import-VmmWorkflowLibrary {
    <#
    .SYNOPSIS
        Merges a shared workflow library (workflows, actions, known fixes) into your encrypted workflows.vmm.
    .DESCRIPTION
        Same id: the newer copy wins (Updated time). Known fixes keep the higher Helped/NotHelped counters.
        Built-in items cannot be replaced. Library actions with an unknown category become Change (strictest
        gates) and only read-only actions may run on a host from a runbook.
    .EXAMPLE
        Import-VmmWorkflowLibrary -Path '\\server\share\vmm\vmm-library.json'
    #>
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Get-VmmSetting 'Workflow.LibraryPath' -Default '' }
    if (-not $Path) { throw (New-VmmErrorRecord -Activity 'No library path.' -Fix 'Give -Path, or set it once: vmm set -Name Workflow.LibraryPath -Value "\\server\share\vmm\vmm-library.json"' -Category InvalidArgument -ErrorId 'VmmLibraryPath') }
    $Path = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw (New-VmmErrorRecord -Activity 'Library file not found.' -Target $Path -Fix 'Check the share is reachable (VPN) and the path is right.' -Category ObjectNotFound -ErrorId 'VmmLibraryMissing') }
    $lib = Read-VmmWorkflowLibraryFile -Path $Path
    $ws = Read-VmmWorkflowStore
    $n = @{ New = 0; Updated = 0; Same = 0 }
    foreach ($p in 'Actions', 'Workflows', 'Kb') {
        foreach ($item in $lib.$p) {
            $old = $ws.$p | Where-Object { $_.Id -eq $item.Id } | Select-Object -First 1
            if (-not $old) { $ws.$p = @($ws.$p) + $item; $n.New++; continue }
            if ("$($item.Updated)" -gt "$($old.Updated)") {
                if ($p -eq 'Kb') { $item.Helped = [math]::Max([int]$item.Helped, [int]$old.Helped); $item.NotHelped = [math]::Max([int]$item.NotHelped, [int]$old.NotHelped) }
                $ws.$p = @($ws.$p | Where-Object { $_.Id -ne $item.Id }) + $item; $n.Updated++
            } else {
                if ($p -eq 'Kb') { $old.Helped = [math]::Max([int]$item.Helped, [int]$old.Helped); $old.NotHelped = [math]::Max([int]$item.NotHelped, [int]$old.NotHelped) }
                $n.Same++
            }
        }
    }
    $ws.LibraryImported = (Get-Date).ToUniversalTime().ToString('o')
    Save-VmmWorkflowStore -Store $ws
    Write-VmmLog ("Library imported from {0}: {1} new, {2} updated, {3} unchanged." -f $Path, $n.New, $n.Updated, $n.Same) -Level Success
    [pscustomobject]@{ Path = $Path; New = $n.New; Updated = $n.Updated; Unchanged = $n.Same }
}
