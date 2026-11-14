function Get-VmmUniqueSnapshotName {
    # Never overwrite an existing snapshot: append the run stamp when the base name is taken.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][string]$Stamp
    )
    $existing = Get-AzSnapshot -ResourceGroupName $ResourceGroup -SnapshotName $BaseName -ErrorAction SilentlyContinue
    if ($existing) { [pscustomobject]@{ Name = "${BaseName}_$Stamp"; Renamed = $true } }
    else           { [pscustomobject]@{ Name = $BaseName;            Renamed = $false } }
}
