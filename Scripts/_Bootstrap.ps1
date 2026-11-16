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
try { & (Get-Module VmMaintenance) { param($n) Write-VmmLog "Script: $n" -Level Muted -FileOnly } ([IO.Path]::GetFileName("$($MyInvocation.ScriptName)")) } catch { }

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
        Write-Host "ERROR: $($err.Exception.Message)" -ForegroundColor Red
        try { & $vmm { param($e, $c) Write-VmmErrorLog -ErrorRecord $e -Command $c -DayLog } $err $Name } catch { }
        if ($err.FullyQualifiedErrorId -notlike 'Vmm*') {
            Write-Host "  At     : $($err.InvocationInfo.ScriptName):$($err.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
        }
        $code = 1
        try { $code = & $vmm { param($e) Get-VmmExitCode -ErrorRecord $e } $err } catch { }
    } finally {
        $sw.Stop()
        $verdict = if ($null -eq $code) { 'INTERRUPTED (Ctrl+C): check what it changed before running it again' } elseif ($code) { "FAILED, exit code $code" } else { 'done' }
        $line = '{0} {1} after {2:N1} s' -f $Name, $verdict, $sw.Elapsed.TotalSeconds
        try { & $vmm { param($t, $ok) Add-VmmLogEntry -Text $t -Level $(if ($ok) { 'Muted' } else { 'Error' }) } $line ($code -eq 0) } catch { }
        try { & $vmm { Clear-VmmSessionCredentialStore } } catch { }
    }
    exit $code
}
