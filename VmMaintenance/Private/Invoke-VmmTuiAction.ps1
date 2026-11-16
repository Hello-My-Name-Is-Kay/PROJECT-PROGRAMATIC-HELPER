function Invoke-VmmTuiAction {
    # Runs an action with a normal scrolling console (tables, colours, prompts), shows any error in
    # red with cause/fix, then waits for a key or click before returning to the TUI. The scrolling
    # area is the live log here: long operations print time-stamped progress lines (F2 turns them
    # off). Start, result, duration and the printed output also go to the log file; Ctrl+C (which ends the
    # whole console) is logged as INTERRUPTED with the time it ran.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][scriptblock]$Action, [switch]$NoPause)
    $script:VmmTuiListActive = $false
    Clear-Host
    [Console]::CursorVisible = $true
    Show-VmmTuiHeader
    [Console]::SetCursorPosition(0, 4 + [Console]::WindowTop)
    Add-VmmLogEntry -Text "== $Title ==" -Level Info
    Write-VmmColor " $Title" -Role Accent
    Write-VmmColor (' ' + ('-' * [math]::Min(100, [math]::Max(10, [Console]::WindowWidth - 3)))) -Role Muted
    if (Test-VmmLogLive) { Write-VmmLog 'Live log on: progress lines are time-stamped (F2 on a menu turns them off).' -Level Muted -FileOnly }
    $ok = $true
    $ended = $false   # stays $false only when Ctrl+C stopped the action (catch blocks do not run then, finally does)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Suspend-VmmConsoleInput
    try {
        & $Action | Out-VmmHost
        $ended = $true
    } catch {
        $ended = $true
        $ok = $false
        Write-VmmLog $_.Exception.Message -Level Error
        if ($_.FullyQualifiedErrorId -notlike 'Vmm*') { Write-VmmLog "At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -Level Muted }
        Write-VmmErrorLog -ErrorRecord $_ -Command "ui: $Title"
    } finally {
        $sw.Stop()
        if ($ended) {
            $verdict = if ($ok) { 'done' } else { 'FAILED' }
            Write-VmmLog ("{0} {1} in {2:N1} s" -f $Title, $verdict, $sw.Elapsed.TotalSeconds) -Level $(if ($ok) { 'Muted' } else { 'Error' }) -FileOnly
        } else {
            Add-VmmLogEntry -Text ("{0} INTERRUPTED (Ctrl+C) after {1:N1} s: check what it changed before running it again" -f $Title, $sw.Elapsed.TotalSeconds) -Level Error
        }
        Resume-VmmConsoleInput
    }
    $script:VmmProgCache = $null
    if (-not $NoPause) {
        Write-Host ''
        Write-VmmColor (' Press any key (or click) to return...  ({0:N1} s)' -f $sw.Elapsed.TotalSeconds) -Role Muted -NoNewline
        do { $e = Read-VmmInput -TimeoutMs 500 } until ($e.Type -in 'Key', 'Click', 'DoubleClick')
    }
    Clear-Host
    $ok
}
