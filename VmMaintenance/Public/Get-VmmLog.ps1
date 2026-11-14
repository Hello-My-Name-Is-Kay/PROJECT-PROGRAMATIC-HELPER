function Get-VmmLog {
    <#
    .SYNOPSIS
        Shows the vmm log: everything the console UI and the CLI did, with live progress lines.
    .DESCRIPTION
        One file per day in the logs folder next to the data folder (vmm_yyyyMMdd.log), kept
        Log.KeepDays days (default 30). Lines are encrypted on disk by default (Log.Encrypt), so
        only this Windows user can read them, through this command.
        -Follow keeps printing new lines as they are written (run it in a second window while the
        UI works; Esc, Q or Ctrl+C stops). -Export writes a plaintext copy you can attach to a
        ticket: it contains host names, delete it after use.
    .EXAMPLE
        vmm log                    # last 100 lines of today
    .EXAMPLE
        vmm log -Follow            # live, in a second window
    .EXAMPLE
        vmm log -Level Error -Date 2026-11-13
    .EXAMPLE
        vmm log -List
    #>
    [CmdletBinding()]
    param(
        [int]$Tail = 100,
        [datetime]$Date = (Get-Date).Date,
        [ValidateSet('All', 'Info', 'Success', 'Warn', 'Error', 'Muted', 'Plain', 'Trace', 'Output')][string]$Level = 'All',
        [string]$Find,
        [switch]$Follow,
        [switch]$Export,
        [switch]$List,
        [switch]$PassThru,
        [switch]$Quiet
    )
    $dir = Get-VmmPath -Name Logs
    if ($List) {
        $files = @(Get-ChildItem -LiteralPath $dir -Filter 'vmm_*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if (-not $files) { Write-VmmLog "No log files yet in $dir" -Level Muted; return }
        $files | Select-Object @{ n = 'Day'; e = { $_.BaseName -replace '^vmm_(\d{4})(\d\d)(\d\d)$', '$1-$2-$3' } }, @{ n = 'SizeKB'; e = { [math]::Round($_.Length / 1KB, 1) } }, @{ n = 'File'; e = { $_.FullName } } | Format-Table -AutoSize | Out-Host
        return
    }
    $file = Join-Path $dir ('vmm_{0}.log' -f $Date.ToString('yyyyMMdd'))
    $match = {
        param($e)
        ($Level -eq 'All' -or $e.Level -eq $Level) -and (-not $Find -or $e.Text -like "*$Find*")
    }
    $read = Read-VmmLogFile -Path $file
    $entries = @($read.Entries | Where-Object { & $match $_ })

    if ($Export) {
        $outDir = Join-Path (Get-VmmPath -Name Reports) 'Logs'
        if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        $out = Join-Path $outDir ('vmm_{0}_plaintext.txt' -f $Date.ToString('yyyyMMdd'))
        $lines = foreach ($e in $entries) { '{0} {1,-7} {2}' -f $(if ($e.At) { $e.At.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }), $e.Level, $e.Text }
        Set-Content -LiteralPath $out -Value $lines -Encoding UTF8
        Write-VmmLog "Plaintext log copy: $out ($($entries.Count) line(s))" -Level Success
        Write-VmmLog 'It contains host names and IPs in plaintext: delete it when done (maintenance M, then clean temp files, removes copies older than a day).' -Level Warn
        return
    }
    if ($PassThru) { return $entries | Select-Object -Last ([math]::Max(1, $Tail)) }

    $show = {
        param($e)
        $t = if ($e.At) { $e.At.ToString('HH:mm:ss') } else { '--:--:--' }
        $c = switch ($e.Level) { 'Info' { 'Cyan' } 'Success' { 'Green' } 'Warn' { 'Yellow' } 'Error' { 'Red' } 'Muted' { 'DarkGray' } 'Trace' { 'DarkCyan' } 'Output' { 'DarkGray' } default { 'Gray' } }
        $line = '{0} {1,-7} {2}' -f $t, $e.Level, $e.Text
        if ($script:VmmFlags -and $script:VmmFlags.NoColor) { Write-Host $line } else { Write-Host $line -ForegroundColor $c }
    }
    if (-not $Quiet) {
        if (-not $entries -and -not $Follow) { Write-VmmLog "Nothing logged for $($Date.ToString('yyyy-MM-dd'))$(if ($Level -ne 'All' -or $Find) { ' with this filter' })." -Level Muted }
        foreach ($e in @($entries | Select-Object -Last ([math]::Max(1, $Tail)))) { & $show $e }
    }
    if (-not $Follow) { return }

    Write-Host "-- following $file (Esc or Q stops) --" -ForegroundColor DarkGray
    $pos = $read.Position
    while ($true) {
        $today = Join-Path $dir ('vmm_{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
        if ($today -ne $file) { $file = $today; $pos = 0; Write-Host "-- new day: $file --" -ForegroundColor DarkGray }
        $r = Read-VmmLogFile -Path $file -From $pos
        $pos = $r.Position
        foreach ($e in $r.Entries) { if (& $match $e) { & $show $e } }
        try {
            if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.Key -eq 'Escape' -or $k.Key -eq 'Q') { return } }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
}
