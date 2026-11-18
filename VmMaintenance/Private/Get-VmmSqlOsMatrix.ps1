function Get-VmmSqlOsMatrix {
    # Reference data for the upgrade path report (Get-VmmUpgradePath). Offline: nothing is downloaded.
    #   Os      Windows Server keys in upgrade order, with build and the next in-place hop toward the target
    #   Sql     per SQL Server major version: name, last service pack (KB + Microsoft file name), and the
    #           minimum servicing level Microsoft supports on each Windows Server (-1 = not supported)
    #   Sources the Microsoft pages the data comes from (shown in the report)
    # SqlMatrix.* settings can add or override rows without a code change (same shape as below).
    # Data as published on the Sources pages (read 2026-11-18). Windows Server 2008 / 2008 R2 are not in
    # Microsoft's current tables: their rows come from the older in-place upgrade guidance and are marked Legacy.
    [CmdletBinding()]
    param()
    $os = [ordered]@{
        # Next = the in-place hop Microsoft supports toward 2019 (2012 R2 -> 2019 and 2016 -> 2019 are direct;
        # 2008 x64 -> 2008 R2 -> 2012 R2 is the older guidance, the same hops the management warning names)
        '2008'   = @{ Name = 'Windows Server 2008';    Build = 6002;  Next = '2008R2'; Legacy = $true }
        '2008R2' = @{ Name = 'Windows Server 2008 R2'; Build = 7601;  Next = '2012R2'; Legacy = $true }
        '2012'   = @{ Name = 'Windows Server 2012';    Build = 9200;  Next = '2016';   Legacy = $false }
        '2012R2' = @{ Name = 'Windows Server 2012 R2'; Build = 9600;  Next = '2019';   Legacy = $false }
        '2016'   = @{ Name = 'Windows Server 2016';    Build = 14393; Next = '2019';   Legacy = $false }
        '2019'   = @{ Name = 'Windows Server 2019';    Build = 17763; Next = '';       Legacy = $false }
        '2022'   = @{ Name = 'Windows Server 2022';    Build = 20348; Next = '';       Legacy = $false }
        '2025'   = @{ Name = 'Windows Server 2025';    Build = 26100; Next = '';       Legacy = $false }
    }
    # MinSp: minimum service pack number on that OS (0 = RTM). Missing OS key = not supported there.
    # SpBuilds: first build (3rd part of the version) of SP1, SP2, ... so the level is known without the build list.
    # LastSp: the final service pack; its file names carry the install language (ENU, FRA, ESN...) and the
    # architecture (x64, x86 for 32-bit instances). SQL 2017 and later have no service packs, only CUs.
    $sql = [ordered]@{
        '9'    = @{ Name = 'SQL Server 2005';    SpBuilds = @(2047, 3042, 4035, 5000); LastSp = $null; MinSp = @{} }
        '10.0' = @{ Name = 'SQL Server 2008';    SpBuilds = @(2531, 4000, 5500, 6000)
                    LastSp = @{ Sp = 4; Kb = 'KB2979596'; File = 'SQLServer2008SP4-KB2979596-{0}-{1}.exe' }
                    MinSp = @{ '2008' = 0; '2008R2' = 1; '2012' = 4; '2012R2' = 4 } }
        '10.50' = @{ Name = 'SQL Server 2008 R2'; SpBuilds = @(2500, 4000, 6000)
                    LastSp = @{ Sp = 3; Kb = 'KB2979597'; File = 'SQLServer2008R2SP3-KB2979597-{0}-{1}.exe' }
                    MinSp = @{ '2008' = 0; '2008R2' = 0; '2012' = 3; '2012R2' = 3 } }
        '11'   = @{ Name = 'SQL Server 2012';    SpBuilds = @(3000, 5058, 6020, 7001)
                    LastSp = @{ Sp = 4; Kb = 'KB4018073'; File = 'SQLServer2012SP4-KB4018073-{0}-{1}.exe' }
                    MinSp = @{ '2008' = 0; '2008R2' = 0; '2012' = 4; '2012R2' = 4; '2016' = 4; '2019' = 4 } }
        '12'   = @{ Name = 'SQL Server 2014';    SpBuilds = @(4100, 5000, 6024)
                    LastSp = @{ Sp = 3; Kb = 'KB4022619'; File = 'SQLServer2014SP3-KB4022619-{0}-{1}.exe' }
                    MinSp = @{ '2008' = 0; '2008R2' = 0; '2012' = 3; '2012R2' = 3; '2016' = 3; '2019' = 3 } }
        '13'   = @{ Name = 'SQL Server 2016';    SpBuilds = @(4001, 5026, 6300)
                    LastSp = @{ Sp = 3; Kb = 'KB5003279'; File = 'SQLServer2016SP3-KB5003279-{0}-{1}.exe' }
                    MinSp = @{ '2012' = 3; '2012R2' = 3; '2016' = 3; '2019' = 3 } }
        '14'   = @{ Name = 'SQL Server 2017';    SpBuilds = @(); LastSp = $null; MinSp = @{ '2012' = 0; '2012R2' = 0; '2016' = 0; '2019' = 0; '2022' = 0; '2025' = 0 } }
        '15'   = @{ Name = 'SQL Server 2019';    SpBuilds = @(); LastSp = $null; MinSp = @{ '2016' = 0; '2019' = 0; '2022' = 0; '2025' = 0 } }
        '16'   = @{ Name = 'SQL Server 2022';    SpBuilds = @(); LastSp = $null; MinSp = @{ '2016' = 0; '2019' = 0; '2022' = 0; '2025' = 0 } }
        '17'   = @{ Name = 'SQL Server 2025';    SpBuilds = @(); LastSp = $null; MinSp = @{ '2019' = 0; '2022' = 0; '2025' = 0 } }
    }
    foreach ($k in @($sql.Keys)) {
        $o = Get-VmmSetting "SqlMatrix.Sql.$($k.Replace('.', '_'))" -Default $null
        if ($o -is [hashtable]) { foreach ($p in $o.Keys) { $sql[$k][$p] = $o[$p] } }
    }
    [pscustomobject]@{
        Os = $os
        Sql = $sql
        Sources = @(
            @{ Name = 'SQL Server versions supported per Windows version (minimum SP)'; Url = 'https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/install/windows/use-sql-server-in-windows' }
            @{ Name = 'Windows Server in-place upgrade paths (language and edition must match)'; Url = 'https://learn.microsoft.com/en-us/windows-server/get-started/install-upgrade-migrate' }
            @{ Name = 'Windows Server in-place upgrade of an Azure VM'; Url = 'https://learn.microsoft.com/en-us/azure/virtual-machines/windows-in-place-upgrade' }
            @{ Name = 'SQL Server update files (search by KB)'; Url = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' }
        )
    }
}
