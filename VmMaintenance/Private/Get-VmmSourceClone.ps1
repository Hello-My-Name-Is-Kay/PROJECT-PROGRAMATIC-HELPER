function Get-VmmSourceClone {
    # The local git clone used for updates and pull requests (GitHub.SourcePath), validated.
    [CmdletBinding()]
    param([switch]$Optional)
    $p = Get-VmmSetting 'GitHub.SourcePath' -Default ''
    if ($p -and (Test-Path -LiteralPath (Join-Path $p '.git')) -and (Test-Path -LiteralPath (Join-Path $p 'VmMaintenance\VmMaintenance.psd1'))) { return $p }
    if ($Optional) { return $null }
    throw (New-VmmErrorRecord -Activity 'No local clone of the repository.' -Target "$p" `
        -Fix 'Clone it from the GitHub screen (U > C) or: vmm clone -Path C:\Src\VmMaintenance   (sets GitHub.SourcePath).' -Category ObjectNotFound -ErrorId 'VmmGhClone')
}
