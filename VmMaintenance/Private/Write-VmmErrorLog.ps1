function Write-VmmErrorLog {
    # [SEC] Appends one sanitized line per unexpected error to <data>\..\logs\errors.log (secrets masked,
    # no credentials ever reach here). Keeps the file under 1 MB. Never throws: logging must not hide the
    # original error.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord, [string]$Command, [switch]$DayLog)
    # -DayLog: also one ERROR line in the encrypted day log (callers that did not log the error with Write-VmmLog)
    try {
        $msg = Protect-VmmLogText (("$($ErrorRecord.Exception.Message)" -replace '\s+', ' ').Trim())
        $where = if ($ErrorRecord.InvocationInfo) { "$([IO.Path]::GetFileName($ErrorRecord.InvocationInfo.ScriptName)):$($ErrorRecord.InvocationInfo.ScriptLineNumber)" } else { '' }
    } catch { return }
    # The day-log line does not depend on errors.log being writable
    if ($DayLog) { Add-VmmLogEntry -Text ("{0} failed: {1} [{2}] {3}" -f $Command, $msg, $ErrorRecord.FullyQualifiedErrorId, $where) -Level Error }
    try {
        $dir = Get-VmmPath -Name Logs
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $file = Join-Path $dir 'errors.log'
        if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt 1MB) { Move-Item -LiteralPath $file -Destination "$file.old" -Force -ErrorAction Stop }
        $line = '{0} | {1} | {2} | {3} | {4}' -f (Get-Date).ToUniversalTime().ToString('o'), $Command, $ErrorRecord.FullyQualifiedErrorId, $where, $msg
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { Add-VmmLogEntry -Text (Protect-VmmLogText "errors.log not written: $($_.Exception.Message)") -Level Warn }
}
