function Add-VmmLogEntry {
    # Every log line goes here: a 500-line memory buffer (the live pane) and the day's log file
    # <data>\..\logs\vmm_yyyyMMdd.log. [SEC] Text is already masked by Protect-VmmLogText; with
    # Log.Encrypt (default) each line is encrypted with the store key (AES-256 + HMAC, DPAPI-protected
    # key), because host names and IPs must not sit in plaintext on disk. Read it with: vmm log.
    # Never throws: logging must not break the work. A file that cannot be written is still never silent: the
    # first failure of the session is shown once (warning) and stays in the on-screen log.
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Text, [string]$Level = 'Plain')
    try {
        if ($null -eq $script:VmmLogBuffer) { $script:VmmLogBuffer = New-Object System.Collections.Generic.List[object] }
        if ($null -eq $script:VmmLogPending) { $script:VmmLogPending = New-Object System.Collections.Generic.List[object] }
        $now = Get-Date
        $flat = "$Text" -replace '[\r\n]+', ' '
        $script:VmmLogBuffer.Add([pscustomobject]@{ At = $now; Level = $Level; Text = $flat })
        if ($script:VmmLogBuffer.Count -gt 500) { $script:VmmLogBuffer.RemoveRange(0, $script:VmmLogBuffer.Count - 500) }
        $script:VmmLogSeq = 1 + [int]$script:VmmLogSeq
        $script:VmmLogPending.Add([pscustomobject]@{ At = $now; Level = $Level; Text = $flat })
        if ($script:VmmLogWriting) { return }   # logged while a line is being written (config load, key creation): written next
        $script:VmmLogWriting = $true
        try {
            while ($script:VmmLogPending.Count) {
                $e = $script:VmmLogPending[0]
                $script:VmmLogPending.RemoveAt(0)
                if (-not (Get-VmmSetting 'Log.ToFile' -Default $true)) { $script:VmmLogPending.Clear(); return }
                $dir = Get-VmmPath -Name Logs
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
                if ($script:VmmLogPrunedFor -ne $e.At.Date) {
                    $script:VmmLogPrunedFor = $e.At.Date
                    try { Remove-VmmOldLog | Out-Null } catch { }
                }
                $line = '{0}|{1}|{2}' -f $e.At.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'), "$($e.Level)".ToUpperInvariant(), $e.Text
                if (Get-VmmSetting 'Log.Encrypt' -Default $true) {
                    $b = [Text.Encoding]::UTF8.GetBytes($line)
                    try { $line = 'E1:' + [Convert]::ToBase64String((Protect-VmmBytes -Bytes $b)) } finally { [Array]::Clear($b, 0, $b.Length) }
                }
                $file = Join-Path $dir ('vmm_{0}.log' -f $e.At.ToString('yyyyMMdd'))
                $bytes = [Text.Encoding]::UTF8.GetBytes($line + "`r`n")
                # Shared append: a second vmm window or 'vmm log -Follow' can have the file open
                $fs = New-Object System.IO.FileStream($file, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
                try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
            }
        } finally { $script:VmmLogWriting = $false }
    } catch {
        try {
            if ($script:VmmLogPending -and $script:VmmLogPending.Count -gt 200) { $script:VmmLogPending.Clear() }
            if (-not $script:VmmLogFileError) {
                $script:VmmLogFileError = (("$($_.Exception.Message)" -split "`r?`n")[0]).Trim()
                $script:VmmLogBuffer.Add([pscustomobject]@{ At = (Get-Date); Level = 'Error'; Text = "Log file not written: $script:VmmLogFileError" })
                Write-Warning "vmm could not write its log file: $script:VmmLogFileError. The work goes on; until this is fixed the session is only in the on-screen log. Check: vmm maint -Action Diagnose"
            }
        } catch { }
    }
}
