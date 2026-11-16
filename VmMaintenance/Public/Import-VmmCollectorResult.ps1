function Import-VmmCollectorResult {
    <#
    .SYNOPSIS
        Records a result line from a host: VMM2|... (host agent, encrypted for this laptop) or
        VMM1|... (paste-in collector / generic agent, plain).
    .DESCRIPTION
        [SEC] The line is untrusted input: size-limited, MAC-checked (VMM2), every field validated and
        length-capped, the host must already be in the fleet, and only known step names and statuses
        are accepted. Agent events (steps run on the host, overrides) are added to the host history.
        [SEC] A result is encrypted to this laptop's public key, which is inside every extractor file: that
        keeps it confidential, it does not prove who wrote it. So a result can never mark a change step
        (Stage, PreSnapshot, ExpandDisk, Upgrade) as done, or record an override, unless Extractor.AllowSteps
        is on; with it off those events are kept as history notes only.
    .EXAMPLE
        Import-VmmCollectorResult -Line (Get-Clipboard)
    .EXAMPLE
        vmm collect
    .EXAMPLE
        vmm collect -Path .\VMM_SRV01_20261114_1030.vmm
    #>
    [CmdletBinding()]
    param([string]$Line, [string]$Path, [ValidateSet('Auto', 'Precheck', 'Verify')][string]$Step = 'Auto', [switch]$PassThru)
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw (New-VmmErrorRecord -Activity "Result file not found: $Path" -Category ObjectNotFound -ErrorId 'VmmResultFile') }
        if ((Get-Item -LiteralPath $Path).Length -gt 6MB) { throw (New-VmmErrorRecord -Activity 'Result file too large.' -Target $Path -Category InvalidData -ErrorId 'VmmCollectorSize') }
        $Line = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath)   # .NET reads relative paths from the process folder, not the PowerShell one
    }
    if (-not $Line) { $Line = try { (Get-Clipboard) -join '' } catch { '' } }
    $Line = "$Line".Trim()
    if ($Line.Length -gt 6MB) { throw (New-VmmErrorRecord -Activity 'Result line too large.' -Category InvalidData -ErrorId 'VmmCollectorSize') }
    if ($Line -match '^VMM2\|([A-Za-z0-9+/=]+)$') {
        $text = Unprotect-VmmAgentResult -Base64 $Matches[1]
        $via = 'host agent (encrypted)'
    } elseif ($Line -match '^VMM1\|([A-Za-z0-9+/=]+)$') {
        try { $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) }
        catch { throw (New-VmmErrorRecord -Activity 'Collector line is not valid base64.' -Fix 'Copy the whole line again.' -Category InvalidData) }
        $via = 'RDP collector'
    } else {
        $peek = if ($Line.Length -gt 12) { $Line.Substring(0, 12) + '...' } else { $Line }
        throw (New-VmmErrorRecord -Activity 'Not a result line from a host.' -Target $peek `
            -Cause 'The clipboard holds something else, or the line was cut when copying.' `
            -Fix 'On the host run the agent (menu 5 Export) or the collector again; both copy the full VMM2|/VMM1| line. Paste that.' -Category InvalidData)
    }

    $clean = { param($v, [int]$max = 200) $t = ("$v" -replace '[\x00-\x1F\x7F]', ' ').Trim(); if ($t.Length -gt $max) { $t = $t.Substring(0, $max) }; Protect-VmmLogText $t }
    $num = { param($v) $d = 0.0; if ([double]::TryParse("$v", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -ge 0 -and $d -lt 1e6) { $d } else { $null } }
    $f = @{}; $events = @(); $packages = @(); $invIn = @{}; $agIn = @{}; $problems = @()
    foreach ($l in ($text -split "`n" | Select-Object -First 2000)) {
        $i = $l.IndexOf('='); if ($i -lt 1) { continue }
        $k = $l.Substring(0, $i); $v = $l.Substring($i + 1)
        if ($k -eq 'Event') { $events += , ($v -split '\|', 4) }
        elseif ($k -eq 'Package') { $packages += & $clean $v 120 }
        elseif ($k -eq 'Problem') { if ($problems.Count -lt 30) { $problems += & $clean $v 160 } }
        elseif ($k -match '^Inv\.([A-Za-z0-9]{1,40})$') { $invIn[$Matches[1]] = $v }
        elseif ($k -match '^Agent\.([A-Za-z0-9]{1,40})$') { $agIn[$Matches[1]] = $v }
        elseif ($k -match '^[A-Za-z]{1,20}$') { $f[$k] = $v }
    }
    if ("$($f['Name'])" -notmatch '^[A-Za-z0-9][A-Za-z0-9\-]{0,62}$') {
        throw (New-VmmErrorRecord -Activity 'Result has no valid host name.' -Category InvalidData -ErrorId 'VmmCollectorName')
    }

    $store = Read-VmmStore
    $rec = Get-VmmHostRecord -Store $store -Name $f['Name']   # throws when the host is not in the fleet
    $check = [pscustomobject]@{
        Name = $rec.Name; CheckedAt = (Get-Date).ToUniversalTime().ToString('o'); IPv4 = $rec.IPv4; Ping = 'n/a'; Ports = 'n/a'
        Reachable = 'Yes'; OS = (& $clean $f['OS'] 120); Lang = $(if ("$($f['Lang'])" -match '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){1,2}$') { $f['Lang'] } else { $null }); Version = (& $clean $f['Version'] 30); Build = (& $clean $f['Build'] 20); SP = (& $clean $f['SP'] 5)
        LastBoot = (& $clean $f['LastBoot'] 30); Manufacturer = (& $clean $f['Manufacturer'] 80); Model = (& $clean $f['Model'] 80)
        Platform = $(if ($f['Platform'] -in 'Azure', 'Hyper-V', 'VMware', 'Physical') { $f['Platform'] } else { 'Unknown' })
        CTotalGB = (& $num $f['CTotalGB']); CFreeGB = (& $num $f['CFreeGB'])
        PendingReboot = $(if ($f['PendingReboot'] -eq 'Yes') { 'Yes' } else { 'No' })
        Sql = $(if ($f['Sql']) { & $clean $f['Sql'] 300 } else { 'none' }); Software = (($packages | Select-Object -First 20) -join '; ')
        Error = $null; Via = $via; Inv = $null; Agents = $null
        Route = 'Hands-on'; Problems = ($problems -join ' | ')   # reads that failed on the host; the rest of the snapshot is complete
    }
    # Inventory columns: only Auto keys from the field list, cleaned and length-capped; IP must be IPv4
    $auto = @(try { Get-VmmInventoryCatalog | Where-Object Source -eq 'Auto' | ForEach-Object Key } catch { })
    $inv = [ordered]@{}
    foreach ($k in $invIn.Keys) {
        if ($auto -notcontains $k) { continue }
        $v = & $clean $invIn[$k] 240
        if ($k -eq 'IPAddress' -and $v -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { continue }
        $inv[$k] = $v
    }
    if ($inv.Count) { $check.Inv = [pscustomobject]$inv }
    # Agent health detail: Status|State|StartMode|Version|Issues, only for known agent columns
    $ag = [ordered]@{}
    foreach ($k in $agIn.Keys) {
        if ($auto -notcontains $k) { continue }
        $p = @("$($agIn[$k])" -split '\|', 5)
        if ($p.Count -lt 5 -or $p[0] -notin 'OK', 'WARN', 'FAIL') { continue }
        $ag[$k] = [pscustomobject]@{ Status = $p[0]; State = (& $clean $p[1] 40); StartMode = (& $clean $p[2] 20); Version = (& $clean $p[3] 40); Issues = (& $clean $p[4] 200) }
    }
    if ($ag.Count) { $check.Agents = [pscustomobject]$ag }
    $rec.Check = $check; $rec.Platform = $check.Platform; $rec.Health = Get-VmmHostHealth -Check $check
    Update-VmmInventoryAuto -Record $rec -Values $check.Inv -Via $via

    $known = @((Get-VmmWorkflowDefinition).Name)
    if ($Step -eq 'Auto') {
        # After the upgrade was launched/done and not yet verified, a new extraction is the Verify; else Precheck.
        $u = $rec.Steps.PSObject.Properties['Upgrade']; $v = $rec.Steps.PSObject.Properties['Verify']
        $Step = if ($u -and $u.Value.Status -in 'Success', 'Launched' -and -not ($v -and $v.Value.Status -eq 'Success')) { 'Verify' } else { 'Precheck' }
    }
    $okStatus = 'Success', 'Failed', 'NotNeeded', 'Launched', 'Override', 'Error'
    $hostSteps = [bool](Get-VmmSetting 'Extractor.AllowSteps' -Default $false)
    $seen = @{}; foreach ($h in $rec.History) { $seen["$($h.At)|$($h.Step)|$($h.Result)"] = $true }
    $added = 0
    foreach ($e in $events) {
        if ($e.Count -lt 3) { continue }
        $at = & $clean $e[0] 25; $st = $e[1]; $res = $e[2]; $note = if ($e.Count -ge 4) { & $clean $e[3] 200 } else { '' }
        if ($res -notin $okStatus -or $at -notmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$') { continue }
        if ($seen.ContainsKey("$at|$st|$res")) { continue }
        if (-not $hostSteps -and ($res -eq 'Override' -or ($st -in $known -and $st -notin 'Precheck', 'Verify'))) {
            $rec.History = @($rec.History) + [pscustomobject]@{ At = $at; Step = $st; Result = 'Ignored'; Note = "reported by a host result as $res, not applied (Extractor.AllowSteps is off): $note" }
            $added++; continue
        }
        if ($res -eq 'Override') {
            $store.Overrides = @($store.Overrides) + [pscustomobject]@{ At = $at; Target = "$($rec.Name)/$st (on host)"; Reason = $note; Mode = 'agent' }
        }
        if ($st -in $known -and $res -ne 'Override') {
            Set-VmmStepState -Record $rec -Step $st -Status $res -Note "on host: $note"
            $rec.History[-1].At = $at
        } else {
            $rec.History = @($rec.History) + [pscustomobject]@{ At = $at; Step = $st; Result = $res; Note = "on host: $note" }
        }
        $added++
    }
    $stepEvents = @($events | Where-Object { $_.Count -ge 3 -and $known -contains $_[1] })
    if (-not $stepEvents -and $Step -in 'Precheck', 'Verify') {
        if ($Step -eq 'Precheck' -and -not $rec.Baseline) { $rec.Baseline = [pscustomobject]@{ OS = $check.OS; Lang = $check.Lang; Build = $check.Build; Sql = $check.Sql } }
        Set-VmmStepState -Record $rec -Step $Step -Status 'Success' -Note "via $via`: $($check.OS), C: $($check.CFreeGB) GB free, SQL: $($check.Sql)"
    } elseif (-not $rec.Baseline) { $rec.Baseline = [pscustomobject]@{ OS = $check.OS; Lang = $check.Lang; Build = $check.Build; Sql = $check.Sql } }
    Save-VmmStore -Store $store
    Write-VmmLog "$($rec.Name): facts recorded via $via ($($check.OS), C: $($check.CFreeGB) GB free), $added new host event(s)." -Level Success
    if ($problems) { Write-VmmLog "$($rec.Name): $($problems.Count) read(s) failed on the host, those fields are empty: $($problems -join ' | ')" -Level Warn }
    if ($PassThru) { [pscustomobject]@{ Host = $rec.Name; Step = $Step; Via = $via; Events = $added } }
}
