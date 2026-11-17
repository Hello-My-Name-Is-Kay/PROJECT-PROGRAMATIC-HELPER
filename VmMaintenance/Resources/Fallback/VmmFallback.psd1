# VmmFallback companion file: settings, OS and SQL support data, steps and advice for VmmFallback.ps1.
# Keep it next to the script. Data only: PowerShell reads it as a restricted data file (no code runs).
# Check it after an edit:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VmmFallback.ps1 -Check
# ASCII only. Never put host names, IP addresses, IDs, user names or passwords in this file.
#
# Placeholders in Advice/Manual lines, filled in by the script for the host it runs on:
#   {WorkDir} {MediaDir} {TargetOs} {Os} {NextOs} {Instance} {SqlMedia} {OsMedia} {MinFreeGB} {FreeGB}
@{
    SchemaVersion = 1

    Settings = @{
        TargetOs              = 'Windows Server 2019'
        TargetOsMatch         = '*Server 2019*'
        # Business hours: only reads and staging into C:\Temp. Changes are allowed outside them.
        TimeZoneId            = 'GMT Standard Time'      # Windows id for Europe/Lisbon
        BusinessDays          = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
        BusinessStart         = '08:00'
        BusinessEnd           = '17:00'
        Holidays              = @()                      # 'yyyy-MM-dd' dates treated as business days off (changes allowed)
        # Work folder: result files, log, lock, staged media. Must be under C:\Temp (project rule).
        WorkDir               = 'C:\Temp\VmmFallback'
        # Local media only, nothing is downloaded. Sub folders: Windows (*.msu, *.cab), Sql (SP/CU *.exe),
        # SqlUpgrade\<version>\setup.exe, Os (extracted ISO with setup.exe), or a mounted ISO drive.
        MediaDir              = 'C:\Temp\VmmFallback\Media'
        MinFreeGBPatch        = 5
        MinFreeGBSql          = 6
        MinFreeGBOsUpgrade    = 32
        SqlBackupMaxAgeHours  = 26                       # a full backup older than this blocks SQL changes
        EventLogHours         = 72                       # window for the error count in System/Application
        DiskTiersGB           = @(64, 128, 256, 512, 1024)
    }

    # First match wins (keep the R2 lines above the plain ones).
    # State: Upgrade = has a next hop, Target = goal reached, Newer = never downgraded, Unsupported = no in-place path.
    # Source: learn.microsoft.com/windows-server/get-started/install-upgrade-migrate (checked 2026-11-16).
    OsPath = @(
        @{ Match = '*Server 2025*';    Name = 'Windows Server 2025';    State = 'Newer';       Next = '';                      NextBuild = '';      Note = 'Newer than the target: never downgraded. Patch only.' }
        @{ Match = '*Server 2022*';    Name = 'Windows Server 2022';    State = 'Newer';       Next = '';                      NextBuild = '';      Note = 'Newer than the target: never downgraded. Patch only.' }
        @{ Match = '*Server 2019*';    Name = 'Windows Server 2019';    State = 'Target';      Next = '';                      NextBuild = '';      Note = 'Target reached. Keep it patched.' }
        @{ Match = '*Server 2016*';    Name = 'Windows Server 2016';    State = 'Upgrade';     Next = 'Windows Server 2019';   NextBuild = '17763'; Note = 'One hop: 2016 to 2019.' }
        @{ Match = '*Server 2012 R2*'; Name = 'Windows Server 2012 R2'; State = 'Upgrade';     Next = 'Windows Server 2019';   NextBuild = '17763'; Note = 'One hop: 2012 R2 to 2019 (supported directly).' }
        @{ Match = '*Server 2012*';    Name = 'Windows Server 2012';    State = 'Upgrade';     Next = 'Windows Server 2016';   NextBuild = '14393'; Note = 'Two hops: 2012 to 2016, then 2016 to 2019 (2012 cannot go straight to 2019).' }
        @{ Match = '*Server 2008 R2*'; Name = 'Windows Server 2008 R2'; State = 'Upgrade';     Next = 'Windows Server 2012 R2'; NextBuild = '9600'; Note = 'Two hops: 2008 R2 SP1 to 2012 R2, then 2012 R2 to 2019.' }
        @{ Match = '*Server 2008*';    Name = 'Windows Server 2008';    State = 'Upgrade';     Next = 'Windows Server 2012';   NextBuild = '9200';  Note = 'Three hops (2012, 2016, 2019), only from 2008 SP2 x64. Warn management first; a rebuild is usually safer.' }
        @{ Match = '*Server 2003*';    Name = 'Windows Server 2003';    State = 'Unsupported'; Next = '';                      NextBuild = '';      Note = 'No in-place path. Migrate to a new 2019 server.' }
    )

    # SQL Server major version -> name, and the lowest level supported on the target OS ('' = not supported there).
    # Source: learn.microsoft.com/troubleshoot/sql/.../use-sql-server-in-windows (checked 2026-11-16, Windows Server 2019 column).
    SqlVersions = @(
        @{ Major = 16; Name = 'SQL Server 2022';    OnTarget = 'RTM'; Note = '' }
        @{ Major = 15; Name = 'SQL Server 2019';    OnTarget = 'RTM'; Note = '' }
        @{ Major = 14; Name = 'SQL Server 2017';    OnTarget = 'RTM'; Note = '' }
        @{ Major = 13; Name = 'SQL Server 2016';    OnTarget = 'SP3'; Note = '' }
        @{ Major = 12; Name = 'SQL Server 2014';    OnTarget = 'SP3'; Note = '' }
        @{ Major = 11; Name = 'SQL Server 2012';    OnTarget = 'SP4'; Note = 'Out of extended support.' }
        @{ Major = 10.5; Name = 'SQL Server 2008 R2'; OnTarget = '';  Note = 'Not supported on Windows Server 2019: upgrade SQL before the OS.' }
        @{ Major = 10; Name = 'SQL Server 2008';    OnTarget = '';    Note = 'Not supported on Windows Server 2019: upgrade SQL before the OS.' }
        @{ Major = 9;  Name = 'SQL Server 2005';    OnTarget = '';    Note = 'Not supported on Windows Server 2019; no direct upgrade to 2016+. Migrate.' }
    )

    # In-place SQL version upgrades: from a major version at a minimum level, to these versions.
    # Verify against Microsoft's "supported version and edition upgrades" page for the target version before running.
    SqlUpgrade = @(
        @{ FromMajor = 10;   MinLevel = 'SP4'; To = @('SQL Server 2016', 'SQL Server 2017'); Note = 'SQL 2008 SP4 can go to 2016/2017 only.' }
        @{ FromMajor = 10.5; MinLevel = 'SP3'; To = @('SQL Server 2016', 'SQL Server 2017'); Note = 'SQL 2008 R2 SP3 can go to 2016/2017 only.' }
        @{ FromMajor = 11;   MinLevel = 'SP4'; To = @('SQL Server 2016', 'SQL Server 2017', 'SQL Server 2019', 'SQL Server 2022'); Note = '' }
        @{ FromMajor = 12;   MinLevel = 'SP2'; To = @('SQL Server 2016', 'SQL Server 2017', 'SQL Server 2019', 'SQL Server 2022'); Note = '' }
        @{ FromMajor = 13;   MinLevel = 'SP1'; To = @('SQL Server 2017', 'SQL Server 2019', 'SQL Server 2022'); Note = '' }
        @{ FromMajor = 14;   MinLevel = 'RTM'; To = @('SQL Server 2019', 'SQL Server 2022'); Note = '' }
        @{ FromMajor = 15;   MinLevel = 'RTM'; To = @('SQL Server 2022'); Note = '' }
    )

    # Security/monitoring agents: service Name or DisplayName wildcards (same as the Extractor's defaults).
    Agents = @{
        Qualys          = @('QualysAgent', 'Qualys*')
        CrowdStrike     = @('CSFalconService', 'CrowdStrike*')
        Zabbix          = @('Zabbix Agent*', 'Zabbix*')
        Ivanti          = @('*Ivanti*', '*LANDesk*')
        LansweeperAgent = @('LansweeperAgentService', 'Lansweeper*Agent*')
    }

    # Guide steps, in menu order. Id must be one the script knows; Title, Advice and Manual are yours to edit.
    # Advice = shown before the step. Manual = the guidance-only path (no automation): what a person does by hand.
    Steps = @(
        @{
            Id = 'Snapshot'; Title = 'Read this host (read-only)'
            Advice = @(
                'Reads OS, disks, patches, roles, SQL instances (64-bit and 32-bit), software, agents and recent errors.'
                'Writes one result file in {WorkDir}. Nothing else on the host changes. Safe at any time.'
                'The result is NOT encrypted: keep it on this host or carry it only to the vmm laptop.'
            )
            Manual = @(
                'winver                                  (OS name and build)'
                'Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" | Select DeviceID,Size,FreeSpace'
                'Get-HotFix | Sort InstalledOn | Select -Last 10'
                'Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"'
                'Get-ItemProperty "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server\Instance Names\SQL"'
            )
        }
        @{
            Id = 'Precheck'; Title = 'Pre-checks before any change'
            Advice = @(
                'Checks free space, pending reboot, Windows Update service, SQL full backup age, cluster and domain controller roles.'
                'On Azure: take a snapshot of the OS disk (and data disks with SQL) in the portal BEFORE any change.'
                'Physical machine: there is no snapshot; make sure a full backup exists and warn management.'
            )
            Manual = @(
                'Reboot first if a reboot is pending, then run the snapshot again.'
                'Azure portal > the VM > Disks > OS disk > Create snapshot (name it with today''s date).'
                'SQL: run a full backup of every user database and check msdb.dbo.backupset for the date.'
            )
        }
        @{
            Id = 'WindowsPatch'; Title = 'Windows patches (security and cumulative updates)'
            Advice = @(
                'Offline: installs *.msu (wusa) and *.cab (DISM) found in {MediaDir}\Windows, in name order (prefix 01-, 02- to set it).'
                'Local media only: nothing is downloaded, not even from Windows Update or WSUS.'
                'Install the servicing stack update first when the cumulative update needs it.'
                'Changes only after hours, after you confirm the rollback snapshot/backup. A reboot is usually needed: the script never reboots by itself.'
            )
            Manual = @(
                'Copy the .msu files to {MediaDir}\Windows.'
                'wusa.exe "{MediaDir}\Windows\<file>.msu" /quiet /norestart     (exit 0 ok, 3010 reboot needed, 2359302 already installed)'
                'dism.exe /online /add-package /packagepath:"{MediaDir}\Windows\<file>.cab" /quiet /norestart'
                'Reboot in the maintenance window, then run the snapshot again.'
            )
        }
        @{
            Id = 'SqlPatch'; Title = 'SQL Server patches (service pack / cumulative update)'
            Advice = @(
                'Patches one instance at a time from the SP/CU installers in {MediaDir}\Sql that match its version.'
                'Needs a fresh full backup of every database. Clustered or Always On instances get guidance only.'
                'The instance restarts during the patch: changes only after hours.'
            )
            Manual = @(
                'Check the version: SELECT @@VERSION, SERVERPROPERTY(''ProductLevel''), SERVERPROPERTY(''ProductUpdateLevel'')'
                '"{SqlMedia}" /quiet /IAcceptSQLServerLicenseTerms /Action=Patch /InstanceName={Instance}'
                'Read the setup log: C:\Program Files\Microsoft SQL Server\<nnn>\Setup Bootstrap\Log\Summary.txt'
                'Always On: patch the secondary replicas first, fail over, then patch the old primary.'
            )
        }
        @{
            Id = 'SqlUpgrade'; Title = 'SQL Server version upgrade'
            Advice = @(
                'Needed when the SQL version is not supported on {TargetOs}: do it BEFORE the OS upgrade.'
                'Uses {MediaDir}\SqlUpgrade\<version>\setup.exe. Check the edition and the product key you are licensed for.'
                'Back up every database and the master/msdb system databases first. Test the application afterwards.'
            )
            Manual = @(
                '"{SqlMedia}" /q /ACTION=Upgrade /INSTANCENAME={Instance} /IACCEPTSQLSERVERLICENSETERMS /UpdateEnabled=False'
                'Add /PID=<product key> unless the media carries the licensed key.'
                'Run the Upgrade Advisor / Data Migration Assistant from another machine first when you can.'
                'After the upgrade: set each database compatibility level only after the application owner agrees.'
            )
        }
        @{
            Id = 'OsUpgrade'; Title = 'Windows Server upgrade towards the target'
            Advice = @(
                'This host: {Os}. Next hop: {NextOs}. Needs {MinFreeGB} GB free on C: (now {FreeGB} GB).'
                'Runs a compatibility scan first, then the upgrade from setup.exe in {OsMedia}. Same edition, keep files and apps.'
                'Azure: snapshot first. Domain controllers, clusters and Exchange get guidance only.'
                'SQL instances must be supported on the next OS before the upgrade (step SqlUpgrade).'
            )
            Manual = @(
                'Mount the ISO (right-click > Mount) or extract it to {MediaDir}\Os.'
                '"{OsMedia}\setup.exe" /auto upgrade /compat scanonly /quiet /dynamicupdate disable    (exit 0xC1900210 = no issues)'
                'dism /Get-WimInfo /WimFile:"{OsMedia}\sources\install.wim"    (pick the index that matches the current edition)'
                '"{OsMedia}\setup.exe" /auto upgrade /imageindex <n> /quiet /dynamicupdate disable /compat ignorewarning'
                'Setup reboots several times. Afterwards: winver, check services and SQL, run the snapshot again.'
            )
        }
        @{
            Id = 'Disk'; Title = 'Disk space (C:)'
            Advice = @(
                'C: has {FreeGB} GB free. Growing the disk is done in Azure, after hours, with the VM deallocated, after a snapshot.'
                'After the Azure resize and a restart, this step can extend C: into the new free space (after hours).'
                'Physical machines and other hypervisors: grow the disk there first, then extend C: here.'
            )
            Manual = @(
                'Azure: snapshot the OS disk, Stop (deallocate) the VM, Disks > OS disk > Size + performance > next size, Start.'
                'Then on the host: diskmgmt.msc > right-click C: > Extend Volume, or:'
                'diskpart  >  select volume C  >  extend'
                'Free space first if it is urgent: cleanmgr /sageset:1 then cleanmgr /sagerun:1, old logs, C:\Windows\SoftwareDistribution\Download.'
            )
        }
        @{
            Id = 'Postcheck'; Title = 'Post-checks and second snapshot'
            Advice = @(
                'Reads the host again and compares it with the first snapshot of this session.'
                'Shows what changed (OS, build, SQL levels, free space) and automatic services that are not running.'
            )
            Manual = @(
                'winver; Get-Service | Where { $_.StartType -eq ''Automatic'' -and $_.Status -ne ''Running'' }'
                'SQL: connect with SSMS or sqlcmd -S .\{Instance} -E -Q "SELECT @@VERSION"'
                'Ask the application owner to test.'
            )
        }
        @{
            Id = 'Finish'; Title = 'Finish and clean up'
            Advice = @(
                'Deletes staged media from {WorkDir}\Media. Result files and the log stay until you remove them.'
                'Copy the result files to the vmm laptop if needed, then remove {WorkDir} completely.'
            )
            Manual = @(
                'Remove-Item -Recurse -Force "{WorkDir}"    (after you copied what you need)'
            )
        }
    )
}
