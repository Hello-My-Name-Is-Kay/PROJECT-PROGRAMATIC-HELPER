function Import-VmmResultInbox {
    <#
    .SYNOPSIS
        Imports every extractor result file (VMM_<HOST>_<time>.vmm) you copied back to this laptop.
    .DESCRIPTION
        Looks in Collect.InboxFolders (default: your Desktop and Downloads) and -Path. Each file is read
        like a pasted line (encrypted, MAC-checked, every field validated). A host not in the fleet yet is added.
        Imported files are deleted (they have no further use); files that fail stay where they are and the
        reason is shown. Runs by itself when the Manager starts (Collect.AutoImport) and with E in the menu.
        Precheck or Verify is chosen per host: Verify once the upgrade was launched, else Precheck.
        When a file fails, the command fails at the end (exit code 1; 5 when a file failed its integrity check),
        unless -Quiet or -PassThru, whose caller shows the failures itself.
    .EXAMPLE
        vmm inbox
    .EXAMPLE
        Import-VmmResultInbox -Path D:\transfer
    #>
    [CmdletBinding()]
    param([string[]]$Path, [switch]$Quiet, [switch]$PassThru)
    $dirs = @($Path | Where-Object { $_ })
    if (-not $dirs) {
        foreach ($d in @(Get-VmmSetting 'Collect.InboxFolders' -Default @('Desktop', 'Downloads'))) {
            $dirs += switch ("$d") {
                'Desktop'   { [Environment]::GetFolderPath('Desktop') }
                'Downloads' { Join-Path $env:USERPROFILE 'Downloads' }
                default     { [Environment]::ExpandEnvironmentVariables("$d") }
            }
        }
    }
    $files = @(foreach ($d in ($dirs | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $d -PathType Container) { Get-ChildItem -LiteralPath $d -Filter 'VMM_*.vmm' -File -ErrorAction SilentlyContinue }
        elseif (Test-Path -LiteralPath $d -PathType Leaf) { Get-Item -LiteralPath $d }
    })
    if (-not $files) { if (-not $Quiet) { Write-VmmLog "No extractor result files (VMM_*.vmm) in: $($dirs -join ', ')" -Level Muted }; return }
    $ok = @(); $bad = @()
    foreach ($f in ($files | Sort-Object LastWriteTime)) {
        try {
            $r = Import-VmmCollectorResult -Path $f.FullName -PassThru
            $ok += $r
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
            catch { Write-VmmLog "$($f.Name): imported, but the file could not be deleted (it is imported again next time; delete it by hand)." -Level Warn }
        } catch {
            $bad += [pscustomobject]@{ File = $f.Name; Reason = $_.Exception.Message.Split([Environment]::NewLine)[0]; Id = "$($_.FullyQualifiedErrorId)" }
            Write-VmmLog "$($f.Name): not imported - $($bad[-1].Reason)" -Level Error
        }
    }
    $newHosts = @($ok | Where-Object { $_.New } | ForEach-Object Host | Select-Object -Unique)
    $script:VmmInboxNotice = if ($ok) { "Imported $($ok.Count) extractor result(s): $((@($ok | ForEach-Object Host) | Select-Object -Unique) -join ', ')$(if ($newHosts) { " ($($newHosts.Count) new in the fleet)" })$(if ($bad) { "; $($bad.Count) failed (E for details)" })" } elseif ($bad) { "$($bad.Count) extractor file(s) could not be imported (E for details)" } else { '' }
    if (-not $Quiet) { Write-VmmLog "Extractor results: $($ok.Count) imported ($($newHosts.Count) new host(s) added to the fleet), $($bad.Count) failed." -Level $(if ($bad) { 'Warn' } else { 'Success' }) }
    if ($PassThru) { [pscustomobject]@{ Imported = $ok; Failed = $bad } }
    elseif ($bad -and -not $Quiet) {
        # A file that fails its integrity check keeps the security exit code (5): it may have been changed on the way
        $sec = @($bad | Where-Object { $_.Id -like 'VmmAgentResult*' }).Count
        throw (New-VmmErrorRecord -Activity "$($bad.Count) extractor result file(s) not imported$(if ($sec) { " ($sec failed the integrity check)" })." `
            -Target (@($bad | ForEach-Object File) -join ', ') -Cause (@($bad | Select-Object -First 3 | ForEach-Object { "$($_.File): $($_.Reason)" }) -join ' | ') `
            -Fix 'The files stay where they are. Build a fresh extractor (vmm extractor) and run it on those hosts again.' `
            -Category InvalidData -ErrorId $(if ($sec) { 'VmmAgentResultRejected' } else { 'VmmInboxFailed' }))
    }
}
