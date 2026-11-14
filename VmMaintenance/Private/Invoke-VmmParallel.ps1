function Invoke-VmmParallel {
    # Runs one script per input item in a runspace pool (works in 5.1 and 7, no ThreadJob needed).
    # -ScriptText receives ($Item, $Arguments) and must be self-contained (module functions are not visible).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$InputObject,
        [Parameter(Mandatory)][string]$ScriptText,
        [hashtable]$Arguments = @{},
        [int]$Throttle = 16,
        [string]$Activity = 'Working'
    )
    $pool = [runspacefactory]::CreateRunspacePool(1, [math]::Max(1, $Throttle))
    $pool.Open()
    $jobs = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($item in $InputObject) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($ScriptText).AddArgument($item).AddArgument($Arguments)
            $jobs.Add([pscustomobject]@{ Item = $item; PS = $ps; Handle = $ps.BeginInvoke() })
        }
        $done = 0
        foreach ($j in $jobs) {
            try {
                $out = $j.PS.EndInvoke($j.Handle)
                foreach ($o in $out) { $o }
                if (-not $out -and $j.PS.Streams.Error.Count) {
                    [pscustomobject]@{ Name = "$($j.Item)"; Error = "$($j.PS.Streams.Error[0])"; Reachable = 'No' }
                }
            } catch {
                [pscustomobject]@{ Name = "$($j.Item)"; Error = "Runspace failed: $($_.Exception.Message)"; Reachable = 'No' }
            } finally { $j.PS.Dispose() }
            $done++
            Write-Progress -Activity $Activity -Status "$done of $($jobs.Count)" -PercentComplete ([int](100 * $done / $jobs.Count))
        }
    } finally {
        Write-Progress -Activity $Activity -Completed
        $pool.Close(); $pool.Dispose()
    }
}
