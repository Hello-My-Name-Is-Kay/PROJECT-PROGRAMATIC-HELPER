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
    $open = [pscustomobject]@{ Text = "Connect to $h in RDM, or with RDP:"; Command = "mstsc /v:$h" }
    $ps   = [pscustomobject]@{ Text = 'Open Windows PowerShell as Administrator (right-click > Run as administrator).'; Command = $null }

    $items = switch ($Step) {
        { $_ -in 'Precheck', 'Verify' } {
            [pscustomobject]@{ Text = "Preferred: the host agent (status, steps, encrypted result). Build it with X on this host or: vmm agent -HostName $h. Paste it on the RDP desktop, then:"; Command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\' + "VmmAgent_$h" + '_<time>.ps1"' }
            [pscustomobject]@{ Text = 'Without the agent, the paste-in collector below does the same read-only check:'; Command = $null }
            $open; $ps
            [pscustomobject]@{ Text = 'Paste the collector (read-only). It prints a VMM1|... line and copies it to the clipboard.'; Command = (Get-VmmCollectorScript) }
            [pscustomobject]@{ Text = "Back on the laptop: press P on this host's screen (or run: vmm collect -Step $Step) to record the result."; Command = $null }
        }
        'Stage' {
            $open
            [pscustomobject]@{ Text = "Create $target if it is missing:"; Command = "New-Item -ItemType Directory -Path '$target' -Force" }
            $pk = try { @(Get-VmmStagingPackage -Record $null) } catch { @() }
            if (-not $pk) { [pscustomobject]@{ Text = 'No packages defined yet: add them to Staging.Packages (Settings > E).'; Command = $null } }
            foreach ($p in $pk) {
                [pscustomobject]@{ Text = "Copy $($p.Name) from the share:"; Command = "Copy-Item '$(Join-Path $share $p.Path)' '$target\' -Force" }
                if ($p.Sha256) { [pscustomobject]@{ Text = "Verify: the hash must be $($p.Sha256)"; Command = "(Get-FileHash '$target\$([IO.Path]::GetFileName($p.Path))' -Algorithm SHA256).Hash" } }
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
            if ($cmd) { [pscustomobject]@{ Text = 'Start the upgrade (from config Upgrade.CommandLine):'; Command = $cmd } }
            else { [pscustomobject]@{ Text = 'Run the installer from the staged files (set Upgrade.CommandLine in Settings to show the exact command here).'; Command = $null } }
            [pscustomobject]@{ Text = 'Wait for the reboots to finish, reconnect, check services, then run Verify.'; Command = $null }
        }
        default { throw (New-VmmErrorRecord -Activity "No RDP guide for step '$Step'." -Category InvalidArgument) }
    }
    @($items)
}
