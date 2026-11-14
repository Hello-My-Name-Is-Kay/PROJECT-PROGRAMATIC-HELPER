<#
.SYNOPSIS
    vmm - fleet maintenance console. No arguments opens the terminal UI; otherwise: vmm <command> [-Option value].
.DESCRIPTION
    Global flags (any position):
      --no-mouse     keyboard only in the console UI (this run)
      --no-color     plain output (this run)
      --no-log       live log pane and progress lines off (this run; the log file is still written)
      --config PATH  use another config file (this run)
      --debug-errors also print the script location of unexpected errors
      --version      print the module version
    Exit codes: 0 ok | 1 error | 2 usage error | 3 blocked by the time window | 4 VPN down | 5 security check failed | 6 another vmm is running
.EXAMPLE
    vmm                      # terminal UI (first run starts the setup wizard)
.EXAMPLE
    vmm check -Name srv01,srv02
.EXAMPLE
    vmm agent -HostName srv01
.EXAMPLE
    vmm help
#>
# Simple (non-advanced) script on purpose: -Options land in $args and are parsed by Invoke-VmmCli.
$all = @($args)
$flags = @{ NoMouse = $false; NoColor = $false; NoLog = $false; Config = $null; DebugErrors = $false; Version = $false }
$rest = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $all.Count; $i++) {
    switch -Exact ("$($all[$i])") {
        '--no-mouse'     { $flags.NoMouse = $true }
        '--no-color'     { $flags.NoColor = $true }
        '--no-log'       { $flags.NoLog = $true }
        '--debug-errors' { $flags.DebugErrors = $true }
        '--version'      { $flags.Version = $true }
        '--config'       { $i++; if ($i -lt $all.Count) { $flags.Config = "$($all[$i])" } }
        default          { $rest.Add($all[$i]) }
    }
}
$Command = 'ui'
if ($rest.Count -and "$($rest[0])" -notmatch '^-') { $Command = "$($rest[0])"; $rest.RemoveAt(0) }

# Installed copy: module next to this script's parent or on PSModulePath
$repoManifest = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'VmMaintenance\VmMaintenance.psd1'
try {
    if (Test-Path -LiteralPath $repoManifest) { $mod = Import-Module $repoManifest -Force -ErrorAction Stop -PassThru }
    else { $mod = Import-Module VmMaintenance -Force -ErrorAction Stop -PassThru }
} catch {
    Write-Host "ERROR: Could not load the VmMaintenance module. $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Fix    : run Install.ps1 again, or run vmm.ps1 from the repository Scripts folder.' -ForegroundColor Red
    exit 1
}
if ($flags.Version) { Write-Host "VmMaintenance $($mod.Version)"; exit 0 }
& $mod { param($f) $script:VmmFlags = $f } $flags
if ($flags.Config) { $env:VMM_CONFIG = $flags.Config }

try {
    Invoke-VmmCli -Command $Command -Arguments $rest.ToArray()
    exit 0
} catch {
    $id = "$($_.FullyQualifiedErrorId)"
    # [SEC] Message only (already free of credentials); sanitized copy to the local error log.
    $msg = & $mod { param($t) Protect-VmmLogText $t } $_.Exception.Message
    if ($flags.NoColor) { Write-Host "ERROR: $msg" } else { Write-Host "ERROR: $msg" -ForegroundColor Red }
    & $mod { param($e, $c) Write-VmmErrorLog -ErrorRecord $e -Command $c } $_ $Command
    if ($id -notlike 'Vmm*' -and $flags.DebugErrors) { Write-Host "  At     : $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray }
    elseif ($id -notlike 'Vmm*') { Write-Host '  Details: logged to %LOCALAPPDATA%\VmMaintenance\logs\errors.log (run with --debug-errors to show the location).' -ForegroundColor DarkGray }
    $code = switch -Wildcard ($id) {
        'VmmCli*'          { 2 }
        'VmmWindowBlocked*' { 3 }
        'VmmVpnDown*'      { 4 }
        'VmmStoreIntegrity*' { 5 }
        'VmmAgentResult*'  { 5 }
        'VmmInstanceLocked*' { 6 }
        default            { 1 }
    }
    # The day log gets the exit code (and the error itself when it was raised before the command started)
    & $mod { param($c, $n, $m) Add-VmmLogEntry -Text "vmm $c exit code $n$(if ($m) { ': ' + $m })" -Level Error } $Command $code $(if ($id -like 'VmmCli*' -or $id -like 'VmmInstanceLocked*') { $msg } else { '' })
    exit $code
}
