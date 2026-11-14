function Invoke-VmmTuiAction {
    # Runs an action with a normal scrolling console (tables, colours, prompts), shows any error in
    # red with cause/fix, then waits for a key or click before returning to the TUI. The scrolling
    # area is the live log here: long operations print time-stamped progress lines (F2 turns them
    # off). Start, result, duration and the printed output also go to the log file.
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
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = $null
    Suspend-VmmConsoleInput
    try { & $Action | Tee-Object -Variable out | Out-Host }
    catch {
        $ok = $false
        Write-VmmLog $_.Exception.Message -Level Error
        if ($_.FullyQualifiedErrorId -notlike 'Vmm*') { Write-VmmLog "At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -Level Muted }
        Write-VmmErrorLog -ErrorRecord $_ -Command "ui: $Title"
    } finally { Resume-VmmConsoleInput }
    $sw.Stop()
    # What the screen showed as tables goes to the file too (first 200 lines)
    if ($out) {
        try {
            $text = @(($out | Out-String -Width 220) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 200)
            foreach ($l in $text) { Add-VmmLogEntry -Text (Protect-VmmLogText $l.TrimEnd()) -Level Output }
        } catch { }
    }
    $verdict = if ($ok) { 'done' } else { 'FAILED' }
    Write-VmmLog ("{0} {1} in {2:N1} s" -f $Title, $verdict, $sw.Elapsed.TotalSeconds) -Level $(if ($ok) { 'Muted' } else { 'Error' }) -FileOnly
    $script:VmmProgCache = $null
    if (-not $NoPause) {
        Write-Host ''
        Write-VmmColor (' Press any key (or click) to return...  ({0:N1} s)' -f $sw.Elapsed.TotalSeconds) -Role Muted -NoNewline
        do { $e = Read-VmmInput -TimeoutMs 500 } until ($e.Type -in 'Key', 'Click', 'DoubleClick')
    }
    Clear-Host
    $ok
}
