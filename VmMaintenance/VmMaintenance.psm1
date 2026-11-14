# Loader: dot-sources Private\*.ps1 and Public\*.ps1 (one function per file), exports Public only.
$script:ModuleRoot    = $PSScriptRoot
$script:VmmConfig     = $null
$script:VmmConfigPath = $null
$script:VmmTenantId   = $null
$script:VmmFlags      = $null   # run flags from vmm.ps1 (--no-mouse, --no-color, ...)
$script:VmmCredentials = @{}     # session-only PSCredentials (never written)

$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public)) {
    try { . $file.FullName }
    catch {
        throw "VmMaintenance: failed to load $($file.FullName) - $($_.Exception.Message). If the files came from a download or zip, run: Get-ChildItem -Recurse '$PSScriptRoot' | Unblock-File"
    }
}

# Unloading the module (also Import-Module -Force) releases the single-instance lock
$ExecutionContext.SessionState.Module.OnRemove = { try { Exit-VmmInstanceLock } catch { } }

Export-ModuleMember -Function $public.BaseName
