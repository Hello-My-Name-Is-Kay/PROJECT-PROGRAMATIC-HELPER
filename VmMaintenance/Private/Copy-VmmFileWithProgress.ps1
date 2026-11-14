function Copy-VmmFileWithProgress {
    # Copies one file in 4 MB blocks and logs progress (done/total, MB/s, time left) every
    # Log.HeartbeatSeconds, so a multi-GB ISO copy over the network never looks stuck.
    # Writes to <dest>.part first and renames at the end: a broken copy never looks complete.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [string]$Label = '')
    $beat = 5
    try { $beat = [math]::Max(2, [int](Get-VmmSetting 'Log.HeartbeatSeconds' -Default 5)) } catch { }
    if (-not $Label) { $Label = [IO.Path]::GetFileName($Source) }
    $part = "$Destination.part"
    $in = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $out = [IO.File]::Open($part, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $total = $in.Length; $doneB = [long]0
            $buf = New-Object byte[] (4MB)
            $sw = [Diagnostics.Stopwatch]::StartNew(); $next = $beat
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $doneB += $n
                if ($sw.Elapsed.TotalSeconds -ge $next) {
                    $next = $sw.Elapsed.TotalSeconds + $beat
                    $rate = $doneB / [math]::Max(0.001, $sw.Elapsed.TotalSeconds)
                    $left = if ($rate -gt 0) { [TimeSpan]::FromSeconds(($total - $doneB) / $rate) } else { [TimeSpan]::Zero }
                    Write-VmmLog ("{0}: {1:N0}/{2:N0} MB ({3}%), {4:N1} MB/s, about {5} left" -f $Label, ($doneB / 1MB), ($total / 1MB), [int](100 * $doneB / [math]::Max(1, $total)), ($rate / 1MB), $left.ToString('hh\:mm\:ss')) -Level Trace
                    Write-Progress -Activity "Copy $Label" -Status ('{0:N0} of {1:N0} MB' -f ($doneB / 1MB), ($total / 1MB)) -PercentComplete ([int](100 * $doneB / [math]::Max(1, $total)))
                }
            }
        } finally { $out.Dispose() }
    } catch {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        throw
    } finally { $in.Dispose(); Write-Progress -Activity "Copy $Label" -Completed }
    Move-Item -LiteralPath $part -Destination $Destination -Force
    Write-VmmLog ("{0}: copied {1:N0} MB in {2:N0} s" -f $Label, ($total / 1MB), $sw.Elapsed.TotalSeconds) -Level Trace
}
