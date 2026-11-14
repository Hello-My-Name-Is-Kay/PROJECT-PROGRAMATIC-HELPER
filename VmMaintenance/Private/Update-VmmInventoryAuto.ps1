function Update-VmmInventoryAuto {
    # Merges automatically read inventory columns into the host record (InventoryAuto), key by key, so a
    # later partial check (host down, licence query timed out) never erases what an earlier source read.
    # Each value keeps where it came from (check / agent / collector) and when.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [AllowNull()]$Values, [string]$Via = 'check')
    if (-not $Values) { return }
    if (-not $Record.PSObject.Properties['InventoryAuto'] -or -not $Record.InventoryAuto) {
        $Record | Add-Member -NotePropertyName InventoryAuto -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $pairs = if ($Values -is [System.Collections.IDictionary]) { @($Values.Keys | ForEach-Object { @{ K = "$_"; V = $Values[$_] } }) }
             else { @($Values.PSObject.Properties | ForEach-Object { @{ K = $_.Name; V = $_.Value } }) }
    foreach ($p in $pairs) {
        if ($null -eq $p.V -or "$($p.V)" -eq '') { continue }
        $item = [pscustomobject]@{ Value = "$($p.V)"; Via = $Via; At = $at }
        $Record.InventoryAuto | Add-Member -NotePropertyName $p.K -NotePropertyValue $item -Force
    }
}
