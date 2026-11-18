function Resolve-VmmResultHost {
    # Finds the fleet record a host result (Extractor / RDP collector) belongs to, or adds a new one: the Extractor
    # works on any host, so a host the fleet does not know yet is not an error (Collect.AutoAddHosts, default on).
    # Match order: full DNS host name, the 15-character NetBIOS name (COMPUTERNAME), a longer fleet name that starts
    # with that NetBIOS name (only when exactly one does), then the FQDN. All inputs are untrusted (from the result).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Name, [string]$DnsName, [string]$Fqdn, [string]$IPv4)
    $label = '^[A-Za-z0-9][A-Za-z0-9\-]{0,62}$'
    if ($Name -notmatch $label) { throw (New-VmmErrorRecord -Activity 'Result has no valid host name.' -Category InvalidData -ErrorId 'VmmCollectorName') }
    $nb = $Name.ToUpper()
    # The DNS name is used only when it is this host's own name (equal, or the NetBIOS name is its first 15 characters)
    $long = $null
    if ($DnsName -match $label) {
        $d = $DnsName.ToUpper()
        if ($d -eq $nb -or ($d.Length -gt 15 -and $nb.Length -eq 15 -and $d.Substring(0, 15) -eq $nb)) { $long = $d }
    }
    $want = if ($long) { $long } else { $nb }
    $fq = $null
    if ($Fqdn -and $Fqdn.Length -le 253 -and $Fqdn -match '^[A-Za-z0-9][A-Za-z0-9\-]{0,62}(\.[A-Za-z0-9][A-Za-z0-9\-]{0,62})+$' -and ($Fqdn -split '\.')[0].ToUpper() -eq $want) { $fq = $Fqdn.ToLower() }
    $ip = if ($IPv4 -match '^\d{1,3}(\.\d{1,3}){3}$') { $IPv4 } else { $null }

    $hosts = @($Store.Hosts | Where-Object { $_ })
    $rec = $hosts | Where-Object { $_.Name -eq $want } | Select-Object -First 1
    if (-not $rec -and $want -ne $nb) { $rec = $hosts | Where-Object { $_.Name -eq $nb } | Select-Object -First 1 }
    if (-not $rec -and $nb.Length -eq 15 -and -not $long) {
        $cand = @($hosts | Where-Object { "$($_.Name)".Length -gt 15 -and "$($_.Name)".Substring(0, 15) -eq $nb })
        if ($cand.Count -eq 1) { $rec = $cand[0] }
        elseif ($cand.Count -gt 1) {
            throw (New-VmmErrorRecord -Activity "Result from '$nb' matches $($cand.Count) fleet hosts whose names start with it." -Target $nb `
                -Cause 'Windows cuts COMPUTERNAME at 15 characters and this result carries no full host name (older Extractor).' `
                -Fix 'Build the Extractor again (vmm extractor) and run it on the host: it also sends the full host name.' -Category InvalidData -ErrorId 'VmmHostAmbiguous')
        }
    }
    if (-not $rec -and $fq) { $rec = $hosts | Where-Object { $_.PSObject.Properties['Fqdn'] -and "$($_.Fqdn)" -ieq $fq } | Select-Object -First 1 }

    $new = $false
    if (-not $rec) {
        if (-not (Get-VmmSetting 'Collect.AutoAddHosts' -Default $true)) {
            throw (New-VmmErrorRecord -Activity "Host '$want' is not in the fleet (Collect.AutoAddHosts is off)." -Target $want `
                -Fix "Add it first: vmm import -Name $want   or let results add hosts: vmm set -Name Collect.AutoAddHosts -Value true" -Category ObjectNotFound -ErrorId 'VmmHostUnknown')
        }
        $rec = New-VmmHostRecord -Name $want -Source 'extractor'
        $Store.Hosts = @($hosts) + $rec
        $new = $true
    }
    # Fill what the fleet did not know; values set by an import file or by hand are kept
    if ($fq -and -not ($rec.PSObject.Properties['Fqdn'] -and $rec.Fqdn)) { $rec | Add-Member -NotePropertyName Fqdn -NotePropertyValue $fq -Force }
    if ($ip -and -not $rec.IPv4) { $rec.IPv4 = $ip }
    [pscustomobject]@{ Record = $rec; New = $new }
}
