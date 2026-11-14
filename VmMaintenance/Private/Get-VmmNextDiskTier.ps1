function Get-VmmNextDiskTier {
    # Next tier up. A disk on a tier (128) goes up one (256); a disk between tiers (127, billed as 128)
    # also goes to 256. Returns $null when no larger tier exists.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$SizeGB,
        [Parameter(Mandatory)][int[]]$TierSizes
    )
    $sorted  = $TierSizes | Sort-Object
    $ceiling = $sorted | Where-Object { $_ -ge $SizeGB } | Select-Object -First 1
    if ($null -eq $ceiling) { return $null }
    $sorted | Where-Object { $_ -gt $ceiling } | Select-Object -First 1
}
