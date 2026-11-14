function Get-VmmPolicyReport {
    <#
    .SYNOPSIS
        Fleet against the OS policy: target Windows Server 2019, client OS skipped unless ordered, and the
        management warnings (Windows Server 2008 non-R2, physical machines) as a ready-to-send note.
    .DESCRIPTION
        Without switches: table of every host with scope and warnings.
        -Notice: writes the management note to Reports\Blockers, copies it to the clipboard and asks
        whether you sent it (Sent / Later / Bypass); the answer is stored per host and shown in the daily
        report. The tool never sends e-mail.
    .EXAMPLE
        Get-VmmPolicyReport
    .EXAMPLE
        vmm policy -Notice
    #>
    [CmdletBinding()]
    param([switch]$Notice, [ValidateSet('Sent', 'Later', 'Bypass')][string]$Contact)
    $store = Read-VmmStore
    $rows = foreach ($h in ($store.Hosts | Sort-Object Name)) {
        $p = Get-VmmHostPolicy -Record $h
        [pscustomobject]@{ Host = $h.Name; Platform = $h.Platform; OS = $p.Os; Scope = $p.Scope; Warnings = ($p.Warnings -join ' | '); Why = $p.Why
            Notified = $(if ($h.PSObject.Properties['PolicyNotice'] -and $h.PolicyNotice) { "$($h.PolicyNotice.Contact) $($h.PolicyNotice.At.Substring(0, 10))" } else { '' }) }
    }
    $rows = @($rows)
    if (-not $Notice) {
        $rows | Format-Table Host, Platform, Scope, Notified, Warnings -AutoSize -Wrap | Out-VmmHost
        $c = $rows | Group-Object Scope | ForEach-Object { "$($_.Name)=$($_.Count)" }
        Write-VmmLog ("Scope: " + ($c -join ', ')) -Level Info
        $w = @($rows | Where-Object Warnings)
        if ($w) { Write-VmmLog "$($w.Count) host(s) need a management warning: vmm policy -Notice" -Level Warn }
        return
    }

    $todo = @($rows | Where-Object { $_.Warnings })
    if (-not $todo) { Write-VmmLog 'No host needs a management warning.' -Level Success; return }
    $mgr = Get-VmmSetting 'Reports.ManagerName' -Default ''
    $lines = @("Subject: Server upgrade programme - machines that need a decision ($((Get-Date).ToString('yyyy-MM-dd')))", '',
        "Hello$(if ($mgr) { " $mgr" }),", '',
        'Our goal is Windows Server 2019 on every server. The machines below need your attention before I continue:', '')
    foreach ($r in $todo) { $lines += " - $($r.Host) [$($r.Platform)] $($r.OS)"; foreach ($x in ($r.Warnings -split ' \| ')) { $lines += "     $x" } }
    $lines += @('', 'What I need: a decision per machine (upgrade path, rebuild, replacement or exclusion) and, for physical',
        'machines, confirmation of the backup/rollback method and who has on-site access.', '', 'Thank you,')
    $text = $lines -join [Environment]::NewLine
    $dir = Get-VmmPath -Name Blockers
    $file = Join-Path $dir ("PolicyNotice_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
    Set-Content -LiteralPath $file -Value $text -Encoding UTF8
    try { Set-Clipboard -Value $text; Write-VmmLog 'Management note copied to the clipboard.' -Level Success } catch { }
    Write-Host $text
    Write-VmmLog "Saved: $file" -Level Muted
    if (-not $Contact) {
        do { $Contact = Read-VmmPrompt 'Have you sent it to management? Sent / Later / Bypass' } until ($Contact -in 'Sent', 'Later', 'Bypass')
    }
    $at = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($r in $todo) {
        $rec = Get-VmmHostRecord -Store $store -Name $r.Host
        $rec | Add-Member -NotePropertyName PolicyNotice -NotePropertyValue ([pscustomobject]@{ At = $at; Contact = $Contact }) -Force
    }
    Save-VmmStore -Store $store
    Write-VmmLog "Recorded '$Contact' for $($todo.Count) host(s)." -Level Info
}
