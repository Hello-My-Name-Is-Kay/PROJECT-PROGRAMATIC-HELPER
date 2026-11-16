function Start-VmmSetupWizard {
    <#
    .SYNOPSIS
        First-run / setup wizard: walks through every option page by page, explains each one, shows
        the important warnings (you type YES), validates answers and saves them to your local config.
    .DESCRIPTION
        Runs from Install.ps1, on the first 'vmm' start when no config exists, and any time with
        'vmm setup' (or W in the console). Enter keeps the value in brackets. Nothing is saved until
        the summary page is confirmed. Never asks for, or stores, usernames or passwords.
    .PARAMETER Page
        Open one page only: Rules, Staging, Workflow, Access, Vpn, Ai, GitHub, Display.
    .PARAMETER AcceptDefaults
        No questions: keep current/default values (warnings are still printed).
    .EXAMPLE
        Start-VmmSetupWizard
    .EXAMPLE
        vmm setup -Page Vpn
    #>
    [CmdletBinding()]
    param([ValidateSet('All', 'Rules', 'Staging', 'Workflow', 'Access', 'Inventory', 'Vpn', 'Ai', 'GitHub', 'Display')][string]$Page = 'All', [switch]$AcceptDefaults)

    if (-not (Resolve-VmmConfigPath)) { Initialize-VmmConfig | Out-Null }
    if (-not $script:VmmConfig) { Import-VmmConfig | Out-Null }
    Suspend-VmmConsoleInput

    $answers = [ordered]@{}
    $cur = { param($k, $d) try { $v = Get-VmmSetting $k -Default $d; if ($v -is [array]) { $v -join ',' } else { "$v" } } catch { "$d" } }
    # What each rule accepts, shown with the question when it is not obvious and after every invalid answer
    $accepts = @{
        time   = 'a 24-hour time HH:mm, e.g. 08:00 or 17:00'
        int    = 'a whole number from 1 to 9999'
        bool   = 'yes or no (y/n, true/false)'
        share  = 'a network path like \\server\share\folder, or Enter to leave it empty'
        url    = 'an address starting with http:// or https://, or Enter to leave it empty'
        tz     = 'a city or country (Lisbon, London, Portugal), a Windows id (GMT Standard Time) or part of a zone name (UTC+01:00)'
        choice = 'one of the options in brackets (upper/lower case does not matter)'
    }
    $ask = {
        param($key, $question, $default, [string]$rule = 'any', [string[]]$choices)
        $d = & $cur $key $default
        $tries = 0
        while ($true) {
            if ($AcceptDefaults) { $a = $d } else {
                $hint = if ($choices) { ' (' + ($choices -join ' | ') + ')' } else { '' }
                $a = Read-Host ("  {0}{1} [{2}]" -f $question, $hint, $d)
                if ([string]::IsNullOrWhiteSpace($a)) { $a = $d } else { $a = $a.Trim() }
            }
            if ($a -eq '?') { Write-VmmLog "  Accepted: $($accepts[$rule]). Enter keeps [$d]." -Level Info; continue }
            $ok = $false; $retry = $false   # 'continue' inside switch would only leave the switch
            switch ($rule) {
                'time'  { if ($a -match '^(\d{1,2})[:h\.]?(\d{2})$' -and [int]$Matches[1] -le 23 -and [int]$Matches[2] -le 59) { $a = '{0:D2}:{1}' -f [int]$Matches[1], $Matches[2]; $ok = $true } }
                'int'   { $ok = $a -match '^\d{1,4}$' -and [int]$a -ge 1 }
                'bool'  { if ($a -match '^(?i)(true|false|yes|no|y|n|1|0|on|off|sim|nao|s)$') { $a = [string]($a -match '^(?i)(true|yes|y|1|on|sim|s)$'); $ok = $true } }
                'share' { $ok = $a -eq '' -or $a -match '^\\\\[^\\]+\\[^\\]+' }
                'url'   { $ok = $a -eq '' -or $a -match '^https?://[^\s]+$' }
                'choice' { $hit = @($choices | Where-Object { $_ -ieq $a }); if ($hit.Count -eq 1) { $a = $hit[0]; $ok = $true } }
                'tz' {
                    $z = Resolve-VmmTimeZone -Text $a
                    if ($z.Id) {
                        $tzi = [TimeZoneInfo]::FindSystemTimeZoneById($z.Id)
                        if ($z.Id -ne $a) { Write-VmmLog "  '$a' -> $($z.Id)  $($tzi.DisplayName)" -Level Success }
                        $a = $z.Id; $ok = $true
                    } elseif ($z.Matches.Count -and -not $AcceptDefaults) {
                        Write-VmmLog "  '$a' matches several time zones:" -Level Warn
                        for ($i = 0; $i -lt $z.Matches.Count; $i++) { Write-Host ("    {0,2}. {1,-34} {2}" -f ($i + 1), $z.Matches[$i].Id, $z.Matches[$i].DisplayName) }
                        $n = Read-Host '  Number (Enter = type again)'
                        $k = 0
                        if ([int]::TryParse($n, [ref]$k) -and $k -ge 1 -and $k -le $z.Matches.Count) { $a = $z.Matches[$k - 1].Id; $ok = $true } else { $retry = $true }
                    }
                }
                default { $ok = $true }
            }
            if ($retry) { continue }
            if ($ok) {
                if ($a -ne $d -or $AcceptDefaults) { $answers[$key] = $a }
                return $a
            }
            $tries++
            if ($AcceptDefaults) { return $d }
            if ($tries -ge 3) {
                Write-VmmLog "  Keeping [$d] after 3 tries. Change it later with: vmm setup, or Settings (9)." -Level Warn
                return $d
            }
            Write-VmmLog "  '$a' was not accepted. Expected: $($accepts[$rule])$(if ($choices) { ': ' + ($choices -join ', ') }). Enter keeps [$d]; ? shows this help." -Level Warn
        }
    }
    $title = { param($t, $why) Write-Host ''; Write-VmmLog "== $t ==" -Level Info; foreach ($l in $why) { Write-VmmLog "  $l" -Level Muted } }
    $want = { param($p) $Page -eq 'All' -or $Page -eq $p }

    try {
        if ($Page -eq 'All') {
            & $title 'VmMaintenance setup' @('Enter keeps the value in [brackets]. Type ? at any question to see what it accepts.', 'Every answer can be changed later: vmm setup, or Settings (9) in the console.')
            Write-VmmLog '  IMPORTANT - read before continuing:' -Level Warn
            Write-VmmLog '  1. Fleet data is encrypted with a key that only YOUR Windows account on THIS laptop can open (DPAPI).' -Level Warn
            Write-VmmLog '     A password reset by an administrator or a new profile makes it unreadable. Daily exports are your backup.' -Level Warn
            Write-VmmLog '  2. Daily and blocker reports are plaintext (host names, no credentials) because they are for your manager.' -Level Warn
            Write-VmmLog '  3. Changes to hosts in business hours are blocked. Overrides are for agreed emergencies and are reported.' -Level Warn
            Write-VmmLog '  4. Usernames and passwords are never stored. You are asked for them in every session.' -Level Warn
            Write-VmmLog '  5. Host agents (.ps1 copied to a host) must be removed with their Finish option at the end of the cycle.' -Level Warn
            if (-not $AcceptDefaults) {
                if ((Read-Host '  Type YES to confirm you read the points above') -cne 'YES') { Write-VmmLog 'Setup cancelled - nothing saved.' -Level Muted; return }
            }
        }
        if (& $want 'Rules') {
            & $title 'Working rules' @('Business hours: only read-only checks and staging into C:\Temp. Outside them: all steps.')
            [void](& $ask 'Schedule.TimeZoneId' 'Time zone (city like Lisbon, or Windows id; Enter keeps Lisbon/London time)' 'GMT Standard Time' 'tz')
            [void](& $ask 'Schedule.BusinessStart' 'Business hours start' '08:00' 'time')
            [void](& $ask 'Schedule.BusinessEnd' 'Business hours end' '17:00' 'time')
            [void](& $ask 'Schedule.AllowChangesOffHoursWeekdays' 'Allow changes on weekdays outside business hours' 'True' 'bool')
            [void](& $ask 'Target.MachinesPerDay' 'Daily target, machines' '10' 'int')
            [void](& $ask 'Target.WorkdayHours' 'Workday length, hours' '9' 'int')
        }
        if (& $want 'Staging') {
            & $title 'Staging' @('Media repository: Windows Server images at its root (Win_Server_2019_FR_FR.iso), one folder per host for that host''s own files (SQL Server updates).', 'Each host gets the image in its own install language plus its folder, copied to the folder on the host. Check it any time: vmm media.')
            [void](& $ask 'Staging.SourceShare' 'Media repository (\\server\share\project\iso-folder, empty = later)' '' 'share')
            [void](& $ask 'Staging.OsMediaVersion' 'Windows Server image version to stage' '2019' 'choice' @('2012R2', '2016', '2019', '2022', '2025'))
            [void](& $ask 'Staging.TargetFolder' 'Folder on each host' 'C:\Temp')
        }
        if (& $want 'Workflow') {
            & $title 'Workflow and snapshots' @('ChangingSteps = checkpoint snapshot after ExpandDisk and Upgrade (Azure VMs). EveryStep adds Precheck/Stage/Verify (costs storage, no extra rollback value).')
            [void](& $ask 'Workflow.StartSnapshotMaxAgeMinutes' 'Skip the start snapshot when every disk has one from the last N minutes' '60' 'int')
            [void](& $ask 'Workflow.SnapshotRetentionDays' 'Days before snapshot-point snapshots may be pruned' '7' 'int')
            [void](& $ask 'Upgrade.Mode' 'Upgrade run by' 'Guided' 'choice' @('Guided', 'RunCommand'))
            [void](& $ask 'Upgrade.CommandLine' 'Exact upgrade command (shown in guides and the host agent; empty = later)' '')
            [void](& $ask 'Upgrade.ExpectedOs' 'Verify passes only if the OS matches (wildcards)' '*Server 2019*')
            [void](& $ask 'Policy.TargetOs' 'Target OS for every machine (client OS is skipped unless ordered)' '*Server 2019*')
            [void](& $ask 'Policy.WarnPhysical' 'Warn management about physical machines' 'True' 'bool')
        }
        if (& $want 'Access') {
            & $title 'Access' @('Prompt = you type a host admin account each session (memory only). CurrentUser = your logged-on Windows identity.')
            [void](& $ask 'Credentials.WindowsMode' 'Host credential mode' 'Prompt' 'choice' @('Prompt', 'CurrentUser'))
            [void](& $ask 'Azure.TenantId' 'Azure tenant id (empty = choose in vmm > Azure)' '')
            [void](& $ask 'Azure.Subscription' 'Azure subscription id or name (empty = choose later)' '')
            [void](& $ask 'Azure.UseDeviceAuthentication' 'Sign in with a device code instead of a browser pop-up' 'False' 'bool')
            [void](& $ask 'Lansweeper.SqlInstance' 'Lansweeper SQL instance host\instance (empty = not used)' '')
        }
        if (& $want 'Inventory') {
            & $title 'Inventory' @('The 24-column server inventory is filled from the checks and the host agent; the rest you type, with a help window per column (I on a host).', 'Values that are the same for most hosts can be set once here (empty = ask per host). Change a host later with I or vmm inventory-set.')
            [void](& $ask 'Inventory.Defaults.AssignedTechnician' 'Assigned Technician (usually you)' '')
            [void](& $ask 'Inventory.Defaults.Company' 'Company (if the same for most hosts)' '')
            [void](& $ask 'Inventory.Defaults.Perimeter' 'Perimeter (if the same for most hosts)' '')
            [void](& $ask 'Inventory.Defaults.Phase' 'Phase / wave (if the same for most hosts)' '')
            [void](& $ask 'Inventory.CsvDelimiter' 'CSV separator for the export (comma, or ; for Excel in PT/FR)' ',' 'choice' @(',', ';'))
        }
        if (& $want 'Vpn') {
            & $title 'VPN' @('The tool can check and start your VPN before host work. You always sign in inside the VPN client; credentials never pass through this tool.',
                'CiscoSecureClient uses vpncli.exe. Windows = built-in VPN profile. Probe = any other client: status by testing an internal host.')
            $prov = & $ask 'Vpn.Provider' 'VPN provider' 'None' 'choice' @('None', 'CiscoSecureClient', 'Windows', 'Probe')
            if ($prov -ne 'None') {
                [void](& $ask 'Vpn.Profile' 'VPN profile/address (Cisco) or connection name (Windows)' '')
                [void](& $ask 'Vpn.ProbeHost' 'Internal host that only answers over the VPN (empty = none)' '')
                [void](& $ask 'Vpn.ProbePort' 'Probe TCP port' '445' 'int')
                [void](& $ask 'Vpn.RequireForHostWork' 'Stop host work when the VPN is down' 'True' 'bool')
            }
        }
        if (& $want 'Ai') {
            & $title 'AI assistant (optional, off by default)' @('Advisory only: explains errors, suggests next steps, drafts wording. It cannot run commands or change files.',
                'Local = Microsoft Foundry Local / Ollama on this laptop (nothing leaves it). AzureOpenAI = your organisation''s Azure OpenAI, signed in with your work account.',
                'Consumer Copilot has no API. Host names are replaced by aliases before sending; you confirm each send. See docs\AI.md.')
            $on = & $ask 'Features.Ai' 'Turn the assistant on' 'False' 'bool'
            if ($on -eq 'True') {
                Write-VmmLog '  WARNING: with AzureOpenAI, sanitized text leaves the laptop to your organisation''s Azure tenant. Check your company AI policy first.' -Level Warn
                $ap = & $ask 'Ai.Provider' 'Provider' 'Local' 'choice' @('Local', 'AzureOpenAI')
                if ($ap -eq 'Local') {
                    [void](& $ask 'Ai.Endpoint' 'Local endpoint (Foundry Local: foundry service status; Ollama: http://localhost:11434/v1)' 'http://localhost:5273/v1' 'url')
                    [void](& $ask 'Ai.Model' 'Model name' 'phi-4-mini')
                } else {
                    [void](& $ask 'Ai.Endpoint' 'Azure OpenAI endpoint (https://<resource>.openai.azure.com)' '' 'url')
                    [void](& $ask 'Ai.Deployment' 'Deployment name' '')
                }
                [void](& $ask 'Ai.ConfirmEachSend' 'Show and confirm every text before it is sent' 'True' 'bool')
            }
        }
        if (& $want 'GitHub') {
            & $title 'GitHub (updates, issues, pull requests)' @('Uses the GitHub CLI (gh) and ITS sign-in; vmm never stores a token. Keep the repository private.',
                'The local clone is where updates are pulled and pull requests are pushed from.')
            $hasGh = [bool](Get-Command gh -ErrorAction SilentlyContinue)
            if (-not $hasGh) { Write-VmmLog '  GitHub CLI not found: winget install GitHub.cli, then reopen the terminal. You can fill this page now anyway.' -Level Warn }
            [void](& $ask 'GitHub.Repo' 'Repository (owner/name, empty = no GitHub integration)' '')
            [void](& $ask 'GitHub.Branch' 'Branch to update from' 'main')
            $defClone = if ($script:VmmInstallSource -and (Test-Path -LiteralPath (Join-Path $script:VmmInstallSource '.git'))) { $script:VmmInstallSource } else { '' }
            [void](& $ask 'GitHub.SourcePath' 'Local clone folder (empty = clone later with U > C)' $defClone)
            [void](& $ask 'GitHub.CheckOnStart' 'Check for updates when vmm starts' 'True' 'bool')
            if ($hasGh -and -not $AcceptDefaults) {
                $null = & gh auth status --hostname github.com 2>&1
                if ($LASTEXITCODE -ne 0 -and (Read-Host '  Not signed in to GitHub. Sign in now with gh auth login? (Y/n)') -notmatch '^[nN]') {
                    & gh auth login --hostname github.com --git-protocol https --web
                }
            }
        }
        if (& $want 'Display') {
            & $title 'Display and reports' @('Mouse works in Windows Terminal and the classic console.')
            [void](& $ask 'UI.Mouse' 'Mouse support' 'True' 'bool')
            [void](& $ask 'Reports.ManagerName' 'Manager name for report greetings (optional)' '')
        }

        Write-Host ''
        if (-not $answers.Count) { Write-VmmLog 'No changes.' -Level Success; return }
        Write-VmmLog '== Summary ==' -Level Info
        foreach ($k in $answers.Keys) {
            $shown = if ($k -match 'Tenant|Subscription' -and $answers[$k]) { '(set)' } else { $answers[$k] }
            Write-VmmLog ('  {0,-40} {1}' -f $k, $shown)
        }
        if (-not $AcceptDefaults -and (Read-Host '  Save these settings? (Y/n)') -match '^[nN]') { Write-VmmLog 'Nothing saved.' -Level Muted; return }
        foreach ($k in $answers.Keys) {
            try { Set-VmmSetting -Name $k -Value $answers[$k] | Out-Null }
            catch { Write-VmmLog "  $k not saved: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -Level Error }
        }
        Write-VmmLog "Settings saved to $script:VmmConfigPath" -Level Success
    } finally { Resume-VmmConsoleInput }
}
