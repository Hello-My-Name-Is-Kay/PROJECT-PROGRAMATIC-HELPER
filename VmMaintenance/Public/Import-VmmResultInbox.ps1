function Import-VmmResultInbox {
    <#
    .SYNOPSIS
        Imports every extractor result file (VMM_<HOST>_<time>.vmm) you copied back to this laptop.
    .DESCRIPTION
        Looks in Collect.InboxFolders (default: your Desktop and Downloads) and -Path. Each file is read
        like a pasted line (encrypted, MAC-checked, host must be in the fleet, every field validated).
        Imported files are deleted (they have no further use); files that fail stay where they are and the
        reason is shown. Runs by itself when the Manager starts (Collect.AutoImport) and with E in the menu.
        Precheck or Verify is chosen per host: Verify once the upgrade was launched, else Precheck.
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
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        } catch {
            $bad += [pscustomobject]@{ File = $f.Name; Reason = $_.Exception.Message.Split([Environment]::NewLine)[0] }
            Write-VmmLog "$($f.Name): not imported - $($bad[-1].Reason)" -Level Error
        }
    }
    $script:VmmInboxNotice = if ($ok) { "Imported $($ok.Count) extractor result(s): $((@($ok | ForEach-Object Host) | Select-Object -Unique) -join ', ')$(if ($bad) { "; $($bad.Count) failed (E for details)" })" } elseif ($bad) { "$($bad.Count) extractor file(s) could not be imported (E for details)" } else { '' }
    if (-not $Quiet) { Write-VmmLog "Extractor results: $($ok.Count) imported, $($bad.Count) failed." -Level $(if ($bad) { 'Warn' } else { 'Success' }) }
    if ($PassThru) { [pscustomobject]@{ Imported = $ok; Failed = $bad } }
}
