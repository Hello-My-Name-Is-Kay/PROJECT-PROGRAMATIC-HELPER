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
