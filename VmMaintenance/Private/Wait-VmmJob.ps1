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
    # Live log: who is still running, every Log.HeartbeatSeconds (Azure jobs can take minutes)
    $beat = 5
    try { $beat = [math]::Max(2, [int](Get-VmmSetting 'Log.HeartbeatSeconds' -Default 5)) } catch { }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $next = $beat; $seen = @{}
    while ($true) {
        $running = @($withJob | Where-Object { $_.Job.State -in 'NotStarted', 'Running' })
        foreach ($p in $withJob) {
            if ($p.Job.State -notin 'NotStarted', 'Running' -and -not $seen[$p.Job.Id]) {
                $seen[$p.Job.Id] = $true
                Write-VmmLog ("{0}: {1} {2} after {3:N0} s" -f $p.VMName, $Label, $p.Job.State.ToString().ToLower(), $sw.Elapsed.TotalSeconds) -Level Trace
            }
        }
        if (-not $running) { break }
        if ($sw.Elapsed.TotalSeconds -ge $next) {
            $next = $sw.Elapsed.TotalSeconds + $beat
            Write-VmmLog ("{0}: {1}/{2} finished, {3:N0} s so far - waiting on {4}" -f $Label, ($withJob.Count - $running.Count), $withJob.Count, $sw.Elapsed.TotalSeconds, ((@($running | Select-Object -First 5 | ForEach-Object { $_.VMName })) -join ', ')) -Level Trace
        }
        Start-Sleep -Milliseconds 500
    }
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
