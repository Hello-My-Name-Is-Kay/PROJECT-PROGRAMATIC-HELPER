function Initialize-VmmConfig {
    <#
    .SYNOPSIS
        Creates your local config and empty server list files from the shipped example.
    .DESCRIPTION
        Default location: %APPDATA%\VmMaintenance\config.psd1 and %APPDATA%\VmMaintenance\lists\*.txt
        - outside the repository, so hosts, IPs and IDs never end up in the project.
        Existing files are left alone unless -Force.
    .EXAMPLE
        Initialize-VmmConfig
        notepad "$env:APPDATA\VmMaintenance\config.psd1"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Destination = (Get-VmmDefaultConfigPath),
        [switch]$Force
    )
    $repoRoot = Split-Path -Path $script:ModuleRoot -Parent
    $example  = Join-Path $repoRoot 'config\config.example.psd1'
    if (-not (Test-Path -LiteralPath $example)) { $example = Join-Path $script:ModuleRoot 'Resources\config.example.psd1' }   # installed copy
    if (-not (Test-Path -LiteralPath $example)) {
        throw (New-VmmErrorRecord -Activity 'Example config not found.' -Target $example `
            -Cause 'The config folder was not copied together with the module.' `
            -Fix 'Keep the repository layout intact: config\ must sit next to the VmMaintenance\ module folder.' `
            -Category ObjectNotFound)
    }

    $dir      = Split-Path -Path $Destination -Parent
    $listsDir = Join-Path $dir 'lists'
    foreach ($d in $dir, $listsDir) {
        if (-not (Test-Path -LiteralPath $d)) { [void](Resolve-VmmWorkDir -Path $d) }
    }

    if ((Test-Path -LiteralPath $Destination) -and -not $Force) {
        Write-VmmLog "Config already exists, left unchanged: $Destination (use -Force to overwrite)" -Level Muted
    } elseif ($PSCmdlet.ShouldProcess($Destination, 'Create config from example')) {
        Copy-Item -LiteralPath $example -Destination $Destination -Force
        Write-VmmLog "Created $Destination" -Level Success
    }

    # One list per task, matching ServerLists.* in the example config
    $lists = 'fleet', 'platform', 'diskspace', 'azurevms', 'osdiskexpand', 'snapshot', 'upgrademedia'
    foreach ($l in $lists) {
        $f = Join-Path $listsDir "$l.txt"
        if (Test-Path -LiteralPath $f) { continue }
        if ($PSCmdlet.ShouldProcess($f, 'Create empty server list')) {
            Set-Content -LiteralPath $f -Encoding UTF8 -Value @(
                "# $l - one server or VM name per line. Lines starting with # are ignored."
                '# Short names, FQDNs or Azure VM names all work (domain suffix is stripped where relevant).'
            )
        }
    }
    Write-VmmLog "Server lists: $listsDir" -Level Info
    Write-VmmLog 'Next: replace every <placeholder> in the config, then fill the list files.' -Level Info
}
