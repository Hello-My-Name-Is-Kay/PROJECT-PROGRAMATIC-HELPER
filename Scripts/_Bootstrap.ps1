# Dot-sourced by every entry script: loads the module from this repository and, when the caller
# set $ConfigPath, that config file. No param block on purpose (dot-sourcing would clobber the
# caller's $PSBoundParameters).
$vmmManifest = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'VmMaintenance\VmMaintenance.psd1'
if (-not (Test-Path -LiteralPath $vmmManifest)) {
    Write-Host "ERROR: Module manifest not found at $vmmManifest" -ForegroundColor Red
    Write-Host '  Fix    : keep the Scripts folder next to the VmMaintenance folder (repository layout).' -ForegroundColor Red
    exit 1
}
try { Import-Module $vmmManifest -Force -ErrorAction Stop }
catch {
    Write-Host "ERROR: Could not load the VmMaintenance module. $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if ($ConfigPath) {
    try { Import-VmmConfig -Path $ConfigPath }
    catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}
# Day log: which script ran (its messages follow; the result and duration are logged by Invoke-VmmEntryScript)
try { & (Get-Module VmMaintenance) { param($n) Write-VmmLog "Script: $n" -Level Muted -FileOnly } ([IO.Path]::GetFileName("$($MyInvocation.ScriptName)")) } catch { Write-Verbose "Day log: script name not written ($($_.Exception.Message))" }

function Invoke-VmmEntryScript {
    # Runs the entry script's module command, then: result and duration in the day log (FAILED with the error,
    # or INTERRUPTED after Ctrl+C), the error in errors.log, session credentials cleared from memory (the script
    # may run inside an open PowerShell), and the same exit codes as vmm:
    # 0 ok | 1 error | 3 time window | 4 VPN down | 5 security check failed | 6 another vmm is running
    param([Parameter(Mandatory)][string]$Command, [System.Collections.IDictionary]$Parameters = @{}, [string]$Name = $Command)
    $vmm = Get-Module VmMaintenance
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $code = $null
    try {
        & $Command @Parameters
        $code = 0
    } catch {
        $err = $_
        $code = 1   # first: whatever fails below, the run is recorded as failed (not as Ctrl+C)
        # [SEC] masked like vmm prints it (the message may be pasted into a ticket)
        $msg = "$($err.Exception.Message)"
        try { $msg = & $vmm { param($t) Protect-VmmLogText $t } $msg } catch { $msg = '(message not shown: it could not be masked; see errors.log)' }
        Write-Host "ERROR: $msg" -ForegroundColor Red
        try { & $vmm { param($e, $c) Write-VmmErrorLog -ErrorRecord $e -Command $c -DayLog } $err $Name } catch { Write-Warning "The error was not written to the log: $($_.Exception.Message)" }
        if ($err.FullyQualifiedErrorId -notlike 'Vmm*') {
            Write-Host "  At     : $($err.InvocationInfo.ScriptName):$($err.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
        }
        try { $code = & $vmm { param($e) Get-VmmExitCode -ErrorRecord $e } $err } catch { $code = 1 }   # table not readable: plain error
    } finally {
        $sw.Stop()
        $verdict = if ($null -eq $code) { 'INTERRUPTED (Ctrl+C): check what it changed before running it again' } elseif ($code) { "FAILED, exit code $code" } else { 'done' }
        $line = '{0} {1} after {2:N1} s' -f $Name, $verdict, $sw.Elapsed.TotalSeconds
        try { & $vmm { param($t, $ok) Add-VmmLogEntry -Text $t -Level $(if ($ok) { 'Muted' } else { 'Error' }) } $line ($code -eq 0) } catch { Write-Warning "The result was not written to the day log: $($_.Exception.Message)" }
        try { & $vmm { Clear-VmmSessionCredentialStore } } catch { Write-Warning "Session credentials could not be cleared from memory ($($_.Exception.Message)): close this PowerShell window." }
    }
    exit $code
}
