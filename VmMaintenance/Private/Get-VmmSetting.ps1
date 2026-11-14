function Get-VmmSetting {
    # Reads a dotted setting (e.g. 'Azure.TenantId') from the local config, loading it on first use.
    # -Required: missing/empty/placeholder values throw with the file path and the key to fix.
    # Without -Required: a missing config file, key or a '<placeholder>' value returns -Default.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [object]$Default,
        [switch]$Required
    )
    if ($null -eq $script:VmmConfig) {
        if (-not (Resolve-VmmConfigPath)) {
            if ($Required) { Import-VmmConfig }   # throws the "no config found" error with the search list
            return $Default
        }
        Import-VmmConfig
    }

    $node = $script:VmmConfig
    foreach ($part in $Name.Split('.')) {
        if ($node -is [System.Collections.IDictionary] -and $node.Contains($part)) { $node = $node[$part] }
        else { $node = $null; break }
    }

    $empty = ($null -eq $node) -or
             ($node -is [string] -and [string]::IsNullOrWhiteSpace($node)) -or
             ($node -is [array] -and $node.Count -eq 0) -or
             ($node -is [System.Collections.IDictionary] -and $node.Count -eq 0)
    if ($empty) {
        if ($Required) {
            throw (New-VmmErrorRecord -Activity "Required setting '$Name' is not set." -Target $script:VmmConfigPath `
                -Cause 'The key is missing or empty in your local config.' `
                -Fix "Set '$Name' in $script:VmmConfigPath (see config\config.example.psd1), or pass it as a parameter." `
                -Category InvalidData -ErrorId 'VmmSettingMissing')
        }
        return $Default
    }

    $placeholder = Find-VmmPlaceholder -Value $node
    if ($placeholder -and -not $Required) { return $Default }   # optional setting not filled in yet = unset
    if ($placeholder) {
        throw (New-VmmErrorRecord -Activity "Setting '$Name' still holds the placeholder '$placeholder'." -Target $script:VmmConfigPath `
            -Cause 'The value was copied from the example file and never filled in.' `
            -Fix "Replace it with the real value in $script:VmmConfigPath, or pass it as a parameter." `
            -Category InvalidData -ErrorId 'VmmSettingPlaceholder')
    }

    if ($node -is [string]) { return [Environment]::ExpandEnvironmentVariables($node) }
    $node
}
