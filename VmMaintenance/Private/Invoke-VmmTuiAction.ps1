function Invoke-VmmTuiAction {
    # Runs an action with a normal scrolling console (tables, colours, prompts), shows any error in
    # red with cause/fix, then waits for a key or click before returning to the TUI. The scrolling
    # area is the live log here: long operations print time-stamped progress lines (F2 turns them
    # off). Start, result, duration and the printed output also go to the log file; Ctrl+C (which ends the
    # whole console) is logged as INTERRUPTED with the time it ran. After a failure, T writes advice and a ticket
    # text for the IT person who can fix it (New-VmmFailureTicket; -TicketHost/-TicketStep fill in the target).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][scriptblock]$Action, [switch]$NoPause, [string]$TicketHost, [string]$TicketStep)
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
    $failure = $null
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
        $failure = $_
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
        if ($failure) {
            # A failure the user cannot fix alone: advice + a ticket text for the IT person who can (New-VmmFailureTicket)
            Write-VmmColor ' T = advice + a ticket for the IT person who can fix this (file + clipboard, you send it)' -Role Warn
        }
        Write-VmmColor (' Press any key (or click) to return...  ({0:N1} s)' -f $sw.Elapsed.TotalSeconds) -Role Muted -NoNewline
        do { $e = Read-VmmInput -TimeoutMs 500 } until ($e.Type -in 'Key', 'Click', 'DoubleClick')
        if ($failure -and $e.Type -eq 'Key' -and "$($e.Char)" -match '^[tT]$') {
            Write-Host ''
            Suspend-VmmConsoleInput
            try {
                $tp = @{ Message = "$($failure.Exception.Message)"; Activity = $Title; ErrorId = "$($failure.FullyQualifiedErrorId)" }
                if ($TicketHost) { $tp.HostName = $TicketHost }
                if ($TicketStep) { $tp.Step = $TicketStep }
                [void](New-VmmFailureTicket @tp)
            } catch { Write-VmmLog "Ticket not written: $($_.Exception.Message)" -Level Error } finally { Resume-VmmConsoleInput }
            Write-VmmColor ' Press any key (or click) to return...' -Role Muted -NoNewline
            do { $e = Read-VmmInput -TimeoutMs 500 } until ($e.Type -in 'Key', 'Click', 'DoubleClick')
        }
    }
    Clear-Host
    $ok
}
