function Resolve-VmmOutputPath {
    # Explicit -Path wins; otherwise <WorkDir>\<BaseName>_<yyyyMMdd-HHmmss>.<Extension>.
    # Either way the parent folder is created.
    [CmdletBinding()]
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$BaseName,
        [string]$Extension = 'csv'
    )
    if ($Path) {
        $Path   = [Environment]::ExpandEnvironmentVariables($Path)
        $parent = Split-Path -Path $Path -Parent
        if ($parent) { [void](Resolve-VmmWorkDir -Path $parent) }
        return $Path
    }
    $dir = Resolve-VmmWorkDir
    Join-Path $dir ('{0}_{1}.{2}' -f $BaseName, (Get-Date -Format 'yyyyMMdd-HHmmss'), $Extension)
}
