function Assert-VmmModule {
    # Imports the named modules, or stops with the exact Install-Module command when one is missing.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Name)
    foreach ($m in $Name) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            throw (New-VmmErrorRecord -Activity "Required PowerShell module '$m' is not installed." -Target $m `
                -Cause 'Az modules are not part of Windows; they are installed per user or per machine.' `
                -Fix "Install-Module $m -Scope CurrentUser   (then open a new PowerShell window)" `
                -Category NotInstalled -ErrorId 'VmmModuleMissing')
        }
        try { Import-Module $m -ErrorAction Stop }
        catch {
            throw (New-VmmErrorRecord -Activity "Module '$m' is installed but failed to load." -Target $m -Exception $_.Exception `
                -Cause 'Usually two Az versions clash in the same session (an older Az.Accounts is already loaded).' `
                -Fix 'Open a fresh PowerShell window and run this first, or: Update-Module Az.Accounts, Az.Compute, Az.ResourceGraph' `
                -Category ResourceUnavailable -ErrorId 'VmmModuleLoad')
        }
    }
}
