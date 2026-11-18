<#
    Pester 5 end-to-end test: the laptop builds the Extractor, the built file runs as on a host (-Extract), and the
    laptop imports the result file into the fleet table and the 24-column inventory.
    No real host is read: the WMI/CIM reads and Get-Service are stand-in functions, one set per Windows version
    (Server 2008 to 2029 and Windows 7 to 11). Registry reads on a Windows runner see the runner's own registry.
    On Linux/macOS (no Windows DPAPI) the two DPAPI functions are replaced by a pass-through INSIDE THIS TEST ONLY,
    so the rest of the path (RSA-OAEP + AES + HMAC, store, inventory) still runs.
    Run:
        Invoke-Pester -Path .\tests\EndToEnd.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $script:repo = Split-Path -Path $PSScriptRoot -Parent
    $script:mod = Import-Module (Join-Path $script:repo 'VmMaintenance\VmMaintenance.psd1') -Force -PassThru
    $script:root = Join-Path ([IO.Path]::GetTempPath()) ('vmm-e2e-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'data'), (Join-Path $root 'reports'), (Join-Path $root 'Desktop') -Force | Out-Null
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
    $script:extractor = (& $script:mod { Export-VmmHostAgent -Generic -NoClipboard -PassThru }).FullName
    $script:exe = (Get-Process -Id $PID).Path

    # One Windows version per host. ProductType: 1 workstation, 3 server. (R) is built at run time: source files stay ASCII.
    $r = [string][char]0xAE
    $script:Profiles = @(
        @{ Name = 'E2E-S2008R2'; Caption = 'Microsoft Windows Server 2008 R2 Standard '; Version = '6.1.7601'; Build = '7601'; PT = 3; Scope = 'InScope' }
        @{ Name = 'E2E-S2008';   Caption = ('Microsoft' + $r + ' Windows Server' + $r + ' 2008 Standard '); Version = '6.0.6002'; Build = '6002'; PT = 3; Scope = 'InScope'; Warn = 'Server 2008 (not R2)' }
        @{ Name = 'E2E-S2012R2'; Caption = 'Microsoft Windows Server 2012 R2 Datacenter'; Version = '6.3.9600'; Build = '9600'; PT = 3; Scope = 'InScope' }
        @{ Name = 'E2E-S2016';   Caption = 'Microsoft Windows Server 2016 Standard'; Version = '10.0.14393'; Build = '14393'; PT = 2; Scope = 'InScope' }
        @{ Name = 'E2E-S2019';   Caption = 'Microsoft Windows Server 2019 Datacenter'; Version = '10.0.17763'; Build = '17763'; PT = 3; Scope = 'AtTarget' }
        @{ Name = 'E2E-S2022';   Caption = 'Microsoft Windows Server 2022 Standard'; Version = '10.0.20348'; Build = '20348'; PT = 3; Scope = 'NewerThanTarget' }
        @{ Name = 'E2E-S2025';   Caption = 'Microsoft Windows Server 2025 Datacenter'; Version = '10.0.26100'; Build = '26100'; PT = 3; Scope = 'NewerThanTarget' }
        @{ Name = 'E2E-S2029';   Caption = 'Microsoft Windows Server 2029 Datacenter'; Version = '10.0.31000'; Build = '31000'; PT = 3; Scope = 'NewerThanTarget' }
        @{ Name = 'E2E-SSAC';    Caption = 'Microsoft Windows Server Datacenter'; Version = '10.0.19042'; Build = '19042'; PT = 3; Scope = 'NewerThanTarget' }
        @{ Name = 'E2E-W7';      Caption = 'Microsoft Windows 7 Professional '; Version = '6.1.7601'; Build = '7601'; PT = 1; Scope = 'ClientOs' }
        @{ Name = 'E2E-W81';     Caption = 'Microsoft Windows 8.1 Pro'; Version = '6.3.9600'; Build = '9600'; PT = 1; Scope = 'ClientOs' }
        @{ Name = 'E2E-W10';     Caption = 'Microsoft Windows 10 Enterprise'; Version = '10.0.19045'; Build = '19045'; PT = 1; Scope = 'ClientOs' }
        @{ Name = 'E2E-W11';     Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.26100'; Build = '26100'; PT = 1; Scope = 'ClientOs' }
    )
    & $script:mod { param($n) Import-VmmFleet -Name $n | Out-Null } @($script:Profiles | ForEach-Object { $_.Name })

    # Stand-ins for the host's WMI reads, written to a file the child PowerShell dot-sources before the Extractor
    $script:mockFile = Join-Path $root 'mocks.ps1'
    $ip = (192, 0, 2, 41) -join '.'   # documentation range, built at run time (leak scan)
    @"
function global:Get-TestRow([string]`$Class) {
    switch (`$Class) {
        'Win32_OperatingSystem' { New-Object PSObject -Property @{ Caption = `$env:E2E_CAPTION; Version = `$env:E2E_VERSION; BuildNumber = `$env:E2E_BUILD; ServicePackMajorVersion = 0; OSLanguage = 1033; LastBootUpTime = [datetime]'2026-11-01T06:00:00'; ProductType = [int]`$env:E2E_PT } }
        'Win32_ComputerSystem' { New-Object PSObject -Property @{ Manufacturer = 'Microsoft Corporation'; Model = 'Virtual Machine'; Domain = 'corp.example.com'; PartOfDomain = `$true; DomainRole = 3; DNSHostName = `$env:E2E_DNS } }
        'Win32_LogicalDisk' { New-Object PSObject -Property @{ Size = 127GB; FreeSpace = 38GB } }
        'Win32_NetworkAdapterConfiguration' { New-Object PSObject -Property @{ IPAddress = @('$ip', 'fe80::1') } }
        'SoftwareLicensingProduct' { New-Object PSObject -Property @{ LicenseStatus = 1 } }
        'Win32_Service' { @(
            (New-Object PSObject -Property @{ Name = 'QualysAgent'; DisplayName = 'Qualys Cloud Agent'; State = 'Running'; StartMode = 'Auto'; PathName = '' }),
            (New-Object PSObject -Property @{ Name = 'CSFalconService'; DisplayName = 'CrowdStrike Falcon Sensor Service'; State = 'Running'; StartMode = 'Auto'; PathName = '' }),
            (New-Object PSObject -Property @{ Name = 'Zabbix Agent'; DisplayName = 'Zabbix Agent'; State = 'Stopped'; StartMode = 'Manual'; PathName = '' })) }
        'Win32_SystemDriver' { New-Object PSObject -Property @{ Name = 'CSAgent'; State = 'Running' } }
        default { `$null }
    }
}
function global:Get-WmiObject { param([string]`$Class, [string]`$Filter, `$ErrorAction) Get-TestRow `$Class }
function global:Get-CimInstance { param([string]`$ClassName, [string]`$Filter, `$ErrorAction) Get-TestRow `$ClassName }
function global:Get-Service { param([string]`$Name, `$ErrorAction) if (`$Name -eq 'WindowsAzureGuestAgent') { New-Object PSObject -Property @{ Name = `$Name } } }
"@ | Set-Content -LiteralPath $script:mockFile -Encoding ASCII

    function script:Invoke-Extractor($P) {
        # Runs the built Extractor as on the host, in a child PowerShell with that host's name and version
        $env:E2E_CAPTION = $P.Caption; $env:E2E_VERSION = $P.Version; $env:E2E_BUILD = $P.Build; $env:E2E_PT = "$($P.PT)"
        $env:E2E_DNS = "$($P.Dns)"   # '' = the host's DNS name is read from .NET (the runner's own name: the laptop ignores it)
        $savedName = $env:COMPUTERNAME; $env:COMPUTERNAME = $P.Name
        $savedProfile = $env:USERPROFILE
        if (-not $script:isWin) { $env:USERPROFILE = $script:root }   # no Desktop folder outside Windows: <root>/Desktop
        try {
            $cmd = ". '$($script:mockFile)'; & '$($script:extractor)' -Extract -NoClipboard -NoColor; exit `$LASTEXITCODE"
            $out = & $script:exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>&1
            [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out | Out-String) }
        } finally { $env:COMPUTERNAME = $savedName; $env:USERPROFILE = $savedProfile }
    }
    function script:Find-Result([string]$Name) {
        foreach ($d in @([Environment]::GetFolderPath('Desktop'), (Join-Path $script:root 'Desktop')) | Select-Object -Unique) {
            if ($d -and (Test-Path -LiteralPath $d)) { Get-ChildItem -LiteralPath $d -Filter ("VMM_$Name" + '_*.vmm') -ErrorAction SilentlyContinue }
        }
    }
}

AfterAll {
    InModuleScope VmMaintenance { Exit-VmmInstanceLock; $script:VmmConfig = $script:SavedCfg }
    Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($p in @($script:Profiles) + @($script:NewProfiles)) { Find-Result $p.Name | Remove-Item -Force -ErrorAction SilentlyContinue }
    Remove-Module VmMaintenance -ErrorAction SilentlyContinue
}

Describe 'Extractor to fleet table, Windows Server 2008 to 2029 and Windows 7 to 11' {
    It 'the built Extractor is snapshot-only and carries this laptop''s key' {
        $t = [IO.File]::ReadAllText($script:extractor)
        $t | Should -Not -Match 'function Invoke-Upgrade'
        $t | Should -Match "(?m)^\`$CardText = '[A-Za-z0-9+/=]{100,}'"
    }
    It '<Name>: extract on the host, import on the laptop' -ForEach @(
        @{ Name = 'E2E-S2008R2' }, @{ Name = 'E2E-S2008' }, @{ Name = 'E2E-S2012R2' }, @{ Name = 'E2E-S2016' }, @{ Name = 'E2E-S2019' },
        @{ Name = 'E2E-S2022' }, @{ Name = 'E2E-S2025' }, @{ Name = 'E2E-S2029' }, @{ Name = 'E2E-SSAC' },
        @{ Name = 'E2E-W7' }, @{ Name = 'E2E-W81' }, @{ Name = 'E2E-W10' }, @{ Name = 'E2E-W11' }
    ) {
        $p = $script:Profiles | Where-Object { $_.Name -eq $Name }
        $run = Invoke-Extractor $p
        $run.Code | Should -BeIn @(0, 2) -Because $run.Out   # 2 = saved, some reads failed (registry differs per runner)
        $files = @(Find-Result $Name)
        $files.Count | Should -Be 1 -Because $run.Out
        [IO.File]::ReadAllText($files[0].FullName) | Should -Match '^VMM2\|'

        $r = & $script:mod { param($f) Import-VmmResultInbox -Path $f -Quiet -PassThru } $files[0].FullName
        @($r.Failed).Count | Should -Be 0 -Because (@($r.Failed | ForEach-Object Reason) -join '; ')
        @($r.Imported).Count | Should -Be 1
        Test-Path -LiteralPath $files[0].FullName | Should -BeFalse   # imported files are removed

        $h = & $script:mod { param($n) (Read-VmmStore).Hosts | Where-Object { $_.Name -eq $n } } $Name
        $h.Check.Via | Should -Be 'host agent (encrypted)'
        $h.Check.OS | Should -Not -Match '[^\x20-\x7E]'   # (R)/(TM) removed on the host
        $h.Check.Build | Should -Be $p.Build
        $h.Check.CFreeGB | Should -Be 38
        $h.Check.Platform | Should -Be 'Azure'
        $h.Steps.Precheck.Status | Should -Be 'Success'

        $pol = & $script:mod { param($rec) Get-VmmHostPolicy -Record $rec } $h
        $pol.Scope | Should -Be $p.Scope
        if ($p.Warn) { ($pol.Warnings -join ' ') | Should -Match ([regex]::Escape($p.Warn)) } else { ($pol.Warnings -join ' ') | Should -Not -Match 'Server 2008' }

        $inv = & $script:mod { param($n) Get-VmmInventory -HostName $n -PassThru 6>$null } $Name
        $col = @{}; foreach ($f in $inv) { $col[$f.Key] = $f }
        $col['Hostname'].Value | Should -Be $Name
        $col['Domain'].Value | Should -Be 'corp.example.com'
        $col['IPAddress'].Value | Should -Match '^\d{1,3}(\.\d{1,3}){3}$'
        $col['OSVersion'].Value | Should -Match ([regex]::Escape("(build $($p.Build))"))
        $col['WindowsLicense'].Value | Should -Be 'Licensed'
        $col['DomainController'].Value | Should -Be 'No'
        $col['Qualys'].Value | Should -Match '^OK'
        $col['CrowdStrike'].Value | Should -Match '^OK'
        $col['Zabbix'].Value | Should -Match '^FAIL'
        $col['TlsLegacyDisabled'].Value | Should -Match '^(Yes|No)'
        $col['Domain'].Origin | Should -Be 'host agent (encrypted)'
    }
}

Describe 'Any host: the generic Extractor on hosts the fleet does not know yet' {
    BeforeAll {
        # Not imported into the fleet first: the import must add them. One has a DNS name longer than the
        # 15-character COMPUTERNAME Windows keeps; the fleet row must carry the full name.
        $script:NewProfiles = @(
            @{ Name = 'E2E-NEW-S2016'; Dns = 'e2e-new-s2016'; Caption = 'Microsoft Windows Server 2016 Standard'; Version = '10.0.14393'; Build = '14393'; PT = 3; Row = 'E2E-NEW-S2016'; Scope = 'InScope' }
            @{ Name = 'E2E-NEW-LONGNAM'; Dns = 'e2e-new-longname-sql01'; Caption = 'Microsoft Windows Server 2012 R2 Standard'; Version = '6.3.9600'; Build = '9600'; PT = 3; Row = 'E2E-NEW-LONGNAME-SQL01'; Scope = 'InScope' }
            @{ Name = 'E2E-NEW-W11'; Dns = ''; Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.26100'; Build = '26100'; PT = 1; Row = 'E2E-NEW-W11'; Scope = 'ClientOs' }
        )
    }
    It '<Row>: not in the fleet, the result adds it with name, FQDN, IP and every column' -ForEach @(
        @{ Name = 'E2E-NEW-S2016'; Row = 'E2E-NEW-S2016' }, @{ Name = 'E2E-NEW-LONGNAM'; Row = 'E2E-NEW-LONGNAME-SQL01' }, @{ Name = 'E2E-NEW-W11'; Row = 'E2E-NEW-W11' }
    ) {
        $p = $script:NewProfiles | Where-Object { $_.Name -eq $Name }
        $before = & $script:mod { param($n) @((Read-VmmStore).Hosts | Where-Object { $_.Name -eq $n }).Count } $Row
        $before | Should -Be 0
        $run = Invoke-Extractor $p
        $run.Code | Should -BeIn @(0, 2) -Because $run.Out
        $files = @(Find-Result $Name)
        $files.Count | Should -Be 1 -Because $run.Out

        $r = & $script:mod { param($f) Import-VmmResultInbox -Path $f -Quiet -PassThru } $files[0].FullName
        @($r.Failed).Count | Should -Be 0 -Because (@($r.Failed | ForEach-Object Reason) -join '; ')
        @($r.Imported).Count | Should -Be 1
        $r.Imported[0].New | Should -BeTrue
        $r.Imported[0].Host | Should -Be $Row

        $h = @(& $script:mod { param($n) (Read-VmmStore).Hosts | Where-Object { $_.Name -eq $n } } $Row)
        $h.Count | Should -Be 1
        $h[0].Source | Should -Be 'extractor'
        $h[0].IPv4 | Should -Match '^\d{1,3}(\.\d{1,3}){3}$'
        if ($p.Dns) { $h[0].Fqdn | Should -Be ($p.Dns + '.corp.example.com') } else { $h[0].Fqdn | Should -BeNullOrEmpty }
        $h[0].Check.Build | Should -Be $p.Build
        $h[0].Steps.Precheck.Status | Should -Be 'Success'
        (& $script:mod { param($rec) Get-VmmHostPolicy -Record $rec } $h[0]).Scope | Should -Be $p.Scope

        $inv = & $script:mod { param($n) Get-VmmInventory -HostName $n -PassThru 6>$null } $Row
        $col = @{}; foreach ($f in $inv) { $col[$f.Key] = $f }
        $col['Hostname'].Value | Should -Be $Row
        $col['Domain'].Value | Should -Be 'corp.example.com'
        $col['WindowsLicense'].Value | Should -Be 'Licensed'
        $col['Qualys'].Value | Should -Match '^OK'
        $col['TlsLegacyDisabled'].Value | Should -Match '^(Yes|No)'
    }
    It 'a second result from the same host updates its row, no duplicate' {
        $p = $script:NewProfiles[1]
        $null = Invoke-Extractor $p
        $f = @(Find-Result $p.Name)[0]
        $r = & $script:mod { param($x) Import-VmmResultInbox -Path $x -Quiet -PassThru } $f.FullName
        $r.Imported[0].New | Should -BeFalse
        @(& $script:mod { param($n) (Read-VmmStore).Hosts | Where-Object { $_.Name -eq $n } } $p.Row).Count | Should -Be 1
    }
}

Describe 'Resolve-VmmResultHost' {
    It 'matches by name, by the 15-character NetBIOS name, by FQDN; adds unknown hosts' {
        InModuleScope VmMaintenance {
            $a = New-VmmHostRecord -Name 'APP-SERVER-PRODUCTION'
            $b = New-VmmHostRecord -Name 'DB01'; $b | Add-Member -NotePropertyName Fqdn -NotePropertyValue 'db01.corp.example.com' -Force
            $st = [pscustomobject]@{ Hosts = @($a, $b) }
            (Resolve-VmmResultHost -Store $st -Name 'APP-SERVER-PROD').Record.Name | Should -Be 'APP-SERVER-PRODUCTION'
            (Resolve-VmmResultHost -Store $st -Name 'app-server-prod' -DnsName 'app-server-production').Record.Name | Should -Be 'APP-SERVER-PRODUCTION'
            (Resolve-VmmResultHost -Store $st -Name 'db01').New | Should -BeFalse
            $n = Resolve-VmmResultHost -Store $st -Name 'WEB07' -DnsName 'OTHER-NAME' -Fqdn 'other-name.corp.example.com' -IPv4 'x'
            $n.New | Should -BeTrue
            $n.Record.Name | Should -Be 'WEB07'          # a DNS name that is not this host's own is ignored
            $n.Record.Fqdn | Should -BeNullOrEmpty       # and so is an FQDN for another name
            $n.Record.IPv4 | Should -BeNullOrEmpty
            @($st.Hosts).Count | Should -Be 3
            { Resolve-VmmResultHost -Store $st -Name 'bad name' } | Should -Throw -ErrorId 'VmmCollectorName*'
        }
    }
    It 'Collect.AutoAddHosts = false keeps unknown hosts out' {
        InModuleScope VmMaintenance {
            Mock Get-VmmSetting { $false } -ParameterFilter { $Name -eq 'Collect.AutoAddHosts' }
            $st = [pscustomobject]@{ Hosts = @() }
            { Resolve-VmmResultHost -Store $st -Name 'WEB08' } | Should -Throw -ErrorId 'VmmHostUnknown*'
        }
    }
}
