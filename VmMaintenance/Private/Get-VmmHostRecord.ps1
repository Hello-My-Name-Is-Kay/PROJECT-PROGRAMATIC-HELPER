function Get-VmmHostRecord {
    # Finds one host in a loaded store (case-insensitive). Throws a specific error when it is not in the fleet.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Name)
    $short = ($Name.Trim() -split '\.')[0].ToUpper()
    $rec = $Store.Hosts | Where-Object { $_.Name -eq $short } | Select-Object -First 1
    if (-not $rec) {
        throw (New-VmmErrorRecord -Activity "Host '$short' is not in the fleet." -Target $short `
            -Fix "Add it first: vmm import -Name $short   (or Import-VmmFleet -Path <list.txt>)" -Category ObjectNotFound -ErrorId 'VmmHostUnknown')
    }
    $rec
}
