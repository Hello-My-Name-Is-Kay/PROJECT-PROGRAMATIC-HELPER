function Set-VmmInventoryValue {
    <#
    .SYNOPSIS
        Sets one inventory column for one or more hosts (what you found by hand), or clears it.
    .DESCRIPTION
        -Field takes the column header as in the CSV ('Server Owner') or its key (ServerOwner), any case.
        Values are stored in the encrypted fleet store. Automatic columns use your value only while the
        host has not been read; derived columns (Actions to be executed, Actions Status, Execution Date)
        use your value instead of the workflow's. Execution Date must be yyyy-MM-dd.
        Same value for the whole fleet (Technician, Phase...)? Use Inventory.Defaults instead (setup wizard).
    .EXAMPLE
        Set-VmmInventoryValue -HostName srv01 -Field 'Server Owner' -Value 'Finance IT'
    .EXAMPLE
        vmm inventory-set -HostName srv01,srv02 -Field Phase -Value 'Wave 2'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string[]]$HostName, [Parameter(Mandatory)][string]$Field, [AllowEmptyString()][string]$Value, [switch]$Clear)
    $f = @(Get-VmmInventoryCatalog | Where-Object { $_.Key -ieq $Field.Trim() -or $_.Header -ieq $Field.Trim() }) | Select-Object -First 1
    if (-not $f) {
        throw (New-VmmErrorRecord -Activity "Unknown inventory column '$Field'." -Cause ('Columns: ' + ((Get-VmmInventoryCatalog | ForEach-Object Header) -join ', ')) `
            -Fix 'Use the header as written in the export, in quotes when it has spaces.' -Category InvalidArgument -ErrorId 'VmmInventoryField')
    }
    if ($f.Key -eq 'Hostname') { throw (New-VmmErrorRecord -Activity 'Hostname comes from the fleet and cannot be typed.' -Fix 'Rename by removing and re-importing the host.' -Category InvalidArgument) }
    $v = ("$Value" -replace '[\x00-\x1F\x7F]', ' ').Trim()
    if ($v.Length -gt 500) { $v = $v.Substring(0, 500) }
    if (-not $Clear -and -not $v) { throw (New-VmmErrorRecord -Activity "No value for '$($f.Header)'." -Fix 'Give -Value, or -Clear to remove what was typed.' -Category InvalidArgument) }
    if ($f.Key -eq 'ExecutionDate' -and -not $Clear) {
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($v, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) {
            throw (New-VmmErrorRecord -Activity "Execution Date '$v' is not a date like 2026-11-21." -Fix 'Use yyyy-MM-dd.' -Category InvalidArgument)
        }
    }
    $v = Protect-VmmLogText $v
    $store = Read-VmmStore
    $done = @()
    foreach ($n in $HostName) {
        $rec = Get-VmmHostRecord -Store $store -Name $n
        if (-not $PSCmdlet.ShouldProcess($rec.Name, "Set $($f.Header)")) { continue }
        if (-not $rec.PSObject.Properties['Inventory'] -or -not $rec.Inventory) { $rec | Add-Member -NotePropertyName Inventory -NotePropertyValue ([pscustomobject]@{}) -Force }
        if ($Clear) { $rec.Inventory.PSObject.Properties.Remove($f.Key) }
        else { $rec.Inventory | Add-Member -NotePropertyName $f.Key -NotePropertyValue ([pscustomobject]@{ Value = $v; At = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }) -Force }
        $done += $rec.Name
    }
    if ($done) {
        Save-VmmStore -Store $store
        Write-VmmLog "$($f.Header) $(if ($Clear) { 'cleared' } else { 'set' }) for $($done -join ', ')." -Level Success
    }
}
