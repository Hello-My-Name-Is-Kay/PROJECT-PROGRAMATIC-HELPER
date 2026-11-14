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
        Ports         = @(135, 445, 3389, 5985)     # RPC, SMB, RDP, WinRM
        SoftwareWatch = @('Microsoft SQL Server*')  # installed software to report (wildcards)
    }

    Staging = @{
        SourceShare  = '<\\fileserver\share\folder>'   # where install files are copied FROM
        TargetFolder = 'C:\Temp'                          # created on each host if missing
        Packages     = @(
            @{ Name = '<package-name>'; Path = '<relative\path\file.iso>'; Sha256 = ''; Source = '<download url or team>'; AppliesTo = '*' }
        )
    }

    Workflow = @{
        SnapshotAfter           = 'ChangingSteps'   # ChangingSteps | EveryStep | Off  (Azure VMs only)
        CheckpointRetentionDays = 7                 # RetentionDays tag on checkpoint snapshots (prune uses it)
    }

    Upgrade = @{
        Mode        = 'Guided'   # Guided = you run it in RDP/RDM | RunCommand = Azure only, launched remotely
        CommandLine = ''         # e.g. C:\Temp\<media>\setup.exe /auto upgrade /quiet /eula accept
        ExpectedOs  = ''         # Verify passes only if the OS caption matches, e.g. '*Server 2019*'
    }

    Reports = @{
        ManagerName = ''         # optional greeting name in blocker reports
    }

    UI = @{
        Mouse = $true            # mouse clicks/wheel in the console UI (Windows Terminal / conhost)
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
