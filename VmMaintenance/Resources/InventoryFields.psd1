# Server inventory: one entry per column of the inventory export, in column order.
# Edit this file (or open a "Help text" issue on GitHub: T in the inventory screen, or vmm helptext) to change
# a header, the help shown in the help window, or which services count as an installed agent.
#   Key      internal name (letters/digits, never change it once data exists)
#   Header   column header in the CSV export (kept exactly as the team's spreadsheet spells it)
#   Source   Auto    = read from the host (fleet check over WMI, host agent or collector in RDP); asked only if that fails
#            Derived = worked out from vmm data (workflow steps); you can overwrite it
#            Manual  = you enter it (help window explains where to find it); fleet default: Inventory.Defaults
#   Required $false = an empty value does not count as missing
#   Services (agents only) service Name or DisplayName wildcards; first match wins
#   Agent    (agents only) health check details: Products = names in Programs and Features (for the version),
#            Drivers = kernel drivers that must be running, Ports = TCP ports the agent listens on,
#            Log = a file the agent writes while it works (older than Agents.LogMaxAgeHours = WARN).
#            Minimum versions are settings: Agents.MinVersion.<Key>
#   Help     shown in the help window: what the field means and how to get it by hand
@{
    Version = 1
    Fields  = @(
        @{ Key = 'Hostname'; Header = 'Hostname'; Source = 'Auto'; Required = $true
           Help = 'Computer name as in the fleet. By hand on the host: hostname' }
        @{ Key = 'Domain'; Header = 'Domain'; Source = 'Auto'; Required = $true
           Help = 'Active Directory domain the server is joined to (WORKGROUP if none). By hand on the host: (Get-WmiObject Win32_ComputerSystem).Domain   or System Properties > Computer name.' }
        @{ Key = 'IPAddress'; Header = 'IPAddress'; Source = 'Auto'; Required = $true
           Help = 'Main IPv4 address. Read from DNS by the fleet check, or from the network adapters by the host agent. By hand on the host: ipconfig (IPv4 Address of the main adapter).' }
        @{ Key = 'OSVersion'; Header = 'OS Version'; Source = 'Auto'; Required = $true
           Help = 'Windows edition and build, e.g. Microsoft Windows Server 2016 Standard (build 14393). By hand on the host: winver   or (Get-WmiObject Win32_OperatingSystem).Caption' }
        @{ Key = 'Company'; Header = 'Company'; Source = 'Manual'; Required = $true
           Help = 'Company (legal entity) the server belongs to. Where to find it: the server request or CMDB record, the Lansweeper asset page (Company / Department field), or ask the server owner. Same for many hosts? Set Inventory.Defaults.Company once.' }
        @{ Key = 'Perimeter'; Header = 'Perimeter'; Source = 'Manual'; Required = $true
           Help = 'Business or project perimeter the server is part of (the scope list you received with the server). Ask your manager if the list does not say.' }
        @{ Key = 'Localisation'; Header = 'Localisation'; Source = 'Manual'; Required = $true
           Help = 'Where the server runs: Azure region (Azure portal > the VM > Overview > Location), or the datacenter / site for VMware, Hyper-V and physical machines (vCenter folder, rack label, CMDB).' }
        @{ Key = 'Phase'; Header = 'Phase'; Source = 'Manual'; Required = $true
           Help = 'Project phase or wave this server is planned in (from the planning sheet). Same for a batch? Set Inventory.Defaults.Phase.' }
        @{ Key = 'ServerOwner'; Header = 'Server Owner'; Source = 'Manual'; Required = $true
           Help = 'Person or team responsible for the server and its application (approves downtime). Where to find it: CMDB, Lansweeper asset owner, AD computer object Managed By (dsa.msc > computer > Managed By), or the application team.' }
        @{ Key = 'AssignedTechnician'; Header = 'Assigned Technician'; Source = 'Manual'; Required = $true
           Help = 'Technician doing the maintenance on this server. Usually you: set Inventory.Defaults.AssignedTechnician once (setup wizard, page Inventory).' }
        @{ Key = 'ActionsToExecute'; Header = 'Actions to be executed'; Source = 'Derived'; Required = $true
           Help = 'Filled from the workflow: the steps still to do on this host (for example Stage, PreSnapshot, Upgrade to Windows Server 2019, Verify), or why nothing is needed. Overwrite it only to add actions outside vmm.' }
        @{ Key = 'ExecutionDate'; Header = 'Execution Date'; Source = 'Derived'; Required = $false
           Help = 'Date the upgrade was done (from the Upgrade step), or the planned date if you enter one (yyyy-MM-dd).' }
        @{ Key = 'WindowsLicense'; Header = 'Windows License'; Source = 'Auto'; Required = $true
           Help = 'Windows activation state: Licensed, Grace period, Notification or Unlicensed. By hand on the host (as administrator): slmgr /dli   (License Status line).' }
        @{ Key = 'Qualys'; Header = 'QUALYS Cloud AGENT'; Source = 'Auto'; Required = $true; Services = @('QualysAgent', 'Qualys*')
           Agent = @{ Products = @('Qualys Cloud Security Agent*', 'Qualys*Agent*'); Log = 'C:\ProgramData\Qualys\QualysAgent\Log.txt' }
           Help = 'Qualys Cloud Agent health: OK / WARN / FAIL, service state, version, and why (service stopped, start type not Automatic, log not written recently). By hand on the host: Get-Service *Qualys*   and Programs and Features for the version.' }
        @{ Key = 'CrowdStrike'; Header = 'CrowdStrike Agent'; Source = 'Auto'; Required = $true; Services = @('CSFalconService', 'CrowdStrike*')
           Agent = @{ Products = @('CrowdStrike Windows Sensor*', 'CrowdStrike*Sensor*'); Drivers = @('CSAgent') }
           Help = 'CrowdStrike Falcon sensor health: OK / WARN / FAIL, service CSFalconService, kernel driver CSAgent running, sensor version. By hand on the host: sc.exe query csagent   and   Get-Service CSFalconService   and Programs and Features (CrowdStrike Windows Sensor) for the version.' }
        @{ Key = 'Zabbix'; Header = 'Zabbix'; Source = 'Auto'; Required = $true; Services = @('Zabbix Agent*', 'Zabbix*')
           Agent = @{ Products = @('Zabbix Agent*'); Ports = @(10050) }
           Help = 'Zabbix Agent / Agent 2 health: OK / WARN / FAIL, service state, version, listening on TCP 10050. By hand on the host: Get-Service *Zabbix*   and   netstat -an | findstr 10050' }
        @{ Key = 'Ivanti'; Header = 'IVANTI'; Source = 'Auto'; Required = $true; Services = @('*Ivanti*', '*LANDesk*')
           Agent = @{ Products = @('*Ivanti*Agent*', '*LANDesk*Agent*') }
           Help = 'Ivanti (formerly LANDesk) agent health: OK / WARN / FAIL, service state, version. By hand on the host: Get-Service | Where-Object { $_.DisplayName -match ''Ivanti|LANDesk'' }   If your Ivanti agent uses other service names, open a help-text issue so they are added here.' }
        @{ Key = 'LansweeperAgent'; Header = 'LANSWEEPER AGENT'; Source = 'Auto'; Required = $true; Services = @('LansweeperAgentService', 'Lansweeper*Agent*')
           Agent = @{ Products = @('LsAgent*', 'Lansweeper*Agent*') }
           Help = 'Lansweeper agent (LsAgent) health: OK / WARN / FAIL, service LansweeperAgentService, version. Agentless scanning does not need it; this column says whether the agent is installed. By hand: Get-Service *Lansweeper*' }
        @{ Key = 'TlsLegacyDisabled'; Header = 'TLS 1.0-1.1 DISABLED'; Source = 'Auto'; Required = $true
           Help = 'Yes when TLS 1.0 and TLS 1.1 are both disabled for the server side in SCHANNEL (Enabled = 0). No lists what is still on. By hand: reg query "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server" /v Enabled   (same for TLS 1.1). A missing key means the Windows default, which is enabled on Server 2019 and older.' }
        @{ Key = 'ActionsStatus'; Header = 'Actions Status'; Source = 'Derived'; Required = $true
           Help = 'Filled from the workflow: Not started, In progress (last step done), Blocked (step), On hold, Done (Verify passed), or Not in scope.' }
        @{ Key = 'DomainController'; Header = 'Domain controller'; Source = 'Auto'; Required = $true
           Help = 'Yes when the server is a domain controller (DomainRole 4 or 5). By hand on the host: (Get-WmiObject Win32_ComputerSystem).DomainRole   (4/5 = DC)   or Server Manager > AD DS role.' }
        @{ Key = 'SqlPresent'; Header = 'SQL Present'; Source = 'Auto'; Required = $true
           Help = 'SQL Server instances found (name, version, edition) or No. By hand on the host: Get-Service MSSQL*   or SQL Server Configuration Manager.' }
        @{ Key = 'Comments'; Header = 'Comments'; Source = 'Manual'; Required = $false
           Help = 'Anything the next person should know: special reboot order, maintenance window agreed with the owner, known issues.' }
        @{ Key = 'Application'; Header = 'Aplication'; Source = 'Manual'; Required = $true
           Help = 'Business application(s) the server runs. Hints: the SQL databases and installed software shown by the check, IIS sites (inetmgr), the server description in AD, or ask the server owner.' }
    )
}
