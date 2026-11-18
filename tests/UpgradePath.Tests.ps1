<#
    Pester 5: SQL/Windows upgrade path report (Get-VmmUpgradePath, Export-VmmUpgradePathReport) from sample
    host results in the Extractor's key=value format, imported as a laptop would (Import-VmmCollectorResult).
    No host, Azure, SQL or network is touched; dbatools is not used (-NoBuildList).
    Run:
        Invoke-Pester -Path .\tests\UpgradePath.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $script:repo = Split-Path -Path $PSScriptRoot -Parent
    $script:mod = Import-Module (Join-Path $script:repo 'VmMaintenance\VmMaintenance.psd1') -Force -PassThru
    $script:root = Join-Path ([IO.Path]::GetTempPath()) ('vmm-path-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'data'), (Join-Path $root 'reports') -Force | Out-Null
    $script:isWin = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
    InModuleScope VmMaintenance -Parameters @{ Root = $script:root; IsWin = $script:isWin } {
        $script:SavedCfg = $script:VmmConfig
        $script:VmmConfig = @{ Log = @{ ToFile = $false }; Paths = @{ DataDir = (Join-Path $Root 'data'); ReportDir = (Join-Path $Root 'reports') } }
        if (-not $IsWin) {
            # Test only: no DPAPI outside Windows
            function script:Protect-VmmDpapi { param([byte[]]$Bytes) return , $Bytes }
            function script:Unprotect-VmmDpapi { param([byte[]]$Bytes, [string]$Source) return , $Bytes }
        }
    }
    # Sample results: one per SQL/Windows combination (the fields the Extractor writes)
    $script:Samples = @(
        @{ Name = 'UP-W2008R2'; OS = 'Microsoft Windows Server 2008 R2 Standard '; Build = '7601'; Lang = 'fr-FR'; Sql = 'MSSQLSERVER 11.2.5058.0 Standard Edition'; SqlLang = 'MSSQLSERVER=1036' }
        @{ Name = 'UP-W2012R2'; OS = 'Microsoft Windows Server 2012 R2 Datacenter'; Build = '9600'; Lang = 'en-US'; Sql = 'MSSQLSERVER 13.1.4001.0 Enterprise Edition'; SqlLang = 'MSSQLSERVER=1033' }
        @{ Name = 'UP-W2019'; OS = 'Microsoft Windows Server 2019 Standard'; Build = '17763'; Lang = 'en-US'; Sql = 'MSSQLSERVER 15.0.4000.5 Standard Edition'; SqlLang = 'MSSQLSERVER=1033' }
        @{ Name = 'UP-W2016-OLDSQL'; OS = 'Microsoft Windows Server 2016 Standard'; Build = '14393'; Lang = 'es-ES'; Sql = 'MSSQLSERVER 10.53.6000.34 Standard Edition'; SqlLang = 'MSSQLSERVER=3082' }
        @{ Name = 'UP-W2008'; OS = ('Microsoft' + [char]0xAE + ' Windows Server' + [char]0xAE + ' 2008 Standard '); Build = '6002'; Lang = 'en-US'; Sql = 'MSSQLSERVER 10.4.6000.29 Standard Edition'; SqlLang = '' }
        @{ Name = 'UP-W10'; OS = 'Microsoft Windows 10 Enterprise'; Build = '19045'; Lang = 'en-US'; Sql = ''; SqlLang = ''; PT = 1 }
        @{ Name = 'UP-PHYS'; OS = 'Microsoft Windows Server 2012 R2 Standard'; Build = '9600'; Lang = 'es-ES'; Sql = 'SALES 12.2.5000.0 Standard Edition'; SqlLang = 'SALES=1033'; Platform = 'Physical' }
        @{ Name = 'UP-X86'; OS = 'Microsoft Windows Server 2012 R2 Standard'; Build = '9600'; Lang = 'fr-FR'; Sql = 'OLD32 12.1.4100.1 Express Edition (32-bit)'; SqlLang = '' }
        @{ Name = 'UP-REBOOT'; OS = 'Microsoft Windows Server 2016 Datacenter'; Build = '14393'; Lang = 'en-US'; Sql = 'MSSQLSERVER 14.0.3456.2 Standard Edition'; SqlLang = 'MSSQLSERVER=1033'; Reboot = 'Yes' }
    )
    & $script:mod { param($n) Import-VmmFleet -Name $n | Out-Null } (@($script:Samples | ForEach-Object { $_.Name }) + 'UP-NOCHECK')
    foreach ($s in $script:Samples) {
        $text = @(
            "Name=$($s.Name)", "OS=$($s.OS)", "Lang=$($s.Lang)", "Version=x", "Build=$($s.Build)", 'SP=0', 'Manufacturer=Microsoft Corporation', 'Model=Virtual Machine',
            "Platform=$(if ($s.Platform) { $s.Platform } else { 'Hyper-V' })", 'CTotalGB=127', 'CFreeGB=40', "PendingReboot=$(if ($s.Reboot) { $s.Reboot } else { 'No' })",
            "Sql=$($s.Sql)", "SqlLang=$($s.SqlLang)", 'LastBoot=2026-11-01T06:00:00Z', "ProductType=$(if ($s.PT) { $s.PT } else { 3 })", 'Mode=Snapshot'
        ) -join "`n"
        $line = 'VMM1|' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
        & $script:mod { param($l) Import-VmmCollectorResult -Line $l } $line
    }
    $script:Paths = @{}
    foreach ($p in (& $script:mod { Get-VmmUpgradePath -NoBuildList -PassThru })) { $script:Paths[$p.Host] = $p }
    function script:Kinds($h) { @($script:Paths[$h].Steps | ForEach-Object Kind) }
}

AfterAll {
    InModuleScope VmMaintenance { Exit-VmmInstanceLock; $script:VmmConfig = $script:SavedCfg }
    Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module VmMaintenance -ErrorAction SilentlyContinue
}

Describe 'SQL level and OS key (offline)' {
    It 'reads the service pack from the build number' {
        InModuleScope VmMaintenance {
            (ConvertTo-VmmSqlLevel '11.2.5058.0').Level | Should -Be 'SP2'
            (ConvertTo-VmmSqlLevel '11.4.7001.0').Name | Should -Be 'SQL Server 2012'
            (ConvertTo-VmmSqlLevel '13.0.6300.2').Level | Should -Be 'SP3'
            (ConvertTo-VmmSqlLevel '13.0.1601.5').Level | Should -Be 'RTM'
            (ConvertTo-VmmSqlLevel '10.53.6000.34').Key | Should -Be '10.50'
            (ConvertTo-VmmSqlLevel '10.53.6000.34').Level | Should -Be 'SP3'
            (ConvertTo-VmmSqlLevel '15.0.4000.5').Level | Should -Be ''
            ConvertTo-VmmSqlLevel 'not a build' | Should -BeNullOrEmpty
        }
    }
    It 'maps captions and builds to OS keys' {
        InModuleScope VmMaintenance {
            ConvertTo-VmmOsKey 'Microsoft Windows Server 2008 R2 Standard' | Should -Be '2008R2'
            ConvertTo-VmmOsKey ('Microsoft' + [char]0xAE + ' Windows Server' + [char]0xAE + ' 2008 Standard') | Should -Be '2008'
            ConvertTo-VmmOsKey 'Microsoft Windows Server Datacenter' -Build '17763' | Should -Be '2019'
            ConvertTo-VmmOsKey 'Microsoft Windows 10 Enterprise' | Should -Be ''
        }
    }
}

Describe 'Extractor sends the SQL install language' {
    It 'imports SqlLang and the SQL language follows it' {
        & $script:mod { (Get-VmmHostRecord -Store (Read-VmmStore) -Name 'UP-W2008R2').Check.SqlLang } | Should -Be 'MSSQLSERVER=1036'
        $script:Paths['UP-W2008R2'].Sql[0].Lang | Should -Be 'FRA'
        $script:Paths['UP-W2008R2'].Sql[0].LangFrom | Should -Be 'SQL setup'
    }
    It 'drops a malformed SqlLang' {
        $text = "Name=UP-W2019`nOS=Microsoft Windows Server 2019 Standard`nLang=en-US`nBuild=17763`nSql=MSSQLSERVER 15.0.4000.5 Standard Edition`nSqlLang=<script>"
        & $script:mod { param($l) Import-VmmCollectorResult -Line $l } ('VMM1|' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)))
        & $script:mod { (Get-VmmHostRecord -Store (Read-VmmStore) -Name 'UP-W2019').Check.SqlLang } | Should -Be ''
    }
}

Describe 'Next step per SQL/Windows combination' {
    It 'SQL 2012 SP2 on 2008 R2 (fr-FR): SQL SP4 in French first, then 2012 R2 and 2019 ISOs in French, then the CU' {
        $p = $script:Paths['UP-W2008R2']
        Kinds 'UP-W2008R2' | Should -Be @('SqlServicePack', 'WindowsUpgrade', 'WindowsUpgrade', 'SqlCumulativeUpdate')
        $p.Steps[0].File | Should -Be 'SQLServer2012SP4-KB4018073-x64-FRA.exe'
        $p.Steps[0].Blocking | Should -BeTrue
        $p.Steps[1].File | Should -Be 'Win_Server_2012R2_FR_FR.iso'
        $p.Steps[1].Note | Should -Match 'older guidance'
        $p.Steps[1].Note | Should -Match 'copy this ISO by hand'
        $p.Steps[2].File | Should -Be 'Win_Server_2019_FR_FR.iso'
        $p.Path | Should -Be '2008 R2 -> 2012 R2 -> 2019'
        $p.NextStep | Should -Match 'SP4'
        $p.Workflow | Should -Match 'next workflow step 2/10 SnapStart'
    }
    It 'SQL 2016 SP1 on 2012 R2: SQL 2016 SP3 (ENU) before the direct hop to 2019' {
        $p = $script:Paths['UP-W2012R2']
        Kinds 'UP-W2012R2' | Should -Be @('SqlServicePack', 'WindowsUpgrade', 'SqlCumulativeUpdate')
        $p.Steps[0].File | Should -Be 'SQLServer2016SP3-KB5003279-x64-ENU.exe'
        $p.Steps[0].Action | Should -Match 'needs SP3 or later \(now SP1\)'
        $p.Steps[1].File | Should -Be 'Win_Server_2019_EN_US.iso'
    }
    It 'SQL 2019 on Server 2019 (target): only the latest CU' {
        Kinds 'UP-W2019' | Should -Be @('SqlCumulativeUpdate')
        $script:Paths['UP-W2019'].Policy | Should -Be 'AtTarget'
        $script:Paths['UP-W2019'].Steps[0].Lang | Should -Be 'neutral'
    }
    It 'SQL 2008 R2 on 2016: blocker, Windows stays (SQL not supported on 2019)' {
        $k = Kinds 'UP-W2016-OLDSQL'
        $k[0] | Should -Be 'Blocker'
        $k | Should -Not -Contain 'SqlServicePack'
        $script:Paths['UP-W2016-OLDSQL'].Steps[0].Action | Should -Match 'SQL Server 2008 R2 is not supported on Windows Server 2019'
        @($script:Paths['UP-W2016-OLDSQL'].Steps | Where-Object Kind -eq 'WindowsUpgrade')[0].Blocking | Should -BeTrue
    }
    It 'Server 2008 (not R2): warn management first; SQL 2008 limits Windows to 2012 R2' {
        $k = Kinds 'UP-W2008'
        $k[0] | Should -Be 'Management'
        $k[1] | Should -Be 'Blocker'
        $script:Paths['UP-W2008'].Steps[1].Action | Should -Match 'Windows can go up to Windows Server 2012 R2\.'
        $script:Paths['UP-W2008'].Sql[0].LangFrom | Should -Be 'OS language'
    }
    It 'Windows 10: not touched' {
        Kinds 'UP-W10' | Should -Be @('None')
    }
    It 'physical with Spanish OS and an English SQL instance: management first, SP in the SQL language, ISO in the OS language' {
        $p = $script:Paths['UP-PHYS']
        Kinds 'UP-PHYS' | Should -Be @('Management', 'SqlServicePack', 'WindowsUpgrade', 'SqlCumulativeUpdate')
        $p.Steps[1].File | Should -Be 'SQLServer2014SP3-KB4022619-x64-ENU.exe'
        $p.Steps[1].Note | Should -Match 'must match the SQL install language \(ENU\)'
        $p.Steps[2].File | Should -Be 'Win_Server_2019_ES_ES.iso'
    }
    It '32-bit SQL 2014 SP1 Express: the x86 service pack in the OS language' {
        $script:Paths['UP-X86'].Steps[0].File | Should -Be 'SQLServer2014SP3-KB4022619-x86-FRA.exe'
        $script:Paths['UP-X86'].Sql[0].Arch | Should -Be 'x86'
    }
    It 'pending reboot: restart before anything else; SQL 2017 has no service pack' {
        Kinds 'UP-REBOOT' | Should -Be @('Restart', 'WindowsUpgrade', 'SqlCumulativeUpdate')
    }
    It 'no snapshot yet: read the host first' {
        $p = & $script:mod { Get-VmmUpgradePath -HostName 'UP-NOCHECK' -NoBuildList -PassThru }
        $p.Steps[0].Kind | Should -Be 'Snapshot'
    }
}

Describe 'Report file for the manager' {
    It 'writes the text and the CSV with every step' {
        $r = & $script:mod { Export-VmmUpgradePathReport -NoBuildList }
        Test-Path -LiteralPath $r.Text | Should -BeTrue
        $t = Get-Content -LiteralPath $r.Text -Raw
        $t | Should -Match 'Subject: Server upgrade programme - next step per server'
        $t | Should -Match 'SQLServer2012SP4-KB4018073-x64-FRA\.exe'
        $t | Should -Match 'learn\.microsoft\.com/en-us/troubleshoot/sql'
        $csv = @(Import-Csv -LiteralPath $r.Csv)
        @($csv | Where-Object { $_.Host -eq 'UP-W2008R2' }).Count | Should -Be 4
        ($csv | Where-Object { $_.Host -eq 'UP-W2012R2' -and $_.Kind -eq 'WindowsUpgrade' }).File | Should -Be 'Win_Server_2019_EN_US.iso'
    }
    It 'prints in the console without errors' {
        { & $script:mod { Get-VmmUpgradePath -HostName 'UP-W2008R2' -NoBuildList 6>$null } } | Should -Not -Throw
    }
}
