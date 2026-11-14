function Import-VmmFleet {
    <#
    .SYNOPSIS
        Adds hosts to the encrypted fleet store from names, a text list or a CSV (column Name/ComputerName).
    .DESCRIPTION
        Only machine names are kept. -RemoveSource deletes the plaintext list after a successful
        import so host names exist only inside the encrypted store.
    .EXAMPLE
        Import-VmmFleet -Path "$env:APPDATA\VmMaintenance\lists\osdiskexpand.txt" -RemoveSource
    .EXAMPLE
        Import-VmmFleet -Name srv01, srv02
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Name, [string]$Path, [switch]$RemoveSource)

    if ($Path -and $Path -match '\.csv$') {
        if (-not (Test-Path -LiteralPath $Path)) { throw (New-VmmErrorRecord -Activity 'CSV not found.' -Target $Path -Category ObjectNotFound) }
        $Name = @(Import-Csv -LiteralPath $Path | ForEach-Object { if ($_.Name) { $_.Name } elseif ($_.ComputerName) { $_.ComputerName } })
        $src = $Path
    } else { $src = if ($Path) { $Path } else { 'manual' } }
    $listPath = if ($Path -and $Path -notmatch '\.csv$') { $Path } else { $null }
    $names = @(Read-VmmServerList -Name $Name -Path $listPath -ListKey 'Fleet' -Case Upper)

    $store = Read-VmmStore
    $added = 0
    foreach ($n in $names) {
        if ($store.Hosts | Where-Object { $_.Name -eq $n }) { continue }
        if ($PSCmdlet.ShouldProcess($n, 'Add to fleet')) {
            $store.Hosts = @($store.Hosts) + (New-VmmHostRecord -Name $n -Source ([IO.Path]::GetFileName($src)))
            $added++
        }
    }
    if ($added) { Save-VmmStore -Store $store }
    Write-VmmLog "$added new host(s) added; fleet now has $(@($store.Hosts).Count)." -Level Success

    if ($RemoveSource -and $Path -and $PSCmdlet.ShouldProcess($Path, 'Delete plaintext source list')) {
        Remove-Item -LiteralPath $Path -Force
        Write-VmmLog "Plaintext list removed: $Path (names now only in the encrypted store)" -Level Muted
    }
}
