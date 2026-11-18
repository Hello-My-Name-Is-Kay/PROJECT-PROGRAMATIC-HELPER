function Get-VmmBuiltinWorkflow {
    # Built-in part of the workflow catalog (code, not stored): one action per workflow step, the non-invasive
    # read-only actions, two workflows and a few generic known fixes. Built-ins cannot be edited or deleted;
    # copy one (C in the workflow manager) to change it.
    #   Default  wf-default   the ten maintenance steps (Get-VmmWorkflowDefinition), the DEFAULT for every host
    #   ReadOnly wf-readonly  non-invasive checks only, every one can run in a host runbook (RDP paste)
    # Action fields: Id, Name, Title, Category ReadOnly|Staging|Change, Group, Mode Auto|Guided|Hybrid,
    # Builtin (workflow step name or $null), Steps (instruction lines), Commands (text to paste on the host),
    # Expect (what success looks like), RunOnHost (read-only commands a runbook may run on the host).
    # Commands are PowerShell 2.0 compatible: the oldest supported host is Windows Server 2008 R2.
    [CmdletBinding()]
    param()
    $t0 = '2026-11-17T00:00:00.0000000Z'
    $actions = New-Object System.Collections.Generic.List[object]
    foreach ($s in Get-VmmWorkflowDefinition) {
        $actions.Add([pscustomobject]@{
            Id = "b-step-$($s.Name.ToLower())"; Name = $s.Name; Title = $s.Title; Category = $s.Class; Group = 'Maintenance'
            Mode = $s.Mode; Builtin = $s.Name; BuiltinItem = $true; RunOnHost = $false
            Steps = @("Workflow step $($s.Order) of the maintenance workflow. Enter = run it from vmm (its own checks and gates apply); G = the RDP guide.")
            Commands = @(); Expect = 'vmm records the result itself.'; Created = $t0; Updated = $t0
        })
    }
    $ro = @(
        @{ Id = 'b-ro-os'; Name = 'OS and uptime'; Group = 'OS'; Title = 'Windows version, build, service pack, last boot'
           Steps = @('Open Windows PowerShell on the host (Start > Windows PowerShell).', 'Paste the command, press Enter, read the output.')
           Commands = @('Get-WmiObject Win32_OperatingSystem | Select-Object Caption, Version, CSDVersion, OSArchitecture, @{n=''LastBoot'';e={$_.ConvertToDateTime($_.LastBootUpTime)}} | Format-List')
           Expect = 'Caption shows Windows Server; note the version and when it last booted.' }
        @{ Id = 'b-ro-disk'; Name = 'Disk space'; Group = 'Disk'; Title = 'Size and free space of every fixed drive'
           Steps = @('Paste the command in PowerShell on the host.', 'C: needs the free space your Lansweeper.OkGB setting asks for (ExpandDisk otherwise).')
           Commands = @('Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" | Select-Object DeviceID, @{n=''SizeGB'';e={[math]::Round($_.Size/1GB,1)}}, @{n=''FreeGB'';e={[math]::Round($_.FreeSpace/1GB,1)}} | Format-Table -AutoSize')
           Expect = 'One line per drive with SizeGB and FreeGB.' }
        @{ Id = 'b-ro-reboot'; Name = 'Pending reboot'; Group = 'OS'; Title = 'Is a reboot pending (servicing, Windows Update, file renames)?'
           Steps = @('Paste the command in PowerShell on the host.', 'A pending reboot must be cleared (after hours) before patching or upgrading.')
           Commands = @('$p = @(); if (Test-Path ''HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'') { $p += ''Servicing'' }; if (Test-Path ''HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'') { $p += ''WindowsUpdate'' }; if ((Get-ItemProperty ''HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'' -ErrorAction SilentlyContinue).PendingFileRenameOperations) { $p += ''FileRename'' }; if ($p.Count) { ''Reboot pending: '' + ($p -join '', '') } else { ''No reboot pending'' }')
           Expect = 'No reboot pending (or the reason it is pending).' }
        @{ Id = 'b-ro-roles'; Name = 'Server roles'; Group = 'OS'; Title = 'Domain controller? Cluster? (management must be warned)'
           Steps = @('Paste the command in PowerShell on the host.', 'DomainRole 4 or 5 = domain controller; a cluster service means a cluster node: tell management before any change.')
           Commands = @('$cs = Get-WmiObject Win32_ComputerSystem; ''DomainRole: '' + $cs.DomainRole + '' (4/5 = domain controller)''; if (Get-Service ClusSvc -ErrorAction SilentlyContinue) { ''Cluster service present: cluster node'' } else { ''No cluster service'' }')
           Expect = 'DomainRole 0-3 and no cluster service, or management informed.' }
        @{ Id = 'b-ro-sql'; Name = 'SQL Server instances'; Group = 'SQL'; Title = 'SQL Server instances and their services'
           Steps = @('Paste the command in PowerShell on the host.', 'Note every instance: each one is patched or upgraded on its own.')
           Commands = @('$k = Get-ItemProperty ''HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'' -ErrorAction SilentlyContinue; if ($k -and $k.InstalledInstances) { ''Instances: '' + ($k.InstalledInstances -join '', '') } else { ''No 64-bit SQL Server instance in the registry'' }; Get-Service | Where-Object { $_.Name -like ''MSSQL*'' -or $_.Name -like ''SQLAgent*'' -or $_.Name -like ''SQLServer*'' } | Select-Object Name, Status, DisplayName | Format-Table -AutoSize')
           Expect = 'Instance names and their services with status.' }
        @{ Id = 'b-ro-services'; Name = 'Stopped automatic services'; Group = 'Services'; Title = 'Automatic services that are not running'
           Steps = @('Paste the command in PowerShell on the host.', 'Write down what is stopped BEFORE you change anything, so the post-check can compare.')
           Commands = @('Get-WmiObject Win32_Service -Filter "StartMode=''Auto'' AND State<>''Running''" | Select-Object Name, State, DisplayName | Format-Table -AutoSize')
           Expect = 'A short list (some services stop by design, such as gupdate or sppsvc).' }
        @{ Id = 'b-ro-events'; Name = 'Recent errors'; Group = 'Events'; Title = 'System and Application errors in the last 24 hours'
           Steps = @('Paste the command in PowerShell on the host.', 'Repeated errors (disk, NTFS, SQL) are a reason to stop and report before changing the host.')
           Commands = @('foreach ($l in ''System'', ''Application'') { ''== '' + $l; Get-EventLog -LogName $l -EntryType Error -After (Get-Date).AddHours(-24) -ErrorAction SilentlyContinue | Select-Object -First 15 TimeGenerated, Source, EventID | Format-Table -AutoSize }')
           Expect = 'Few or no errors; nothing about disks or SQL.' }
        @{ Id = 'b-ro-updates'; Name = 'Last updates'; Group = 'Updates'; Title = 'The ten most recent installed updates'
           Steps = @('Paste the command in PowerShell on the host.')
           Commands = @('Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 10 HotFixID, Description, InstalledOn | Format-Table -AutoSize')
           Expect = 'Updates from the last months: a host without updates for a year needs extra care.' }
        @{ Id = 'b-ro-temp'; Name = 'Staging folder'; Group = 'Staging'; Title = 'What is already in C:\Temp (staged files)'
           Steps = @('Paste the command in PowerShell on the host.', 'Staged installers must be complete (compare sizes with the media repository).')
           Commands = @('if (Test-Path ''C:\Temp'') { Get-ChildItem ''C:\Temp'' | Select-Object Name, @{n=''MB'';e={[math]::Round($_.Length/1MB,1)}}, LastWriteTime | Format-Table -AutoSize } else { ''C:\Temp does not exist yet'' }')
           Expect = 'The folder exists; staged files have their full size.' }
    )
    foreach ($a in $ro) {
        $actions.Add([pscustomobject]@{
            Id = $a.Id; Name = $a.Name; Title = $a.Title; Category = 'ReadOnly'; Group = $a.Group; Mode = 'Guided'; Builtin = $null
            BuiltinItem = $true; RunOnHost = $true; Steps = @($a.Steps); Commands = @($a.Commands); Expect = $a.Expect; Created = $t0; Updated = $t0
        })
    }
    $workflows = @(
        [pscustomobject]@{ Id = 'wf-default'; Name = 'Full maintenance'; BuiltinItem = $true; Created = $t0; Updated = $t0
            Description = 'The ten maintenance steps: checks, four snapshot points, staging, disk, upgrade, verify, manual check.'
            Steps = @(Get-VmmWorkflowDefinition | ForEach-Object { "b-step-$($_.Name.ToLower())" }) }
        [pscustomobject]@{ Id = 'wf-readonly'; Name = 'Read-only snapshot'; BuiltinItem = $true; Created = $t0; Updated = $t0
            Description = 'Non-invasive checks only. Every step can be pasted or run on the host over RDP (host runbook).'
            Steps = @('b-ro-os', 'b-ro-disk', 'b-ro-reboot', 'b-ro-roles', 'b-ro-sql', 'b-ro-services', 'b-ro-events', 'b-ro-updates', 'b-ro-temp') }
    )
    $kb = @(
        [pscustomobject]@{ Id = 'b-kb-policy'; ActionId = '*'; BuiltinItem = $true; Helped = 0; NotHelped = 0; Created = $t0; Updated = $t0
            Symptom = 'running scripts is disabled on this system (execution policy)'
            Cause = 'The host execution policy blocks .ps1 files that you double-click or run.'
            Fix = @('Run the .cmd file next to the .ps1 (it starts PowerShell with -ExecutionPolicy Bypass for this one run).', 'Or in PowerShell: powershell -NoProfile -ExecutionPolicy Bypass -File <path to the .ps1>')
            Commands = @() }
        [pscustomobject]@{ Id = 'b-kb-admin'; ActionId = '*'; BuiltinItem = $true; Helped = 0; NotHelped = 0; Created = $t0; Updated = $t0
            Symptom = 'access is denied / requested operation requires elevation'
            Cause = 'PowerShell is not running as Administrator.'
            Fix = @('Close the window. Right-click Windows PowerShell > Run as administrator, then paste the command again.')
            Commands = @() }
        [pscustomobject]@{ Id = 'b-kb-space'; ActionId = 'b-step-stage'; BuiltinItem = $true; Helped = 0; NotHelped = 0; Created = $t0; Updated = $t0
            Symptom = 'not enough space on the disk while staging to C:\Temp'
            Cause = 'C: is too full for the installation files.'
            Fix = @('Check the free space (Disk space action).', 'Remove old files from C:\Temp that are not part of this staging.', 'If still short: the ExpandDisk step grows C: after hours (Azure), or ask the platform owner for more space.')
            Commands = @('Get-WmiObject Win32_LogicalDisk -Filter "DeviceID=''C:''" | Select-Object @{n=''FreeGB'';e={[math]::Round($_.FreeSpace/1GB,1)}}') }
    )
    [pscustomobject]@{ Actions = $actions.ToArray(); Workflows = $workflows; Kb = $kb }
}
