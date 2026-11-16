function Import-VmmFleet {
    <#
    .SYNOPSIS
        Adds hosts to the encrypted fleet store from names, a text list (one name per line) or a CSV with
        three columns: hostname or FQDN, domain, IP.
    .DESCRIPTION
        CSV: separator , ; or tab, header row optional (Hostname/FQDN, Domain, IP; any order with a header,
        else that order). For new hosts the FQDN, domain and IP are kept with the host (encrypted store):
        the fleet check connects by FQDN, and falls back to the IP when the name does not resolve from this
        laptop; the domain and IP also fill the inventory. For hosts already in the fleet, empty values are
        filled in and nothing measured is overwritten (use -Update to replace FQDN/domain/IP from the file).
        -Preview shows what would happen without saving. -RemoveSource deletes the plaintext file afterwards.
    .EXAMPLE
        Import-VmmFleet -Path .\new-hosts.csv -Preview
    .EXAMPLE
        vmm import -Path .\new-hosts.csv -RemoveSource
    .EXAMPLE
        Import-VmmFleet -Name srv01, srv02
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Name, [string]$Path, [switch]$RemoveSource, [switch]$Preview, [switch]$Update)
    if ($Path) { $Path = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"')) }
    $rows = @()
    if ($Path -and $Path -match '\.(csv|tsv)$') {
        $rows = @(Read-VmmHostCsv -Path $Path)
        if (-not $rows) { throw (New-VmmErrorRecord -Activity 'No valid hosts in the CSV.' -Target $Path -Fix 'One host per line: hostname or FQDN, domain, IP (see the warnings above).' -Category InvalidData -ErrorId 'VmmCsvEmpty') }
        $src = $Path
    } else {
        $src = if ($Path) { $Path } else { 'manual' }
        $rows = @(Read-VmmServerList -Name $Name -Path $Path -ListKey 'Fleet' -Case Upper | ForEach-Object { [pscustomobject]@{ Name = $_; Fqdn = $null; Domain = ''; IP = '' } })
    }

    $store = Read-VmmStore
    $plan = foreach ($r in $rows) {
        $rec = $store.Hosts | Where-Object { $_.Name -eq $r.Name } | Select-Object -First 1
        $act = if (-not $rec) { 'Add' } else {
            $chg = @()
            $cur = if ($rec.PSObject.Properties['Fqdn']) { $rec.Fqdn } else { $null }
            if ($r.Fqdn -and ($Update -or -not $cur) -and $r.Fqdn -ne $cur) { $chg += 'FQDN' }
            if ($r.IP -and ($Update -or -not $rec.IPv4) -and $r.IP -ne $rec.IPv4) { $chg += 'IP' }
            $hd = if ($rec.PSObject.Properties['InventoryAuto'] -and $rec.InventoryAuto -and $rec.InventoryAuto.PSObject.Properties['Domain']) { $rec.InventoryAuto.Domain.Value } else { '' }
            if ($r.Domain -and ($Update -or -not $hd) -and $r.Domain -ne $hd) { $chg += 'Domain' }
            if ($chg) { 'Update (' + ($chg -join ', ') + ')' } else { 'Already there' }
        }
        [pscustomobject]@{ Action = $act; Name = $r.Name; Fqdn = $r.Fqdn; Domain = $r.Domain; IP = $r.IP; Row = $r; Record = $rec }
    }
    $plan = @($plan | Group-Object Name | ForEach-Object { $_.Group[-1] })   # same host twice: last line wins
    if ($Preview -or -not $Name) { $plan | Format-Table Action, Name, Fqdn, Domain, IP -AutoSize | Out-VmmHost }
    if ($Preview) { Write-VmmLog "Preview only: $(@($plan | Where-Object Action -eq 'Add').Count) to add, $(@($plan | Where-Object Action -like 'Update*').Count) to update. Run again without -Preview to save." -Level Info; return }

    $added = 0; $updated = 0
    foreach ($p in $plan) {
        if ($p.Action -eq 'Already there') { continue }
        if (-not $PSCmdlet.ShouldProcess($p.Name, $p.Action)) { continue }
        $rec = $p.Record
        if (-not $rec) {
            $rec = New-VmmHostRecord -Name $p.Name -Source ([IO.Path]::GetFileName($src))
            $store.Hosts = @($store.Hosts) + $rec
            $added++
        } else { $updated++ }
        if ($p.Fqdn -and ($Update -or -not ($rec.PSObject.Properties['Fqdn'] -and $rec.Fqdn))) { $rec | Add-Member -NotePropertyName Fqdn -NotePropertyValue $p.Fqdn -Force }
        if ($p.IP -and ($Update -or -not $rec.IPv4)) { $rec.IPv4 = $p.IP }
        if ($p.Domain -or $p.IP) {
            $have = if ($rec.PSObject.Properties['InventoryAuto'] -and $rec.InventoryAuto) { $rec.InventoryAuto } else { $null }
            $v = [ordered]@{}
            if ($p.Domain -and ($Update -or -not ($have -and $have.PSObject.Properties['Domain']))) { $v.Domain = $p.Domain }
            if ($p.IP -and ($Update -or -not ($have -and $have.PSObject.Properties['IPAddress']))) { $v.IPAddress = $p.IP }
            if ($v.Count) { Update-VmmInventoryAuto -Record $rec -Values $v -Via 'import file' }
        }
    }
    if ($added -or $updated) { Save-VmmStore -Store $store }
    Write-VmmLog "$added new host(s) added, $updated updated; fleet now has $(@($store.Hosts).Count). Next: 3 Check fleet (or vmm check) to read them." -Level Success

    if ($RemoveSource -and $Path -and $PSCmdlet.ShouldProcess($Path, 'Delete plaintext source list')) {
        # [SEC] a list that could not be deleted must not be reported as removed: it holds host names in plaintext
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        catch {
            throw (New-VmmErrorRecord -Activity 'Hosts imported, but the plaintext source list was NOT deleted.' -Target $Path -Exception $_.Exception `
                -Fix 'Close the program that has it open (Excel), then delete it by hand.' -Category WriteError -ErrorId 'VmmSourceNotRemoved')
        }
        Write-VmmLog "Plaintext list removed: $Path (names now only in the encrypted store)" -Level Muted
    }
}
