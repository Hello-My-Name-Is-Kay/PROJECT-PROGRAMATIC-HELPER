function Show-VmmSettingsScreen {
    # Every question the tool could ask is a setting here. Enter edits; E opens the whole file.
    [CmdletBinding()]
    param()
    $keys = @(
        @('Staging.SourceShare', 'Media repository: OS images at the root, one folder per host')
        @('Staging.OsMediaVersion', 'Windows Server image version to stage (2019 = target)')
        @('Downloads.CacheFolder', 'SQL update download cache (empty = <share>\_Downloads)')
        @('SqlUpdates.MaxBehind', 'SQL updates: empty = latest SP/CU, 1CU = one CU behind is fine')
        @('Collect.AutoImport', 'Import extractor result files from Desktop/Downloads at start')
        @('Inventory.Defaults.AssignedTechnician', 'Inventory: default Assigned Technician')
        @('Inventory.Defaults.Phase', 'Inventory: default Phase')
        @('Inventory.CsvDelimiter', 'Inventory CSV separator: , or ;')
        @('Staging.Layout', 'Repository (images + host folders) | Packages (fixed list only)')
        @('Staging.TargetFolder', 'Folder on each host files are copied TO')
        @('Target.MachinesPerDay', 'Daily target (machines)')
        @('Target.WorkdayHours', 'Workday length used for pace')
        @('Schedule.TimeZoneId', 'Working time zone (Windows id; Lisbon = GMT Standard Time)')
        @('Schedule.BusinessStart', 'Business hours start (no changes)')
        @('Schedule.BusinessEnd', 'Business hours end')
        @('Schedule.AllowChangesOffHoursWeekdays', 'Allow changes on weekdays outside business hours')
        @('Workflow.SnapshotAfter', 'Checkpoint snapshots: ChangingSteps | EveryStep | Off')
        @('Workflow.CheckpointRetentionDays', 'Days before checkpoints can be pruned')
        @('Credentials.WindowsMode', 'Prompt (ask each session) | CurrentUser (no prompt)')
        @('Azure.UseDeviceAuthentication', 'Device-code sign-in instead of browser pop-up')
        @('Azure.DisableLoginPicker', 'Turn off the Az tenant/subscription picker')
        @('Upgrade.Mode', 'Guided (RDP) | RunCommand (Azure: launch setup remotely)')
        @('Upgrade.CommandLine', 'Exact upgrade command shown in guides / used by RunCommand')
        @('Upgrade.ExpectedOs', 'Verify passes only if OS matches (wildcards)')
        @('Fleet.Throttle', 'Hosts checked in parallel')
        @('Log.Live', 'Live log pane + progress lines (F2 on any screen)')
        @('Log.PaneLines', 'Rows of the live log pane (2-20)')
        @('Log.KeepDays', 'Days of log files kept')
        @('Log.Encrypt', 'Encrypt log lines on disk (read with vmm log)')
        @('Reports.ManagerName', 'Greeting name in blocker reports (optional)')
        @('UI.Mouse', 'Mouse support in this console')
        @('GitHub.Repo', 'owner/name of the private repository (updates, issues, PRs)')
        @('GitHub.SourcePath', 'Local git clone used by update and pull requests')
        @('GitHub.CheckOnStart', 'Check for updates when vmm starts')
        @('Vpn.Provider', 'None | CiscoSecureClient | Windows | Probe')
        @('Vpn.Profile', 'Cisco address/profile or Windows VPN connection name')
        @('Vpn.ProbeHost', 'Internal host that only answers over the VPN')
        @('Vpn.RequireForHostWork', 'Stop checks/staging when the VPN is down')
        @('Features.HostAgent', 'Host agent export (X on a host)')
        @('Features.Ai', 'Optional AI assistant (off by default)')
        @('Ai.Provider', 'Local (Foundry Local/Ollama) | AzureOpenAI (work account)')
        @('Ai.Endpoint', 'Local: http://localhost:<port>/v1 | Azure: https://<res>.openai.azure.com')
        @('Ai.Model', 'Local model name')
        @('Ai.Deployment', 'Azure OpenAI deployment name')
        @('Ai.ConfirmEachSend', 'Show and confirm every text before it is sent')
    )
    $sel = 0; $status = ''
    while ($true) {
        $rows = foreach ($k in $keys) {
            $v = try { Get-VmmSetting $k[0] -Default '(default)' } catch { '<placeholder - set me>' }
            @{ Text = ('{0,-38} {1,-30} {2}' -f $k[0], ("$v" -replace '^(.{0,30}).*', '$1'), $k[1]) }
        }
        $r = Invoke-VmmListView -Title "Settings - $script:VmmConfigPath" -ColumnHeader ('  {0,-38} {1,-30} {2}' -f 'Setting', 'Value', 'Meaning') `
             -Rows @($rows) -Selected $sel -Status $status -Hotkeys @('E') -Help 'Enter edit | E open config in Notepad (packages, tags) | Esc back'
        $sel = $r.Index; $status = ''
        switch ($r.Action) {
            'Esc'   { return }
            'E'     { Start-Process notepad.exe -ArgumentList "`"$script:VmmConfigPath`"" -Wait; try { Import-VmmConfig -Path $script:VmmConfigPath | Out-Null; $status = 'Config reloaded' } catch { $status = "Config error: $($_.Exception.Message.Split([Environment]::NewLine)[0])" }; Clear-Host }
            'Enter' {
                $k = $keys[$r.Index][0]
                $v = Read-VmmPrompt "New value for $k (empty = cancel)"
                if ($v) { try { Set-VmmSetting -Name $k -Value $v; $status = "$k updated" } catch { $status = $_.Exception.Message.Split([Environment]::NewLine)[0] } }
                Clear-Host
            }
        }
    }
}
