function Resolve-VmmWorkDir {
    # Returns <Paths.WorkDir>[\SubFolder] and creates it. Default work dir: C:\Temp\VmMaintenance
    [CmdletBinding()]
    param([string]$SubFolder, [string]$Path)
    if (-not $Path) {
        $Path = Get-VmmSetting 'Paths.WorkDir' -Default 'C:\Temp\VmMaintenance'
        if ($SubFolder) { $Path = Join-Path $Path $SubFolder }
    }
    $Path = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        try { New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null }
        catch {
            throw (New-VmmErrorRecord -Activity 'Could not create the output folder.' -Target $Path -Exception $_.Exception `
                -Cause 'The drive does not exist, the path has a typo, or you have no write permission there.' `
                -Fix 'Set Paths.WorkDir in your config to a folder you can write to.' -Category WriteError)
        }
    }
    $Path
}
