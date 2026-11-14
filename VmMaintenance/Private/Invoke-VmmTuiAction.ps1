function Invoke-VmmTuiAction {
    # Runs an action with a normal scrolling console (tables, colours, prompts), shows any error in
    # red with cause/fix, then waits for a key or click before returning to the TUI.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][scriptblock]$Action, [switch]$NoPause)
    Clear-Host
    [Console]::CursorVisible = $true
    Show-VmmTuiHeader
    [Console]::SetCursorPosition(0, 4 + [Console]::WindowTop)
    Write-VmmLog "== $Title ==" -Level Info
    $ok = $true
    Suspend-VmmConsoleInput
    try { & $Action | Out-Host }
    catch {
        $ok = $false
        Write-VmmLog $_.Exception.Message -Level Error
        if ($_.FullyQualifiedErrorId -notlike 'Vmm*') { Write-VmmLog "At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -Level Muted }
    } finally { Resume-VmmConsoleInput }
    $script:VmmProgCache = $null
    if (-not $NoPause) {
        Write-Host ''
        Write-Host ' Press any key (or click) to return...' -ForegroundColor DarkGray -NoNewline
        do { $e = Read-VmmInput -TimeoutMs 500 } until ($e.Type -in 'Key', 'Click', 'DoubleClick')
    }
    Clear-Host
    $ok
}
