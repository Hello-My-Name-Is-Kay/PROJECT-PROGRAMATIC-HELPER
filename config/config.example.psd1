# VmMaintenance local settings - TEMPLATE. Copy with Initialize-VmmConfig (goes to
# %APPDATA%\VmMaintenance\config.psd1) or to config\config.local.psd1 (gitignored).
# Never commit the filled-in copy. Values in <angle brackets> are placeholders and are
# rejected at run time until replaced. %VARIABLES% in paths are expanded.
@{
    Azure = @{
        TenantId        = '<tenant-guid>'
        Subscription    = '<subscription-guid-or-name>'   # default subscription (avoids the picker)
        ResourceGroup   = '<resource-group>'              # snapshot cleanup, restore, upgrade media
        SubscriptionIds = @()                             # Get-VmmAzureVmDisk: limit the search; empty = all enabled
        DisableLoginPicker      = $true    # turn off the Az 'Select a tenant and subscription' prompt (this process only)
        UseDeviceAuthentication = $false   # $true = device code (microsoft.com/devicelogin) instead of a browser pop-up
    }

    Paths = @{
        WorkDir   = 'C:\Temp\VmMaintenance'               # CSV results of the classic scripts, transcripts, tag backups
        DataDir   = '%LOCALAPPDATA%\VmMaintenance\data'      # encrypted fleet store + DPAPI-protected key
        ReportDir = '%LOCALAPPDATA%\VmMaintenance\Reports'   # daily CSV/HTML/JSON and blocker reports (plaintext)
    }

    # One name per line, '#' for comments. Keep these files outside the repository.
    ServerLists = @{
        Fleet        = '%APPDATA%\VmMaintenance\lists\fleet.txt'          # Import-VmmFleet default (delete after import)
        Platform     = '%APPDATA%\VmMaintenance\lists\platform.txt'       # Get-VmmServerPlatform
        DiskSpace    = '%APPDATA%\VmMaintenance\lists\diskspace.txt'      # Get-VmmLansweeperDiskSpace
        AzureVms     = '%APPDATA%\VmMaintenance\lists\azurevms.txt'       # Get-VmmAzureVmDisk
        OsDiskExpand = '%APPDATA%\VmMaintenance\lists\osdiskexpand.txt'   # Expand-VmmOsDisk (5-11 per batch)
        Snapshot     = '%APPDATA%\VmMaintenance\lists\snapshot.txt'       # New-VmmSnapshot
        UpgradeMedia = '%APPDATA%\VmMaintenance\lists\upgrademedia.txt'   # Mount/Dismount-VmmUpgradeMedia
    }

    Lansweeper = @{
        SqlInstance            = '<sql-host\instance>'
        Database               = 'lansweeperdb'
        CriticalGB             = 32          # below this: under the OS minimum, upgrade likely fails
        OkGB                   = 40          # at or above this: room for setup plus Windows.old
        TrustServerCertificate = $false
    }

    Snapshots = @{
        SkuName          = 'Standard_LRS'
        # Tags put on every snapshot. Add your organisation's mandatory tags here.
        Tags             = @{
            'Project'       = '<project-tag>'
            'RetentionDays' = '5'
        }
        # Remove-VmmExpiredSnapshot only touches snapshots with this tag (and a RetentionDays tag)
        CleanupTagName   = 'Project'
        CleanupTagValue  = '<project-tag>'
    }

    OsDiskExpand = @{
        TierSizes        = @(4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096)   # managed disk tiers (GiB)
        MaxCurrentGB     = 128       # safety guard: skip any OS disk larger than this
        AgentWaitMinutes = 10        # how long to wait for the VM agent after start
    }

    UpgradeMedia = @{
        Publisher  = 'MicrosoftWindowsServer'
        Offer      = 'WindowsServerUpgrade'
        Sku        = 'server2019Upgrade'
        DiskSuffix = 'Upgrade2019'   # disk name = <VM>-<DiskSuffix>
        Lun        = 10
        SkuName    = 'Standard_LRS'
    }

    # ---- Fleet console (vmm) ----------------------------------------------------------------
    Schedule = @{
        TimeZoneId                   = 'GMT Standard Time'   # Windows id for Europe/Lisbon (WET/WEST)
        BusinessDays                 = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
        BusinessStart                = '08:00'               # in business hours: checks + staging only
        BusinessEnd                  = '17:00'
        AllowChangesOffHoursWeekdays = $true                 # weekday evenings count as maintenance window
        Holidays                     = @()                   # 'yyyy-MM-dd' days treated like weekends
    }

    Target = @{
        MachinesPerDay = 10                     # daily minimum; more is better, never at the cost of checks
        WorkdayHours   = 9
        CountedSteps   = @('Stage', 'Verify')   # a host counts for the day when one of these succeeds
    }

    Credentials = @{
        WindowsMode = 'Prompt'   # Prompt = ask every session (default) | CurrentUser = use your logged-on identity
    }

    Fleet = @{
        Throttle      = 16                          # hosts checked in parallel
        TimeoutMs     = 1500                        # ping / TCP connect timeout
        Ports         = @(135, 445, 3389, 5985)     # RPC, SMB, RDP, WinRM (route ports are always probed too)
        # Terminal routes tried in this order; the first that answers reads the host. All read-only.
        #   DCOM = WMI over RPC (TCP 135 + dynamic ports), WinRM = TCP 5985, WinRM-SSL = TCP 5986
        # Hands-on (the Extractor in RDP/RDM) is proposed only for hosts where every route fails.
        Routes        = @('DCOM', 'WinRM', 'WinRM-SSL')
        AccessMaxAgeHours = 24                      # older access results count as "not tried": try the terminal again
        WindowsLicence = $true                      # read the Windows licence state ($false = skip: the query wakes the Software Protection service on the host for a moment)
        SoftwareWatch = @('Microsoft SQL Server*')  # installed software to report (wildcards)
    }

    Staging = @{
        # Media repository: where you download and keep everything the hosts need.
        #   <share>\Win_Server_2019_EN_US.iso, Win_Server_2019_FR_FR.iso ...  OS images at the root
        #   <share>\<HOST>\SQLServer2016SP3-KB5003279-x64-FRA.exe ...       files for that host only
        #   <file>.sha256 (optional, next to any file)                       SHA256 to verify against
        # Each host gets: the image for OsMediaVersion in its install language + everything in its folder.
        SourceShare    = '<\\fileserver\share\project\iso-repository>'   # media repository root
        TargetFolder   = 'C:\Temp'                          # created on each host if missing
        Layout         = 'Repository'                       # Repository (above) | Packages (only the list below)
        OsMediaVersion = '2019'                             # image version staged for the upgrade
        OsMediaPattern = '^Win_Server_(?<Version>\d{4}(R2)?)_(?<Lang>[A-Za-z]{2,3}[_-][A-Za-z]{2,4})\.iso$'
        HostFolders    = @{ }                               # optional: fleet name -> folder name when they differ
        Packages       = @(                                 # optional extra files for every host (path relative to SourceShare)
            # @{ Name = 'Tool'; Path = 'Common\tool.msi'; Sha256 = ''; Source = '<download url or team>'; AppliesTo = '*Server 2016*' }
        )
    }

    Handoff = @{
        # Hands-on fallback when the terminal cannot copy files to a host (vmm handoff, T on a host, offered by Stage).
        # vmm opens the client, puts a copy-and-check script on the clipboard and verifies size + SHA256 on the host.
        # No user name or password is ever passed to the client or saved: you sign in each time.
        Offer          = 'Ask'     # Ask = offer it when the Stage copy fails | Always = go straight to it | Never
        Client         = 'Ask'     # Ask | Rdp (mstsc) | Rdm (Devolutions Remote Desktop Manager) | RdcMan (Sysinternals) | None
        Outbox         = 'Ask'     # Ask | Always | Never: copy the files to this laptop first, share that drive with RDP (\\tsclient)
        OutboxFolder   = ''        # '' = %LOCALAPPDATA%\VmMaintenance\outbox (vmm maint -Action CleanTemp empties it after a day)
        RdmPath        = ''        # '' = search (App Paths, Program Files\Devolutions, PATH)
        RdmTemplate    = 'RDP'     # RDM /Template: for the quick connect (RDP, or the id of your own RDP template)
        RdmDataSource  = ''        # optional RDM /DataSource: id
        RdcManPath     = ''        # '' = search (PATH, Program Files\Sysinternals)
        AcceptSizeOnly = $false    # $false = when a SHA256 is known it must be read on the host (report, WinRM or share)
        ShareHashMaxMB = 256       # verify over the admin share: hash files up to this size (bigger = over the network, slow)
    }

    Collect = @{
        # Extractor result files (VMM_<HOST>_<time>.vmm) you copy back from the hosts are picked up here.
        InboxFolders = @('Desktop', 'Downloads')   # Desktop | Downloads | any folder path
        AutoImport   = $true                       # import them when vmm starts (also: E in the menu, vmm inbox)
    }

    Agents = @{
        # Health of the agent columns (Qualys, CrowdStrike, Zabbix, Ivanti, Lansweeper): vmm agents, A on a host.
        LogMaxAgeHours = 48         # an agent log not written for this long = WARN
        AffectHealth   = $true      # a FAIL agent makes the host health Warn
        MinVersion     = @{         # lowest accepted version per agent ('' = any); lower = WARN
            Qualys = ''; CrowdStrike = ''; Zabbix = ''; Ivanti = ''; LansweeperAgent = ''
        }
    }

    Downloads = @{
        # SQL Server updates fetched by 'vmm fetch' are downloaded once into this folder, then copied into
        # each host's folder. Empty = <Staging.SourceShare>\_Downloads (folders starting with _ are not host folders).
        CacheFolder = ''
    }

    SqlUpdates = @{
        MaxBehind = ''              # '' = latest SP/CU | e.g. '1CU' = one CU behind latest is fine (dbatools Test-DbaBuild)
    }

    Log = @{
        # Everything vmm does goes to one file per day in the logs folder (read it with: vmm log, L in the menu, F3 anywhere).
        Live             = $true    # live log pane at the bottom of every screen + progress lines; F2 toggles it on any screen
        PaneLines        = 6        # rows of the pane (2-20)
        HeartbeatSeconds = 5        # long operations say what they are waiting on this often
        ToFile           = $true
        Encrypt          = $true    # lines encrypted with the store key (host names and IPs are in them)
        KeepDays         = 30
    }

    Maintenance = @{
        AutoBackup  = $true         # one encrypted copy of the fleet store per day, made when vmm starts
        KeepBackups = 14
    }

    Inventory = @{
        # 24-column server inventory (column list, order and help texts: VmMaintenance\Resources\InventoryFields.psd1).
        # Values typed here apply to every host that has no value of its own (empty = ask per host).
        Defaults = @{
            AssignedTechnician = ''
            Company            = ''
            Perimeter          = ''
            Phase              = ''
        }
        CsvDelimiter    = ','       # ',' or ';' (Excel with Portuguese/French regional settings)
        ExportWithDaily = $true     # write Reports\Inventory\Inventory_<date>.csv with every daily report
    }

    Workflow = @{
        # Four Azure snapshot points per host (every disk): SnapStart, SnapPreSql, SnapPostSql, SnapFinal (docs\WORKFLOW.md)
        StartSnapshotMaxAgeMinutes = 60   # SnapStart/SnapPreSql are skipped when every disk has a snapshot this recent (portal ones count)
        SnapshotRetentionDays      = 7    # RetentionDays tag on snapshot-point snapshots (prune uses it)
    }

    Upgrade = @{
        Mode        = 'Guided'   # Guided = you run it in RDP/RDM | RunCommand = Azure only, launched remotely
        CommandLine = ''         # e.g. <ISO drive>:\setup.exe /auto upgrade /quiet /eula accept  (mount the staged ISO first; the RDP guide shows how)
        ExpectedOs  = '*Server 2019*'   # Verify passes only if the OS caption matches
    }

    Reports = @{
        ManagerName = ''         # optional greeting name in blocker reports
    }

    UI = @{
        Mouse = $true            # mouse clicks/wheel in the console UI (Windows Terminal / conhost)
        # Theme: deep iceberg blue (blue-black background, deep iceberg bars and selected row); green / orange / red
        # only for statuses. 'Auto' uses 24-bit colour when the console takes it, else the 16 console colours.
        TrueColor = 'Auto'       # 'Auto' | $true | $false ($false = always the 16 console colours)
        DeepBackground = $true   # blue-black console background while the UI runs ($false = black)
    }

    # Fleet OS policy
    Policy = @{
        TargetOs           = '*Server 2019*'                    # goal for every machine
        NewerOs            = @('*Server 2022*', '*Server 2025*') # never downgraded
        ClientOs           = @('*Windows 10*', '*Windows 11*', '*Windows 8*', '*Windows 7*')   # not touched without orders (vmm order)
        WarnOs             = @('*Server 2008*')                 # warn management...
        WarnOsExcept       = @('*2008 R2*')                     # ...but 2008 R2 is fine
        WarnPhysical       = $true                              # warn management about physical machines
        ExpandDiskOverride = $false                             # disk expand deallocates the VM: no business-hours override
        SnapStartInBusinessHours = $true                        # start snapshot (Azure, no downtime, guest untouched) allowed 08-17
    }

    # GitHub integration (GitHub CLI 'gh' and its own sign-in; vmm stores no token)
    GitHub = @{
        Repo         = ''        # owner/name of the repository for issues (public repo = public issues); empty = integration off
        Branch       = 'main'    # branch 'vmm update' installs from
        SourcePath   = ''        # local git clone (vmm clone) used by update and pull requests
        CheckOnStart = $true     # one quick call at start: shows 'Update available' in the menu
    }

    Extractor = @{
        # The .ps1 run by hand on a host the terminal cannot read. Default: SNAPSHOT ONLY - it reads the host and
        # writes one encrypted result file on the host desktop; the steps code is cut out of the file.
        AllowSteps = $false      # $true = a per-host extractor (X on a host) also carries the workflow steps
    }

    # Feature flags: turn whole areas on or off without touching code
    Features = @{
        HostAgent = $true        # X on a host: export the agent .ps1 that runs on the remote host
        Vpn       = $true        # VPN checks before host work (needs Vpn.Provider)
        Ai        = $false       # optional AI assistant - read docs\AI.md first
    }

    # VPN: the tool checks/starts it; you always sign in inside the VPN client itself
    Vpn = @{
        Provider          = 'None'   # None | CiscoSecureClient | Windows | Probe
        Profile           = ''       # Cisco: VPN address/profile as in the client | Windows: VPN connection name
        ClientPath        = ''       # optional: vpncli.exe path (Cisco) or the VPN app to start (Probe)
        ProbeHost         = ''       # internal host only reachable over the VPN (status check)
        ProbePort         = 445
        RequireForHostWork = $true   # stop fleet checks/staging with a clear error when the VPN is down
    }

    # Optional AI assistant (advisory only; cannot run commands). See docs\AI.md.
    Ai = @{
        Provider        = 'None'                       # None | Local | AzureOpenAI
        Endpoint        = ''                           # Local: http://localhost:5273/v1 (Foundry Local) | http://localhost:11434/v1 (Ollama)
                                                       # AzureOpenAI: https://<resource>.openai.azure.com (Entra ID sign-in, no key)
        Model           = 'phi-4-mini'                 # Local model name
        Deployment      = ''                           # AzureOpenAI deployment name
        ApiVersion      = '2024-10-21'
        SendHostNames   = $false                       # $false = host names replaced by HOST01.. before sending
        ConfirmEachSend = $true                        # show the exact text and ask before every send
        TimeoutSeconds  = 120
    }
}
