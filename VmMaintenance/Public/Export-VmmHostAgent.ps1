function Export-VmmHostAgent {
    <#
    .SYNOPSIS
        Builds the host agent (VmmHostAgent.ps1) for one host: the generic agent plus that host's plan
        (step statuses, time rules, packages, upgrade command) and this laptop's public key.
    .DESCRIPTION
        Copy the file to the host's desktop through RDP/RDM, then on the host run:
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\VmmHostAgent.ps1"
        The agent exports an encrypted VMM2 line that only this laptop can read (vmm collect).
        The file is written to %LOCALAPPDATA%\VmMaintenance\agents and put on the clipboard as a file
        (Windows PowerShell 5.1) so you can paste it on the RDP desktop. Older agent files for the same
        host are deleted. [SEC] The file holds no credentials; it does hold the share path and step notes
        for that host, so delete it from the host with the agent's Finish option.
    .PARAMETER Generic
        The agent without a plan or key (status only; export unencrypted after confirmation).
    .EXAMPLE
        Export-VmmHostAgent -HostName srv01
    .EXAMPLE
        vmm agent -HostName srv01
    #>
    [CmdletBinding(DefaultParameterSetName = 'Host')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Host')][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9\-\.]{0,252}$')][string]$HostName,
        [Parameter(Mandatory, ParameterSetName = 'Generic')][switch]$Generic,
        [int]$ValidHours = 48,
        [switch]$NoClipboard,
        [switch]$PassThru
    )
    if (-not (Get-VmmSetting 'Features.HostAgent' -Default $true)) {
        throw (New-VmmErrorRecord -Activity 'Host agent export is turned off.' -Fix 'vmm set -Name Features.HostAgent -Value true' -Category NotEnabled -ErrorId 'VmmFeatureOff')
    }
    $template = Join-Path $script:ModuleRoot 'Resources\VmmHostAgent.ps1'
    if (-not (Test-Path -LiteralPath $template)) {
        throw (New-VmmErrorRecord -Activity 'Host agent template missing.' -Target $template -Fix 'Reinstall (Install.ps1) or restore the Resources folder.' -Category ObjectNotFound)
    }
    $src = [System.IO.File]::ReadAllText($template)
    $dir = Get-VmmPath -Name Agents
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if ($Generic) {
        $out = Join-Path $dir 'VmmHostAgent.ps1'
        [System.IO.File]::WriteAllText($out, $src, [Text.Encoding]::ASCII)
    } else {
        $store = Read-VmmStore
        $rec = Get-VmmHostRecord -Store $store -Name $HostName
        $rsa = Get-VmmAgentKey
        try { $pub = $rsa.ToXmlString($false) } finally { $rsa.Clear() }

        $flat = { param($v) ("$v" -replace '[\r\n]+', ' ').Trim() }
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('Host=' + $rec.Name)
        $lines.Add('Generated=' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
        $lines.Add('ValidHours=' + $ValidHours)
        $lines.Add('TimeZoneId=' + (Get-VmmSetting 'Schedule.TimeZoneId' -Default 'GMT Standard Time'))
        $lines.Add('BusinessDays=' + (@(Get-VmmSetting 'Schedule.BusinessDays' -Default @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')) -join ','))
        $lines.Add('BusinessStart=' + (Get-VmmSetting 'Schedule.BusinessStart' -Default '08:00'))
        $lines.Add('BusinessEnd=' + (Get-VmmSetting 'Schedule.BusinessEnd' -Default '17:00'))
        $lines.Add('OffHoursWeekdays=' + [bool](Get-VmmSetting 'Schedule.AllowChangesOffHoursWeekdays' -Default $true))
        $lines.Add('Holidays=' + (@(Get-VmmSetting 'Schedule.Holidays' -Default @()) -join ','))
        $lines.Add('OkGB=' + ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', (Get-VmmSetting 'Lansweeper.OkGB' -Default 40))))
        $lines.Add('CriticalGB=' + ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', (Get-VmmSetting 'Lansweeper.CriticalGB' -Default 32))))
        $lines.Add('TargetFolder=' + (Get-VmmSetting 'Staging.TargetFolder' -Default 'C:\Temp'))
        $lines.Add('ExpectedOs=' + (& $flat (Get-VmmSetting 'Upgrade.ExpectedOs' -Default '*Server 2019*')))
        $lines.Add('UpgradeCommand=' + (& $flat (Get-VmmSetting 'Upgrade.CommandLine' -Default '')))
        $lines.Add('Share=' + (Get-VmmSetting 'Staging.SourceShare' -Default ''))
        $lines.Add('Platform=' + $rec.Platform)
        $lines.Add('AzureVm=' + $(if ($rec.Azure) { 'Yes' } else { 'No' }))
        $lines.Add('PublicKey=' + $pub)
        try { $svc = Get-VmmInventoryServiceMap; foreach ($k in $svc.Keys) { $lines.Add('Svc.' + $k + '=' + (@($svc[$k]) -join ';')) } }
        catch { Write-VmmLog 'Inventory field list not readable: the agent uses its built-in agent service names.' -Level Warn }
        $pol = Get-VmmHostPolicy -Record $rec
        $lines.Add('TargetOs=' + (Get-VmmSetting 'Policy.TargetOs' -Default '*Server 2019*'))
        $lines.Add('PolicyScope=' + $pol.Scope)
        $lines.Add('PolicyWhy=' + (& $flat $pol.Why))
        $lines.Add('PolicyWarnings=' + (& $flat ($pol.Warnings -join ' / ')))
        foreach ($p in $rec.Steps.PSObject.Properties) {
            $lines.Add('Step.' + $p.Name + '=' + $p.Value.Status + '|' + $p.Value.At + '|' + (& $flat $p.Value.Note).Replace('|', '/'))
        }
        $pk = @(); try { $pk = @(Get-VmmStagingPackage -Record $rec) } catch { Write-VmmLog "Media repository not readable now ($($_.Exception.Message.Split([Environment]::NewLine)[0])): the agent cannot check staged files." -Level Warn }
        foreach ($p in $pk) {
            if ($p.Gate) { Write-VmmLog "$($rec.Name): $($p.Gate)" -Level Warn; continue }
            $lines.Add('Package=' + (& $flat $p.Name).Replace('|', '/') + '|' + $p.DestName + '|' + $p.Sha256 + '|' + $p.Path)
        }
        $card = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))
        $marker = "`$CardText = ''   # VMM-CARD"
        if (-not $src.Contains($marker)) {
            throw (New-VmmErrorRecord -Activity 'Host agent template has no plan marker.' -Target $template -Fix 'Restore Resources\VmmHostAgent.ps1 from the repository.' -Category InvalidData)
        }
        $src = $src.Replace($marker, "`$CardText = '$card'   # VMM-CARD")

        Get-ChildItem -LiteralPath $dir -Filter ("VmmAgent_{0}_*.ps1" -f $rec.Name) -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $out = Join-Path $dir ("VmmAgent_{0}_{1}.ps1" -f $rec.Name, (Get-Date -Format 'yyyyMMddHHmm'))
        [System.IO.File]::WriteAllText($out, $src, [Text.Encoding]::ASCII)
        Set-VmmStepState -Record $rec -Step 'Agent' -Status 'Exported' -Note "host agent exported, valid $ValidHours h"
        Save-VmmStore -Store $store
    }

    $copied = $false
    if (-not $NoClipboard -and (Get-Command Set-Clipboard -ErrorAction SilentlyContinue).Parameters.ContainsKey('Path')) {
        try { Set-Clipboard -Path $out; $copied = $true } catch { }
    }
    Write-VmmLog "Host agent written: $out" -Level Success
    if ($copied) { Write-VmmLog 'File is on the clipboard: paste it on the host''s desktop in RDP/RDM (Ctrl+V).' -Level Info }
    else { Write-VmmLog 'Copy the file to the host''s desktop (RDP clipboard or RDM file transfer).' -Level Info }
    Write-VmmLog 'On the host:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\<file>.ps1"' -Level Info
    Write-VmmLog 'Back here:   vmm collect   (or P on the host screen) with the VMM2 line the agent copies.' -Level Info
    if ($PassThru) { Get-Item -LiteralPath $out }
}
