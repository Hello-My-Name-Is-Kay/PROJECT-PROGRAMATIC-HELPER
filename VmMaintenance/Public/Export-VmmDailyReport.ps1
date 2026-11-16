function Export-VmmDailyReport {
    <#
    .SYNOPSIS
        Daily export for your manager: Fleet_<date>.csv, Fleet_<date>.html (open in any browser) and
        Fleet_<date>.json (machine-readable summary). Plaintext by design - they contain host names.
    .DESCRIPTION
        Includes progress against the daily target, every host's health/stage/OS/SQL/C: free, steps
        done today, open blockers (with the manager-contact answer) and every business-hours override.
        Never includes usernames or passwords. Folder: %LOCALAPPDATA%\VmMaintenance\Reports\Daily.
    .EXAMPLE
        Export-VmmDailyReport -Open
    #>
    [CmdletBinding()]
    param([switch]$Open, [switch]$Quiet)
    $store = Read-VmmStore
    $w     = Get-VmmTimeWindow
    $prog  = Get-VmmDailyProgress -Store $store
    $tz    = [TimeZoneInfo]::FindSystemTimeZoneById($w.ZoneId)
    $date  = $w.ZoneTime.ToString('yyyy-MM-dd')
    $dir   = Get-VmmPath -Name Daily
    $base  = Join-Path $dir "Fleet_$date"
    $toZone = { param($v) if ($v) { [TimeZoneInfo]::ConvertTimeFromUtc((ConvertTo-VmmUtcDate $v), $tz).ToString('yyyy-MM-dd HH:mm') } }

    $steps = Get-VmmWorkflowDefinition
    $rows = foreach ($h in ($store.Hosts | Sort-Object Name)) {
        $c = $h.Check
        $row = [ordered]@{
            Host = $h.Name; Platform = $h.Platform; Health = $h.Health; Stage = Get-VmmHostStage -Record $h
            DoneToday = ($prog.Hosts -contains $h.Name)
            OS = $c.OS; Build = $c.Build; Sql = $c.Sql; CFreeGB = $c.CFreeGB; PendingReboot = $c.PendingReboot
        }
        foreach ($s in $steps) {
            $st = $h.Steps.PSObject.Properties[$s.Name]
            $row[$s.Name] = if ($st) { $st.Value.Status } else { '' }
        }
        $row['OpenBlockers'] = @($h.Blockers | Where-Object { -not $_.Resolved }).Count
        $pol = Get-VmmHostPolicy -Record $h
        $row['Policy'] = $pol.Scope
        $row['ManagementWarning'] = ($pol.Warnings -join ' | ')
        $row['ManagementNotified'] = $(if ($h.PSObject.Properties['PolicyNotice'] -and $h.PolicyNotice) { $h.PolicyNotice.Contact } elseif ($pol.Warnings) { 'NOT YET' } else { '' })
        $row['LastCheck'] = & $toZone $c.CheckedAt
        [pscustomobject]$row
    }
    $rows = @($rows)
    $todayEvents = @(foreach ($h in $store.Hosts) { foreach ($e in $h.History) {
        $d = [TimeZoneInfo]::ConvertTimeFromUtc((ConvertTo-VmmUtcDate $e.At), $tz)
        if ($d.ToString('yyyy-MM-dd') -eq $date) { [pscustomobject]@{ Time = $d.ToString('HH:mm'); Host = $h.Name; Step = $e.Step; Result = $e.Result; Note = $e.Note } }
    } }) | Sort-Object Time
    $blockers = @(foreach ($h in $store.Hosts) { foreach ($b in $h.Blockers) { if (-not $b.Resolved) {
        [pscustomobject]@{ Host = $h.Name; Step = $b.Step; Needed = $b.Summary; ManagerContact = $b.Contact; Since = (& $toZone $b.At) } } } })
    $overrides = @($store.Overrides | Where-Object { [TimeZoneInfo]::ConvertTimeFromUtc((ConvertTo-VmmUtcDate $_.At), $tz).ToString('yyyy-MM-dd') -eq $date } |
        ForEach-Object { [pscustomobject]@{ Time = (& $toZone $_.At); Target = $_.Target; Reason = $_.Reason } })

    # CSV for the manager
    Export-VmmCsv -InputObject $rows -Path "$base.csv"

    # JSON summary (AI/automation readable)
    [pscustomobject]@{
        Date = $date; Zone = $w.ZoneLabel; GeneratedAt = $w.ZoneTime.ToString('yyyy-MM-dd HH:mm')
        Progress = $prog; Hosts = $rows; Today = $todayEvents; OpenBlockers = $blockers; Overrides = $overrides
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$base.json" -Encoding UTF8 -ErrorAction Stop

    # HTML status page
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
    $badge = { param($v) $cls = switch -Regex ("$v") { '^(OK|Success|Done|NotNeeded|True)$' { 'ok' } '^(Warn|Launched|Skipped|Pending)' { 'warn' } '^(Critical|Failed|Blocked|Unreachable)' { 'bad' } default { 'muted' } }; "<span class='b $cls'>$(& $enc $v)</span>" }
    $table = { param($items, $badgeCols)
        if (-not $items) { return '<p class="muted">None.</p>' }
        $cols = $items[0].PSObject.Properties.Name
        $th = ($cols | ForEach-Object { "<th>$(& $enc $_)</th>" }) -join ''
        $tr = foreach ($i in $items) { '<tr>' + (($cols | ForEach-Object { $v = $i.$_; if ($badgeCols -contains $_) { "<td>$(& $badge $v)</td>" } else { "<td>$(& $enc $v)</td>" } }) -join '') + '</tr>' }
        "<table><thead><tr>$th</tr></thead><tbody>$($tr -join '')</tbody></table>"
    }
    $statusCls = @{ TargetMet = 'ok'; OnTrack = 'ok'; AtRisk = 'bad' }[$prog.Status]
    $pct = if ($prog.Target) { [math]::Min(100, [int](100 * $prog.Done / $prog.Target)) } else { 0 }
    $badgeCols = @('Health', 'DoneToday') + @($steps | ForEach-Object Name)
    $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Fleet status $date</title>
<style>
:root{--bg:#f7f7f5;--fg:#1d1d1b;--mut:#6b6b66;--card:#fff;--line:#e2e2dc;--ok:#1e7d3a;--warn:#9a6a00;--bad:#b3261e;--acc:#0b6e8a}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--fg:#ecebe6;--mut:#a3a29b;--card:#1f1f1d;--line:#33332f;--ok:#5cc47a;--warn:#e0b04a;--bad:#ef7a70;--acc:#5bb8d4}}
body{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:14px/1.45 Segoe UI,system-ui,sans-serif}
h1{font-size:20px;margin:0 0 4px}h2{font-size:16px;margin:24px 0 8px}.muted{color:var(--mut)}
.cards{display:flex;flex-wrap:wrap;gap:12px;margin:12px 0}.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 14px;min-width:150px}
.card .v{font-size:22px;font-weight:600}.bar{height:8px;background:var(--line);border-radius:4px;overflow:hidden;margin-top:6px}.bar i{display:block;height:100%;background:var(--acc)}
.wrap{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:8px}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{padding:6px 8px;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap}
th{position:sticky;top:0;background:var(--card);cursor:pointer}.b{padding:1px 6px;border-radius:4px;font-size:12px;border:1px solid currentColor}
.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}input{padding:6px 8px;margin:8px 0;width:260px;max-width:100%;background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:6px}
</style></head><body>
<h1>Fleet status - $date</h1>
<div class="muted">Generated $(& $enc $w.ZoneTime.ToString('yyyy-MM-dd HH:mm')) $(& $enc $w.ZoneLabel) | window: $(& $enc $w.Mode) | contains host names, no credentials</div>
<div class="cards">
<div class="card"><div class="muted">Machines done today</div><div class="v $statusCls">$($prog.Done) / $($prog.Target)</div><div class="bar"><i style="width:$pct%"></i></div><div class="muted">$(& $enc $prog.Status), expected by now: $($prog.ExpectedByNow)</div></div>
<div class="card"><div class="muted">Hosts in fleet</div><div class="v">$($rows.Count)</div></div>
<div class="card"><div class="muted">Done (all steps)</div><div class="v ok">$(@($rows | Where-Object Stage -eq 'Done').Count)</div></div>
<div class="card"><div class="muted">Open blockers</div><div class="v $(if ($blockers) { 'bad' } else { 'ok' })">$($blockers.Count)</div></div>
<div class="card"><div class="muted">Overrides today</div><div class="v $(if ($overrides) { 'warn' } else { 'ok' })">$($overrides.Count)</div></div>
</div>
<h2>Hosts</h2><input id="f" placeholder="Filter hosts..." oninput="filt()">
<div class="wrap" id="hosts">$(& $table $rows $badgeCols)</div>
<h2>Open blockers</h2><div class="wrap">$(& $table $blockers @())</div>
<h2>Business-hours overrides today</h2><div class="wrap">$(& $table $overrides @())</div>
<h2>Activity today</h2><div class="wrap">$(& $table $todayEvents @('Result'))</div>
<script>
function filt(){var q=document.getElementById('f').value.toLowerCase();document.querySelectorAll('#hosts tbody tr').forEach(function(r){r.style.display=r.textContent.toLowerCase().indexOf(q)<0?'none':''})}
document.querySelectorAll('th').forEach(function(th){th.onclick=function(){var t=th.closest('table'),i=[].indexOf.call(th.parentNode.children,th),b=t.tBodies[0],d=th.dataset.d=th.dataset.d=='a'?'d':'a';
[].slice.call(b.rows).sort(function(x,y){var p=x.cells[i].textContent,q=y.cells[i].textContent,n=parseFloat(p)-parseFloat(q);var c=isNaN(n)?p.localeCompare(q):n;return d=='a'?c:-c}).forEach(function(r){b.appendChild(r)})}})
</script></body></html>
"@
    Set-Content -LiteralPath "$base.html" -Value $html -Encoding UTF8 -ErrorAction Stop
    if (-not $Quiet) {
        Write-VmmLog "Daily report: $base.html | .csv | .json" -Level Success
        if (Get-VmmSetting 'Inventory.ExportWithDaily' -Default $true) {
            try { Get-VmmInventory -Export } catch { Write-VmmLog "Inventory CSV not written: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -Level Warn }
        }
        Write-VmmLog 'These files are plaintext (host names) so your manager can read them. Send them yourself; delete old ones when no longer needed.' -Level Warn
    }
    if ($Open) { Start-Process "$base.html" }
    [pscustomobject]@{ Html = "$base.html"; Csv = "$base.csv"; Json = "$base.json" }
}
