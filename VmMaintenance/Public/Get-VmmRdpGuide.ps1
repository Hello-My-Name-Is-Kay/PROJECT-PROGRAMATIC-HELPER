function Get-VmmRdpGuide {
    <#
    .SYNOPSIS
        Step-by-step checklist for doing a workflow step by hand in an RDP/RDM session, with the exact
        commands to paste. Used when the tool cannot reach the host, or for Guided steps (Upgrade).
    .EXAMPLE
        Get-VmmRdpGuide -HostName srv01 -Step Precheck
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][string]$Step)
    $share  = try { Get-VmmSetting 'Staging.SourceShare' -Default '(staging share not set)' } catch { '(staging share not set - Settings)' }
    $target = Get-VmmSetting 'Staging.TargetFolder' -Default 'C:\Temp'
    $cmd    = Get-VmmSetting 'Upgrade.CommandLine' -Default ''
    $h = $HostName.ToUpper()
    $rec = try { Get-VmmHostRecord -Store (Read-VmmStore) -Name $HostName } catch { $null }
    $pk = if ($Step -in 'Stage', 'Upgrade') { try { @(Get-VmmStagingPackage -Record $rec) } catch { @() } } else { @() }
    $open = [pscustomobject]@{ Text = "Connect to $h in RDM, or with RDP:"; Command = "mstsc /v:$h" }
    $ps   = [pscustomobject]@{ Text = 'Open Windows PowerShell as Administrator (right-click > Run as administrator).'; Command = $null }

    $items = switch ($Step) {
        { $_ -in 'Precheck', 'Verify' } {
            $acc = if ($rec) { Get-VmmHostAccess -Record $rec } else { $null }
            if ($acc -and $acc.Terminal -eq $true) { [pscustomobject]@{ Text = "NO HANDS-ON NEEDED: this host answers over the terminal ($($acc.Why)). Press S on the host (or run the command) and skip the rest of this page."; Command = "vmm snapshot -Name $h" } }
            elseif (-not $acc -or $null -eq $acc.Terminal) { [pscustomobject]@{ Text = 'FIRST try the terminal: press S on the host (or run the command). Continue below only if it reports no working route.'; Command = "vmm snapshot -Name $h" } }
            else { [pscustomobject]@{ Text = "The terminal cannot read this host ($($acc.Why)). Hands-on steps:"; Command = $null } }
            [pscustomobject]@{ Text = "The extractor (snapshot only: it writes one result file on the host desktop, nothing else). Build it with X on this host (or: vmm extractor for one file that works on every host). It is on the clipboard: paste it on the RDP desktop."; Command = $null }
            [pscustomobject]@{ Text = 'On the host: right-click the file > Run with PowerShell. It saves VMM_<HOST>_<time>.vmm on the desktop. Copy that file to this laptop''s Desktop or Downloads: vmm imports it by itself (E in the menu).'; Command = $null }
            [pscustomobject]@{ Text = 'Without copying a file: paste the collector below into PowerShell on the host (same read-only extraction):'; Command = $null }
            $open; $ps
            [pscustomobject]@{ Text = 'Paste the collector (read-only). It prints a VMM1|... line and copies it to the clipboard.'; Command = (Get-VmmCollectorScript) }
            [pscustomobject]@{ Text = "Back on the laptop: press P on this host's screen (or run: vmm collect -Step $Step) to record the result."; Command = $null }
        }
        'Stage' {
            $open
            [pscustomobject]@{ Text = "Create $target if it is missing:"; Command = "New-Item -ItemType Directory -Path '$target' -Force" }
            if (-not $pk) { [pscustomobject]@{ Text = 'Nothing resolved: check the media repository (vmm media) and that the host has been checked (its install language picks the image).'; Command = $null } }
            foreach ($p in $pk) {
                if ($p.Gate) { [pscustomobject]@{ Text = "NOT READY: $($p.Gate)"; Command = $null }; continue }
                [pscustomobject]@{ Text = "Copy $($p.Name) from the share:"; Command = "Copy-Item '$(Join-Path $share $p.Path)' '$target\' -Force" }
                if ($p.Sha256) { [pscustomobject]@{ Text = "Verify: the hash must be $($p.Sha256)"; Command = "(Get-FileHash '$target\$($p.DestName)' -Algorithm SHA256).Hash" } }
                if ($p.Note) { [pscustomobject]@{ Text = "Note: $($p.Note)"; Command = $null } }
            }
        }
        'PreSnapshot' {
            [pscustomobject]@{ Text = 'Not an Azure VM: take a snapshot/backup in the platform console (vSphere, Hyper-V, backup tool).'; Command = $null }
            [pscustomobject]@{ Text = 'Name it <HOST>_pre-upgrade_<yyyyMMdd> and note the retention you set.'; Command = $null }
            [pscustomobject]@{ Text = 'Confirm in vmm only after the snapshot shows as completed.'; Command = $null }
        }
        'ExpandDisk' {
            [pscustomobject]@{ Text = 'Grow the OS disk in the platform console first (vSphere: Edit settings > Hard disk 1).'; Command = $null }
            $open; $ps
            [pscustomobject]@{ Text = 'Extend C: into the new space:'; Command = "'rescan','select volume c','extend' | Set-Content `$env:TEMP\x.txt -Encoding ASCII; diskpart /s `$env:TEMP\x.txt" }
            [pscustomobject]@{ Text = 'If C: did not grow, a recovery partition sits after it: fix in Disk Management.'; Command = 'diskmgmt.msc' }
        }
        'Upgrade' {
            [pscustomobject]@{ Text = 'Confirm a rollback snapshot exists (PreSnapshot = Success) before you start.'; Command = $null }
            $open; $ps
            [pscustomobject]@{ Text = "Check the media is staged in ${target}:"; Command = "Get-ChildItem '$target'" }
            $iso = @($pk | Where-Object { $_.Kind -eq 'OsMedia' -and -not $_.Gate }) | Select-Object -First 1
            if ($iso) { [pscustomobject]@{ Text = 'Mount the OS image (Server 2012 or later) and note its drive letter:'; Command = "(Mount-DiskImage -ImagePath '$target\$($iso.DestName)' -PassThru | Get-Volume).DriveLetter" } }
            foreach ($s in @($pk | Where-Object { $_.Kind -eq 'HostFile' -and $_.Name -like 'SQLServer*' })) {
                [pscustomobject]@{ Text = "SQL Server update staged for this host (run it when your plan says so): $target\$($s.DestName)$(if ($s.Note) { ' - ' + $s.Note })"; Command = $null }
            }
            if ($cmd) { [pscustomobject]@{ Text = 'Start the upgrade (from config Upgrade.CommandLine):'; Command = $cmd } }
            else { [pscustomobject]@{ Text = 'Run the installer from the staged files (set Upgrade.CommandLine in Settings to show the exact command here).'; Command = $null } }
            [pscustomobject]@{ Text = 'Wait for the reboots to finish, reconnect, check services, then run Verify.'; Command = $null }
        }
        default { throw (New-VmmErrorRecord -Activity "No RDP guide for step '$Step'." -Category InvalidArgument) }
    }
    @($items)
}
