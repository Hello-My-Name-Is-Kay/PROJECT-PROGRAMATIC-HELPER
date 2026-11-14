function Wait-VmmJob {
    # Waits for the .Job on each item. A failed job sets Status = Failed and records why in Notes,
    # unless -KeepStatus (then only the note is added).
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Item,
        [Parameter(Mandatory)][string]$Label,
        [switch]$KeepStatus
    )
    $withJob = @($Item | Where-Object { $_.Job })
    if (-not $withJob) { return }
    $withJob | ForEach-Object { $_.Job } | Wait-Job | Out-Null
    foreach ($p in $withJob) {
        $jerr = $null
        Receive-Job $p.Job -ErrorVariable jerr -ErrorAction SilentlyContinue | Out-Null
        if ($p.Job.State -ne 'Completed' -or $jerr) {
            $reason = if ($jerr) { "$($jerr[0])" } else { "$($p.Job.ChildJobs[0].JobStateInfo.Reason.Message)" }
            if (-not $KeepStatus) { $p.Status = 'Failed' }
            $p.Notes += (ConvertTo-VmmNote -Activity $Label -ErrorRecord ([System.Exception]::new($reason))) + '; '
            Write-VmmLog "$($p.VMName): $Label failed - $reason" -Level Error
        }
        Remove-Job $p.Job -Force
        $p.Job = $null
    }
}
