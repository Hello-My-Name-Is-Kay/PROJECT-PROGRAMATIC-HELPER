function Export-VmmHostAgent {
    <#
    .SYNOPSIS
        Builds the extractor: the .ps1 you run on a remote host in RDP/RDM when this terminal cannot read
        the host by itself (vmm snapshot tries the terminal first). -Generic = one file for every host.
    .DESCRIPTION
        By default the extractor is SNAPSHOT ONLY: it reads the host, writes one encrypted result file on
        the host's desktop and nothing else. The code for workflow steps is cut out of the file, so it
        cannot change a host. Steps are added only to a per-host extractor when Extractor.AllowSteps is
        true (vmm set -Name Extractor.AllowSteps -Value true).
        Every extractor carries this laptop's public key, so what it extracts can only be read here.
        1. The file goes to %LOCALAPPDATA%\VmMaintenance\agents and onto the clipboard as a file
           (Windows PowerShell 5.1): paste it on the host's desktop.
        2. On the host: right-click > Run with PowerShell (or powershell.exe -ExecutionPolicy Bypass -File ...).
           It extracts at once and saves VMM_<HOST>_<time>.vmm (encrypted) on the host's desktop.
        3. Copy that file to this laptop's Desktop or Downloads: vmm imports it on start, with E in the menu,
           or with vmm inbox.
        [SEC] No credentials inside. A snapshot extractor holds no host name, share path or address.
        A per-host steps extractor holds the share path and step notes for that host; the extractor's
        Finish removes it and its result files from the host.
    .PARAMETER Generic
        One extractor for every host (VmmExtractor.ps1): snapshot and encrypt, no per-host plan, no host name.
        Copy the same file to any host, in the fleet or not: the import adds a host the fleet does not know yet.
    .EXAMPLE
        Export-VmmHostAgent -HostName srv01
    .EXAMPLE
        vmm agent -HostName srv01
    .EXAMPLE
        vmm extractor            # generic: one file for every host
    #>
    [CmdletBinding(DefaultParameterSetName = 'Generic')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Host')][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9\-\.]{0,252}$')][string]$HostName,
        [Parameter(ParameterSetName = 'Generic')][switch]$Generic,
        [int]$ValidHours = 48,
        [switch]$NoClipboard,
        [switch]$PassThru
    )
    if (-not (Get-VmmSetting 'Features.HostAgent' -Default $true)) {
        throw (New-VmmErrorRecord -Activity 'Host agent export is turned off.' -Fix 'vmm set -Name Features.HostAgent -Value true' -Category NotEnabled -ErrorId 'VmmFeatureOff')
    }
    if ($PSCmdlet.ParameterSetName -eq 'Generic') { $Generic = [switch]$true }
    $template = Join-Path $script:ModuleRoot 'Resources\VmmHostAgent.ps1'
    if (-not (Test-Path -LiteralPath $template)) {
        throw (New-VmmErrorRecord -Activity 'Host agent template missing.' -Target $template -Fix 'Reinstall (Install.ps1) or restore the Resources folder.' -Category ObjectNotFound)
    }
    $src = [System.IO.File]::ReadAllText($template)
    $dir = Get-VmmPath -Name Agents
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $flat = { param($v) ("$v" -replace '[\r\n]+', ' ').Trim() }
    $rsa = Get-VmmAgentKey
    try { $pub = $rsa.ToXmlString($false) } finally { $rsa.Clear() }
    $lines = New-Object System.Collections.Generic.List[string]
    # Common to every extractor: time rules, thresholds, laptop public key (results are always encrypted),
    # inventory agent service names.
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
    $lines.Add('TargetOs=' + (Get-VmmSetting 'Policy.TargetOs' -Default '*Server 2019*'))
    $lines.Add('PublicKey=' + $pub)
    $lines.Add('Licence=' + [bool](Get-VmmSetting 'Fleet.WindowsLicence' -Default $true))
    # Snapshot only unless steps were switched on, and then only for a per-host extractor
    $withSteps = (-not $Generic) -and [bool](Get-VmmSetting 'Extractor.AllowSteps' -Default $false)
    $lines.Add('Mode=' + $(if ($withSteps) { 'Steps' } else { 'Snapshot' }))
    try { $svc = Get-VmmInventoryServiceMap; foreach ($k in $svc.Keys) { $lines.Add('Svc.' + $k + '=' + (@($svc[$k]) -join ';')) } }
    catch { Write-VmmLog 'Inventory field list not readable: the extractor uses its built-in agent service names.' -Level Warn }
    try {
        $agents = Get-VmmAgentCheckMap
        foreach ($k in $agents.Keys) {
            foreach ($fld in 'Services', 'Products', 'Drivers', 'Ports') { $lines.Add("Agt.$k.$fld=" + (@($agents[$k][$fld]) -join ';')) }
            foreach ($fld in 'Log', 'LogMaxAgeHours', 'MinVersion') { $lines.Add("Agt.$k.$fld=" + (& $flat $agents[$k][$fld])) }
        }
    } catch { Write-VmmLog 'Agent health list not readable: the extractor uses its built-in agent checks.' -Level Warn }

    $store = $null; $rec = $null
    if (-not $Generic) {
        $store = Read-VmmStore
        $rec = Get-VmmHostRecord -Store $store -Name $HostName
        # Terminal first: say so when this host can be read without anyone opening RDP
        $acc = Get-VmmHostAccess -Record $rec
        if ($acc.Terminal -eq $true) { Write-VmmLog "$($rec.Name) answers over the terminal ($($acc.Why)): vmm snapshot -Name $($rec.Name) reads it with no hands-on. The extractor is only for when that stops working." -Level Warn }
        elseif ($null -eq $acc.Terminal) { Write-VmmLog "$($rec.Name): $($acc.Why). Run vmm snapshot -Name $($rec.Name) first; hands-on only if the terminal fails." -Level Warn }
        if ($withSteps) {
            $lines.Add('Host=' + $rec.Name)
            $lines.Add('UpgradeCommand=' + (& $flat (Get-VmmSetting 'Upgrade.CommandLine' -Default '')))
            $lines.Add('Share=' + (Get-VmmSetting 'Staging.SourceShare' -Default ''))
        }
        $lines.Add('Platform=' + $rec.Platform)
        $lines.Add('AzureVm=' + $(if ($rec.Azure) { 'Yes' } else { 'No' }))
        $pol = Get-VmmHostPolicy -Record $rec
        $lines.Add('PolicyScope=' + $pol.Scope)
        $lines.Add('PolicyWhy=' + (& $flat $pol.Why))
        $lines.Add('PolicyWarnings=' + (& $flat ($pol.Warnings -join ' / ')))
        foreach ($p in $(if ($withSteps) { @($rec.Steps.PSObject.Properties) } else { @() })) {
            $lines.Add('Step.' + $p.Name + '=' + $p.Value.Status + '|' + $p.Value.At + '|' + (& $flat $p.Value.Note).Replace('|', '/'))
        }
        $pk = @(); try { $pk = @(Get-VmmStagingPackage -Record $rec) } catch { Write-VmmLog "Media repository not readable now ($($_.Exception.Message.Split([Environment]::NewLine)[0])): the extractor cannot check staged files." -Level Warn }
        foreach ($p in $pk) {
            if ($p.Gate) { Write-VmmLog "$($rec.Name): $($p.Gate)" -Level Warn; continue }
            # Snapshot: names only (is the file there?). Hash and share path travel only with steps.
            if ($withSteps) { $lines.Add('Package=' + (& $flat $p.Name).Replace('|', '/') + '|' + $p.DestName + '|' + $p.Sha256 + '|' + $p.Path) }
            else { $lines.Add('Package=' + (& $flat $p.Name).Replace('|', '/') + '|' + $p.DestName + '||') }
        }
    }
    $card = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))
    $marker = "`$CardText = ''   # VMM-CARD"
    if (-not $src.Contains($marker)) {
        throw (New-VmmErrorRecord -Activity 'Extractor template has no plan marker.' -Target $template -Fix 'Restore Resources\VmmHostAgent.ps1 from the repository.' -Category InvalidData)
    }
    $src = $src.Replace($marker, "`$CardText = '$card'   # VMM-CARD")
    if (-not $withSteps) {
        # Cut the steps code out: a snapshot extractor holds nothing that can change a host
        $b = $src.IndexOf('# VMM-STEPS-BEGIN'); $e = $src.IndexOf('# VMM-STEPS-END')
        if ($b -lt 0 -or $e -lt $b) {
            throw (New-VmmErrorRecord -Activity 'Extractor template has no steps markers.' -Target $template -Fix 'Restore Resources\VmmHostAgent.ps1 from the repository.' -Category InvalidData)
        }
        $src = $src.Substring(0, $b) + '# (snapshot extractor: built without the steps code)' + $src.Substring($e + '# VMM-STEPS-END'.Length)
    }

    if ($Generic) {
        $out = Join-Path $dir 'VmmExtractor.ps1'
    } else {
        Get-ChildItem -LiteralPath $dir -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ("VmmAgent_{0}_*.ps1" -f $rec.Name) -or $_.Name -like ("VmmExtractor_{0}_*.ps1" -f $rec.Name) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $out = Join-Path $dir ("VmmExtractor_{0}_{1}.ps1" -f $rec.Name, (Get-Date -Format 'yyyyMMddHHmm'))
    }
    [System.IO.File]::WriteAllText($out, $src, [Text.Encoding]::ASCII)
    if ($rec) {
        Set-VmmStepState -Record $rec -Step 'Agent' -Status 'Exported' -Note "$(if ($withSteps) { 'steps' } else { 'snapshot' }) extractor exported, valid $ValidHours h"
        Save-VmmStore -Store $store
    }

    $copied = $false
    if (-not $NoClipboard -and (Get-Command Set-Clipboard -ErrorAction SilentlyContinue).Parameters.ContainsKey('Path')) {
        try { Set-Clipboard -Path $out; $copied = $true } catch { }
    }
    Write-VmmLog "Extractor written: $out ($(if ($withSteps) { 'WITH STEPS for this host' } else { 'snapshot only, read-only' })$(if ($Generic) { ', works on any host: one the fleet does not know yet is added when its result is imported' }))" -Level Success
    if ($copied) { Write-VmmLog '1. It is on the clipboard: in RDP/RDM paste it on the host''s desktop (Ctrl+V).' -Level Info }
    else { Write-VmmLog '1. Copy that file to the host''s desktop (RDP clipboard or RDM file transfer).' -Level Info }
    Write-VmmLog '2. On the host: right-click the file > Run with PowerShell. It reads the host and saves VMM_<HOST>_<time>.vmm on the desktop - the only thing it writes.' -Level Info
    Write-VmmLog '3. Copy that .vmm file back to this laptop''s Desktop or Downloads. vmm imports it by itself (or press E in the menu / vmm inbox).' -Level Info
    if ($PassThru) { Get-Item -LiteralPath $out }
}
