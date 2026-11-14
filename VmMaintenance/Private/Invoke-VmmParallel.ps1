function Invoke-VmmParallel {
    # Runs one script per input item in a runspace pool (works in 5.1 and 7, no ThreadJob needed).
    # -ScriptText receives ($Item, $Arguments) and must be self-contained (module functions are not visible).
    # Live log: the script can report steps with  $Arguments.Trace.Enqueue("<item>: <step>")  ; every
    # finished item is logged with its duration, and every Log.HeartbeatSeconds (default 5) a summary
    # says how many are done and which items have been running longest, so a stuck host is visible.
    # Results come back in finishing order.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$InputObject,
        [Parameter(Mandatory)][string]$ScriptText,
        [hashtable]$Arguments = @{},
        [int]$Throttle = 16,
        [string]$Activity = 'Working'
    )
    $runArgs = $Arguments.Clone()
    $runArgs.Trace   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $runArgs.Started = [hashtable]::Synchronized(@{})
    $runArgs.Body    = $ScriptText
    # Wrapper records when an item really starts (queued items wait for a free runspace)
    $wrapper = 'param($Item, $A) $A.Started["$Item"] = [DateTime]::UtcNow; & ([scriptblock]::Create($A.Body)) $Item $A'
    $beat = 5
    try { $beat = [math]::Max(2, [int](Get-VmmSetting 'Log.HeartbeatSeconds' -Default 5)) } catch { }

    $pool = [runspacefactory]::CreateRunspacePool(1, [math]::Max(1, $Throttle))
    $pool.Open()
    $jobs = New-Object System.Collections.Generic.List[object]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $drain = {
        $m = $null
        while ($runArgs.Trace.TryDequeue([ref]$m)) { Write-VmmLog $m -Level Trace }
    }
    try {
        foreach ($item in $InputObject) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($wrapper).AddArgument($item).AddArgument($runArgs)
            $jobs.Add([pscustomobject]@{ Item = $item; PS = $ps; Handle = $ps.BeginInvoke() })
        }
        $total = $jobs.Count; $done = 0
        Write-VmmLog ("{0}: {1} item(s) started, {2} at a time" -f $Activity, $total, [math]::Max(1, $Throttle)) -Level Trace
        $nextBeat = $beat
        $pending = New-Object System.Collections.Generic.List[object]
        foreach ($j in $jobs) { $pending.Add($j) }
        while ($pending.Count) {
            & $drain
            foreach ($j in @($pending | Where-Object { $_.Handle.IsCompleted })) {
                $failed = $false
                try {
                    $out = $j.PS.EndInvoke($j.Handle)
                    foreach ($o in $out) { $o }
                    if (-not $out -and $j.PS.Streams.Error.Count) {
                        $failed = $true
                        [pscustomobject]@{ Name = "$($j.Item)"; Error = "$($j.PS.Streams.Error[0])"; Reachable = 'No' }
                    }
                } catch {
                    $failed = $true
                    [pscustomobject]@{ Name = "$($j.Item)"; Error = "Runspace failed: $($_.Exception.Message)"; Reachable = 'No' }
                } finally { $j.PS.Dispose() }
                [void]$pending.Remove($j)
                $done++
                $st = $runArgs.Started["$($j.Item)"]
                $took = if ($st) { ([DateTime]::UtcNow - $st).TotalSeconds } else { 0 }
                Write-VmmLog ("{0}: finished in {1:N1} s{2} ({3}/{4})" -f $j.Item, $took, $(if ($failed) { ', with an error' } else { '' }), $done, $total) -Level Trace
                Write-Progress -Activity $Activity -Status "$done of $total" -PercentComplete ([int](100 * $done / [math]::Max(1, $total)))
            }
            if (-not $pending.Count) { break }
            if ($sw.Elapsed.TotalSeconds -ge $nextBeat) {
                $nextBeat = $sw.Elapsed.TotalSeconds + $beat
                $now = [DateTime]::UtcNow
                $running = @(foreach ($j in $pending) { $st = $runArgs.Started["$($j.Item)"]; if ($st) { [pscustomobject]@{ Item = "$($j.Item)"; Sec = ($now - $st).TotalSeconds } } })
                $slow = (@($running | Sort-Object Sec -Descending | Select-Object -First 3 | ForEach-Object { '{0} {1:N0} s' -f $_.Item, $_.Sec })) -join ', '
                $msg = "{0}: {1}/{2} done, {3} running, {4} queued, {5:N0} s so far" -f $Activity, $done, $total, $running.Count, ($pending.Count - $running.Count), $sw.Elapsed.TotalSeconds
                if ($slow) { $msg += " - longest: $slow" }
                Write-VmmLog $msg -Level Trace
            }
            # F2 works here too (the menu keys are paused while an action runs)
            try {
                if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.Key -eq 'F2') { $on = Switch-VmmLogLive; Write-Host ("Live log {0}." -f $(if ($on) { 'on' } else { 'off (still written to the file)' })) -ForegroundColor DarkGray } }
            } catch { }
            Start-Sleep -Milliseconds 150
        }
        & $drain
        Write-VmmLog ("{0}: all {1} finished in {2:N1} s" -f $Activity, $total, $sw.Elapsed.TotalSeconds) -Level Trace
    } finally {
        Write-Progress -Activity $Activity -Completed
        foreach ($j in $jobs) { try { if (-not $j.Handle.IsCompleted) { $j.PS.Stop() }; $j.PS.Dispose() } catch { } }
        $pool.Close(); $pool.Dispose()
    }
}
