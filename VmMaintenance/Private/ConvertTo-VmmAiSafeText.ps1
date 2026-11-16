function ConvertTo-VmmAiSafeText {
    # [SEC] Prepares text that leaves this laptop (AI model, GitHub issue): masks secrets, Azure resource ids,
    # GUIDs (tenant/subscription ids), IPs, UNC paths, e-mail addresses, DOMAIN\user and your user name; the
    # values of the settings that name your environment (Azure, SQL instance, share, VPN, tags, manager and
    # inventory defaults); the domains, resource groups and VM names kept in the fleet store; and replaces
    # every fleet host name with an alias (HOST01, HOST02...) unless Ai.SendHostNames is on.
    # Fails closed: when the fleet store exists but cannot be read, it throws (VmmAiUnsafe) instead of
    # returning text with host names left in. Returns the safe text and the alias map (used to restore names).
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text, [hashtable]$Map)
    if (-not $Map) { $Map = @{} }
    $t = Protect-VmmLogText $Text

    # Settings that name the environment, longest first (a share path before its server name)
    $words = New-Object System.Collections.Generic.List[string]
    $add = {
        param($v)
        if ($null -eq $v) { return }
        if ($v -is [System.Collections.IDictionary]) { foreach ($k in @($v.Keys)) { & $add $v[$k] }; return }
        if ($v -is [array]) { foreach ($i in $v) { & $add $i }; return }
        $s = "$v".Trim()
        if ($s.Length -ge 3 -and $s -notmatch '^\d+$' -and $s -notmatch '^<.+>$' -and $s -notmatch '^(?i)(true|false)$' -and -not $words.Contains($s)) { $words.Add($s) }
    }
    foreach ($k in 'Azure', 'Lansweeper.SqlInstance', 'Staging.SourceShare', 'Vpn.Profile', 'Vpn.ProbeHost', 'Snapshots.Tags', 'Snapshots.CleanupTagValue',
                   'Reports.ManagerName', 'Inventory.Defaults', 'Downloads.CacheFolder', 'Handoff.OutboxFolder') {
        try { & $add (Get-VmmSetting $k) } catch { }
    }
    foreach ($w in @($words | Sort-Object Length -Descending)) { $t = $t -replace ('(?i)' + [regex]::Escape($w)), '<config>' }

    $t = $t -replace '(?i)/subscriptions/[^\s''"<>|,;]+', '<azure-resource-id>'
    $t = $t -replace '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '<id>'
    $t = $t -replace '\b(?:\d{1,3}\.){3}\d{1,3}\b', '<ip>'
    $t = $t -replace '\\\\[^\\\s]+\\[^\s''"]*', '\\<share>\...'
    $t = $t -replace '\b[\w\.-]+@[\w\.-]+\.\w+\b', '<email>'
    $t = $t -replace '\b[A-Za-z0-9\-]{2,15}\\[A-Za-z0-9\.\-_]{2,64}\b', '<account>'
    if ($env:USERNAME) { $t = $t -replace [regex]::Escape($env:USERNAME), '<me>' }

    # Fleet store: host names (aliases), domains, resource groups, VM names that differ from the host name
    try { $hosts = @((Read-VmmStore).Hosts | Where-Object { $_ -and $_.Name }) }
    catch {
        throw (New-VmmErrorRecord -Activity 'Text not prepared for sending: the fleet store could not be read to mask host names.' `
            -Exception $_.Exception -Fix 'Nothing was sent. Fix the store first (vmm maint -Action CheckStore), then try again.' `
            -Category SecurityError -ErrorId 'VmmAiUnsafe')
    }
    $sendNames = [bool](Get-VmmSetting 'Ai.SendHostNames' -Default $false)
    $domains = @(); $groups = @(); $vms = @()
    foreach ($h in $hosts) {
        if ($h.PSObject.Properties['Fqdn'] -and "$($h.Fqdn)" -match '^[^\.]+\.(.+)$') { $domains += $Matches[1] }
        if ($h.PSObject.Properties['InventoryAuto'] -and $h.InventoryAuto -and $h.InventoryAuto.PSObject.Properties['Domain']) { $domains += "$($h.InventoryAuto.Domain.Value)" }
        if ($h.PSObject.Properties['Azure'] -and $h.Azure) {
            if ($h.Azure.PSObject.Properties['ResourceGroup']) { $groups += "$($h.Azure.ResourceGroup)" }
            if ($h.Azure.PSObject.Properties['VMName'] -and "$($h.Azure.VMName)" -ne "$($h.Name)") { $vms += "$($h.Azure.VMName)" }
        }
    }
    if (-not $sendNames) {
        foreach ($n in @($hosts | ForEach-Object { "$($_.Name)" } | Sort-Object Length -Descending)) {
            if (-not $Map.ContainsKey($n)) { $Map[$n] = 'HOST{0:D2}' -f ($Map.Count + 1) }
            $t = $t -replace ('(?i)\b' + [regex]::Escape($n) + '(\.[\w\.-]+)?\b'), $Map[$n]
        }
        foreach ($v in @($vms | Where-Object { $_ } | Select-Object -Unique | Sort-Object Length -Descending)) { $t = $t -replace ('(?i)\b' + [regex]::Escape($v) + '\b'), '<vm>' }
    }
    foreach ($g in @($groups | Where-Object { $_.Length -ge 3 } | Select-Object -Unique | Sort-Object Length -Descending)) { $t = $t -replace ('(?i)\b' + [regex]::Escape($g) + '\b'), '<resource-group>' }
    foreach ($d in @($domains | Where-Object { $_.Length -ge 3 } | Select-Object -Unique | Sort-Object Length -Descending)) { $t = $t -replace ('(?i)\b' + [regex]::Escape($d) + '\b'), '<domain>' }
    [pscustomobject]@{ Text = $t; Map = $Map }
}
