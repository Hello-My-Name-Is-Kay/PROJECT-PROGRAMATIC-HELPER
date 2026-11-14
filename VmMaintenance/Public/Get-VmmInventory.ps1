function Get-VmmInventory {
    <#
    .SYNOPSIS
        Server inventory: the 24 columns of the team spreadsheet for every host, filled from the fleet
        check, the host agent / collector, the workflow, fleet defaults and what you typed.
    .DESCRIPTION
        Default: one line per host with how many columns are filled and which are missing.
        -HostName with one name: every column with its value, where it came from and its help text.
        -Missing: only the gaps, host by host. -Export: CSV with the exact headers in the agreed order
        (Inventory.CsvDelimiter, default comma) in Reports\Inventory. Read-only except the CSV file.
    .EXAMPLE
        vmm inventory
    .EXAMPLE
        vmm inventory -HostName srv01
    .EXAMPLE
        vmm inventory -Export
    #>
    [CmdletBinding()]
    param([string[]]$HostName, [switch]$Missing, [switch]$Export, [switch]$PassThru)
    $store = Read-VmmStore
    $cat = Get-VmmInventoryCatalog
    $hosts = if ($HostName) { @($HostName | ForEach-Object { Get-VmmHostRecord -Store $store -Name $_ }) } else { @($store.Hosts) }
    if (-not $hosts) { throw (New-VmmErrorRecord -Activity 'The fleet is empty.' -Fix 'Import hosts first: vmm import -Path <list.txt>' -Category ObjectNotFound) }
    $all = @(foreach ($h in $hosts) { [pscustomobject]@{ Host = $h.Name; Fields = @(Get-VmmInventoryRow -Record $h -Catalog $cat) } })

    if ($Export) {
        $dir = Join-Path (Get-VmmPath -Name Reports) 'Inventory'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $file = Join-Path $dir ('Inventory_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmm'))
        $delim = "$(Get-VmmSetting 'Inventory.CsvDelimiter' -Default ',')"
        if ($delim.Length -ne 1) { $delim = ',' }
        $rows = foreach ($a in $all) { $o = [ordered]@{}; foreach ($f in $a.Fields) { $o[$f.Header] = $f.Value }; [pscustomobject]$o }
        $rows | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8 -Delimiter $delim
        $gap = @($all | Where-Object { $_.Fields | Where-Object Missing }).Count
        Write-VmmLog "Inventory exported: $file ($($all.Count) host(s), $gap with missing columns). Plaintext on purpose, like the daily report." -Level Success
        if ($PassThru) { return $file }
        return
    }
    if ($HostName -and $all.Count -eq 1 -and -not $Missing) {
        $all[0].Fields | Format-Table @{ n = 'Column'; e = { $_.Header } }, Value, @{ n = 'From'; e = { if ($_.Missing) { 'MISSING' } else { $_.Origin } } } -AutoSize -Wrap | Out-VmmHost
        $m = @($all[0].Fields | Where-Object Missing)
        if ($m) { Write-VmmLog "$($m.Count) column(s) missing. Fill them: open the host, press I (help window per column), or vmm inventory-set -HostName $($all[0].Host) -Field '<column>' -Value '...'" -Level Warn }
        if ($PassThru) { return $all[0].Fields }
        return
    }
    $sum = foreach ($a in $all) {
        $m = @($a.Fields | Where-Object Missing)
        [pscustomobject]@{ Host = $a.Host; Filled = "$(@($a.Fields | Where-Object { $_.Value }).Count)/$($a.Fields.Count)"; Missing = (@($m | ForEach-Object Header) -join ', ') }
    }
    if ($Missing) { $sum = @($sum | Where-Object Missing) }
    if ($sum) { $sum | Format-Table Host, Filled, Missing -AutoSize -Wrap | Out-VmmHost } else { Write-VmmLog 'No missing inventory columns.' -Level Success }
    if ($PassThru) { $all }
}
