<#
    Pester 5 tests for the offline, pure parts of VmMaintenance. No host, Azure or SQL access.
    Install Pester 5 once (current user, no admin):
        Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
    Run:
        Invoke-Pester -Path .\tests -Output Detailed
#>

BeforeAll {
    $script:repo = Split-Path -Path $PSScriptRoot -Parent
    $script:mod  = Import-Module (Join-Path $script:repo 'VmMaintenance\VmMaintenance.psd1') -Force -PassThru
}

Describe 'Module surface' {
    It 'exports exactly the files in Public\' {
        $files = (Get-ChildItem (Join-Path $repo 'VmMaintenance\Public') -Filter *.ps1).BaseName | Sort-Object
        ($mod.ExportedFunctions.Keys | Sort-Object) | Should -Be $files
    }
    It 'one version everywhere: manifest, Extractor, README, PROJECT.json, top of the changelog' {
        $v = "$($mod.Version)"
        [IO.File]::ReadAllText((Join-Path $repo 'VmMaintenance\Resources\VmmHostAgent.ps1')) | Should -Match ("\`$AgentVersion = '" + [regex]::Escape($v) + "'")
        [IO.File]::ReadAllText((Join-Path $repo 'README.md')) | Should -Match ('\*\*Version:\*\* ' + [regex]::Escape($v) + ' ')
        (Get-Content (Join-Path $repo 'PROJECT.json') -Raw | ConvertFrom-Json).version | Should -Be $v
        ([regex]::Match([IO.File]::ReadAllText((Join-Path $repo 'CHANGELOG.md')), '(?m)^## (\d+\.\d+\.\d+)')).Groups[1].Value | Should -Be $v
    }
    It 'every source file parses without errors' {
        $bad = foreach ($f in (Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' -and $_.FullName -notmatch '\\\.git\\' })) {
            $t = $null; $e = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
            if ($e.Count) { $f.Name }
        }
        $bad | Should -BeNullOrEmpty
    }
    It 'every source file is ASCII-only' {
        $bad = foreach ($f in (Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.cs', '.sql' -and $_.FullName -notmatch '\\\.git\\' })) {
            if ([System.IO.File]::ReadAllBytes($f.FullName) | Where-Object { $_ -gt 127 } | Select-Object -First 1) { $f.Name }
        }
        $bad | Should -BeNullOrEmpty
    }
    It 'no function stores a username or password parameter default' {
        $hits = Select-String -Path (Join-Path $repo 'VmMaintenance\*\*.ps1') -Pattern '\$(Password|UserName)\s*=\s*[''"][^''"]+[''"]'
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'Get-VmmNextDiskTier' {
    It 'returns the next managed-disk tier above the current ceiling' -TestCases @(
        @{ Size = 30;   Want = 64 }
        @{ Size = 127;  Want = 256 }
        @{ Size = 128;  Want = 256 }
        @{ Size = 500;  Want = 1024 }
    ) {
        InModuleScope VmMaintenance -Parameters @{ Size = $Size } {
            Get-VmmNextDiskTier -SizeGB $Size -TierSizes 4, 8, 16, 32, 64, 128, 256, 512, 1024
        } | Should -Be $Want
    }
    It 'returns nothing at the top tier' {
        InModuleScope VmMaintenance { Get-VmmNextDiskTier -SizeGB 1024 -TierSizes 512, 1024 } | Should -BeNullOrEmpty
    }
}

Describe 'Get-VmmVmPlatform' {
    It 'detects <Want>' -TestCases @(
        @{ Mfr = 'VMware, Inc.';          Model = 'VMware7,1';       Mac = '';                  Want = 'VMware' }
        @{ Mfr = 'Microsoft Corporation'; Model = 'Virtual Machine'; Mac = '00-0D-3A-11-22-33'; Want = 'Azure' }
        @{ Mfr = 'Microsoft Corporation'; Model = 'Virtual Machine'; Mac = '00155D112233';      Want = 'Hyper-V' }
    ) {
        InModuleScope VmMaintenance -Parameters @{ Mfr = $Mfr; Model = $Model; Mac = $Mac } {
            Get-VmmVmPlatform -Manufacturer $Mfr -Model $Model -Mac $Mac
        } | Should -Be $Want
    }
}

Describe 'Test-VmmChangeAllowed (Lisbon business-hours rule)' {
    BeforeAll {
        $script:days = 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'
    }
    # 2026-11-16 = Monday, 2026-11-21 = Saturday
    It '<When> off-hours=<Off> holiday=<Hol> -> <Want>' -TestCases @(
        @{ When = '2026-11-16T08:00'; Off = $true;  Hol = '';           Want = $false }
        @{ When = '2026-11-16T16:59'; Off = $true;  Hol = '';           Want = $false }
        @{ When = '2026-11-16T17:00'; Off = $true;  Hol = '';           Want = $true }
        @{ When = '2026-11-16T07:59'; Off = $true;  Hol = '';           Want = $true }
        @{ When = '2026-11-16T07:59'; Off = $false; Hol = '';           Want = $false }
        @{ When = '2026-11-21T11:00'; Off = $false; Hol = '';           Want = $true }
        @{ When = '2026-11-16T11:00'; Off = $true;  Hol = '2026-11-16'; Want = $true }
    ) {
        InModuleScope VmMaintenance -Parameters @{ When = $When; Off = $Off; Hol = $Hol; Days = $days } {
            $h = @(); if ($Hol) { $h = @($Hol) }
            Test-VmmChangeAllowed -ZoneTime ([datetime]$When) -BusinessDays $Days -Start '08:00' -End '17:00' -Holidays $h -OffHoursWeekdays $Off
        } | Should -Be $Want
    }
}

Describe 'Config helpers' {
    It 'Find-VmmPlaceholder finds a nested placeholder' {
        InModuleScope VmMaintenance { Find-VmmPlaceholder -Value @{ A = @{ B = @('x', '<share>') } } } | Should -Be '<share>'
    }
    It 'Get-VmmSetting returns the default for an optional placeholder' {
        InModuleScope VmMaintenance {
            $old = $script:VmmConfig
            try {
                $script:VmmConfig = @{ Azure = @{ TenantId = '<tenant-id>' } }
                Get-VmmSetting 'Azure.TenantId' -Default 'none'
            } finally { $script:VmmConfig = $old }
        } | Should -Be 'none'
    }
    It 'Get-VmmSetting -Required throws on a placeholder' {
        {
            InModuleScope VmMaintenance {
                $old = $script:VmmConfig
                try {
                    $script:VmmConfig = @{ Azure = @{ TenantId = '<tenant-id>' } }
                    Get-VmmSetting 'Azure.TenantId' -Required
                } finally { $script:VmmConfig = $old }
            }
        } | Should -Throw '*placeholder*'
    }
    It 'ConvertTo-VmmPsd1 output loads back with Import-PowerShellDataFile' {
        $psd = InModuleScope VmMaintenance { ConvertTo-VmmPsd1 -InputObject @{ S = "it's"; B = $true; L = @(1, 2); H = @{ X = 'y' } } }
        $f = Join-Path $TestDrive 'r.psd1'
        Set-Content -LiteralPath $f -Value $psd -Encoding ASCII
        $r = Import-PowerShellDataFile -LiteralPath $f
        $r.S | Should -Be "it's"
        $r.B | Should -BeTrue
        $r.L | Should -Be @(1, 2)
        $r.H.X | Should -Be 'y'
    }
}

Describe 'Get-VmmHostPolicy (Server 2019 goal)' {
    It '<Os> on <Platform> -> <Scope>, warnings <Warn>' -TestCases @(
        @{ Os = 'Microsoft Windows Server 2016 Datacenter';    Platform = 'Azure';    Scope = 'InScope';         Warn = 0 }
        @{ Os = 'Microsoft Windows Server 2019 Standard';      Platform = 'Azure';    Scope = 'AtTarget';        Warn = 0 }
        @{ Os = 'Microsoft Windows Server 2022 Standard';      Platform = 'VMware';   Scope = 'NewerThanTarget'; Warn = 0 }
        @{ Os = 'Microsoft Windows 10 Enterprise';             Platform = 'VMware';   Scope = 'ClientOs';        Warn = 0 }
        @{ Os = 'Microsoft Windows 11 Pro';                    Platform = 'Physical'; Scope = 'ClientOs';        Warn = 1 }
        @{ Os = 'Microsoft Windows Server 2008 Standard';      Platform = 'VMware';   Scope = 'InScope';         Warn = 1 }
        @{ Os = 'Microsoft Windows Server 2008 R2 Standard';   Platform = 'Hyper-V';  Scope = 'InScope';         Warn = 0 }
        @{ Os = 'Microsoft Windows Server 2012 R2 Standard';   Platform = 'Physical'; Scope = 'InScope';         Warn = 1 }
        @{ Os = '';                                            Platform = 'Unknown';  Scope = 'Unknown';         Warn = 0 }
    ) {
        $p = InModuleScope VmMaintenance -Parameters @{ Os = $Os; Platform = $Platform } {
            $r = New-VmmHostRecord -Name 'policy-test'
            $r.Platform = $Platform
            if ($Os) { $r.Check = [pscustomobject]@{ OS = $Os } }
            Get-VmmHostPolicy -Record $r
        }
        $p.Scope | Should -Be $Scope
        @($p.Warnings).Count | Should -Be $Warn
    }
}

Describe 'Resolve-VmmTimeZone (setup wizard input)' {
    It "'<In>' -> <Want>" -TestCases @(
        @{ In = 'Lisbon';            Want = 'GMT Standard Time' }
        @{ In = 'lisbon';            Want = 'GMT Standard Time' }
        @{ In = 'London';            Want = 'GMT Standard Time' }
        @{ In = 'Portugal';          Want = 'GMT Standard Time' }
        @{ In = 'Europe/Lisbon';     Want = 'GMT Standard Time' }
        @{ In = 'gmt standard time'; Want = 'GMT Standard Time' }
        @{ In = 'UTC';               Want = 'UTC' }
    ) {
        (InModuleScope VmMaintenance -Parameters @{ In = $In } { Resolve-VmmTimeZone -Text $In }).Id | Should -Be $Want
    }
    It 'returns candidates for an ambiguous text and nothing for nonsense' {
        $amb = InModuleScope VmMaintenance { Resolve-VmmTimeZone -Text 'UTC+01:00' }
        $amb.Id | Should -BeNullOrEmpty
        $amb.Matches.Count | Should -BeGreaterThan 1
        (InModuleScope VmMaintenance { Resolve-VmmTimeZone -Text 'zzz-not-a-zone' }).Id | Should -BeNullOrEmpty
    }
}

Describe 'Media repository (ISO root + one folder per host)' {
    BeforeAll {
        $script:share = Join-Path $TestDrive 'iso-repository'
        New-Item -ItemType Directory -Path $share -Force | Out-Null
        foreach ($n in 'Win_Server_2012R2_EN_US.iso', 'Win_Server_2016_EN_US.ISO', 'Win_Server_2019_EN_US.ISO', 'Win_Server_2019_FR_FR.ISO',
                       'Win_Server_2022_ES-ES.ISO', 'Win_Server_2025_FR_FR.iso', 'readme.txt') { Set-Content -LiteralPath (Join-Path $share $n) -Value 'x' }
        Set-Content -LiteralPath (Join-Path $share 'Win_Server_2019_FR_FR.ISO.sha256') -Value ('A' * 64 + '  Win_Server_2019_FR_FR.ISO')
        $files = @{ 'SERVER_01' = @('SQLServer2014SP3-KB4022619-x64-FRA.exe', 'SQLServer2016SP3-KB5003279-x64-FRA.exe'); 'SERVER_02' = @('SQLServer2014SP3-KB4022619-x64-ENU.exe') }
        foreach ($k in $files.Keys) { New-Item -ItemType Directory -Path (Join-Path $share $k) -Force | Out-Null; foreach ($f in $files[$k]) { Set-Content -LiteralPath (Join-Path $share "$k\$f") -Value 'x' } }
        InModuleScope VmMaintenance -Parameters @{ Share = $share } {
            $script:SavedCfg2 = $script:VmmConfig
            $script:VmmConfig = @{ Staging = @{ SourceShare = $Share; TargetFolder = 'C:\Temp'; OsMediaVersion = 2019 } }
        }
    }
    AfterAll { InModuleScope VmMaintenance { $script:VmmConfig = $script:SavedCfg2 } }

    It 'normalizes language codes: <In> -> <Want>' -TestCases @(
        @{ In = 'fr-FR'; Want = 'FR-FR' }, @{ In = 'FR_FR'; Want = 'FR-FR' }, @{ In = 'ES-ES'; Want = 'ES-ES' }, @{ In = 'sr-Latn-RS'; Want = 'SR-LATN-RS' }, @{ In = ''; Want = $null }, @{ In = 'french'; Want = $null }
    ) {
        InModuleScope VmMaintenance -Parameters @{ In = $In } { ConvertTo-VmmMediaLanguage $In } | Should -Be $Want
    }
    It 'reads images (any case, _ or -), host folders, sidecar hashes and unknown files' {
        $inv = InModuleScope VmMaintenance { Get-VmmMediaInventory }
        $inv.Isos.Count | Should -Be 6
        @($inv.Isos | Where-Object { $_.Version -eq '2012R2' }).Count | Should -Be 1
        ($inv.Isos | Where-Object { $_.Version -eq '2022' }).Lang | Should -Be 'ES-ES'
        ($inv.Isos | Where-Object { $_.Name -eq 'Win_Server_2019_FR_FR.ISO' }).Sha256 | Should -Be ('A' * 64)
        @($inv.Folders).Count | Should -Be 2
        $inv.Other | Should -Be @('readme.txt')
    }
    It 'gives a French host the French 2019 image and its own folder, warns on a SQL version it does not have' {
        $pk = InModuleScope VmMaintenance {
            $rec = [pscustomobject]@{ Name = 'SERVER_01'; Check = [pscustomobject]@{ OS = 'Microsoft Windows Server 2016 Standard'; Lang = 'fr-FR'; Sql = 'MSSQLSERVER 12.0.6024.0 Standard Edition' }; Baseline = $null }
            @(Get-VmmStagingPackage -Record $rec)
        }
        ($pk | Where-Object Kind -eq 'OsMedia').Name | Should -Be 'Win_Server_2019_FR_FR.ISO'
        @($pk | Where-Object Kind -eq 'HostFile').Count | Should -Be 2
        ($pk | Where-Object { $_.Name -like 'SQLServer2016*' }).Note | Should -Match '2016.*2014'
        ($pk | Where-Object { $_.Name -like 'SQLServer2014*' }).Note | Should -BeNullOrEmpty
        @($pk | Where-Object Gate).Count | Should -Be 0
    }
    It 'closes the gate with the exact file name when the language image is missing' {
        $pk = @(InModuleScope VmMaintenance { Get-VmmStagingPackage -Record ([pscustomobject]@{ Name = 'SERVER_09'; Check = [pscustomobject]@{ OS = 'x'; Lang = 'pt-PT'; Sql = 'none' }; Baseline = $null }) })
        $pk.Count | Should -Be 1
        $pk[0].Gate | Should -Match 'Win_Server_2019_PT_PT\.iso'
        $pk[0].Gate | Should -Match 'EN-US, FR-FR'
    }
    It 'closes the gate when the host language is unknown (no silent fallback to English)' {
        $pk = InModuleScope VmMaintenance { @(Get-VmmStagingPackage -Record ([pscustomobject]@{ Name = 'SERVER_02'; Check = $null; Baseline = $null })) }
        ($pk | Where-Object Kind -eq 'OsMedia').Gate | Should -Match 'LANGUAGE UNKNOWN'
        @($pk | Where-Object Kind -eq 'HostFile').Count | Should -Be 1
    }
}

Describe 'Host agent plan card' {
    It 'reads every Package line from the embedded plan' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'VmMaintenance\Resources\VmmHostAgent.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-Card' }, $true) | Select-Object -First 1
        . ([scriptblock]::Create($fn.Extent.Text))
        function Bad { param($t) }
        $CardText = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Host=H1`nPackage=Win_Server_2019_FR_FR.ISO|Win_Server_2019_FR_FR.ISO||Win_Server_2019_FR_FR.ISO`nPackage=b|b.exe||H1\b.exe"))
        $c = Read-Card
        $c.Packages.Count | Should -Be 2
        $c.Host | Should -Be 'H1'
    }
}

Describe 'Server inventory' {
    BeforeAll {
        InModuleScope VmMaintenance {
            $script:SavedCfg3 = $script:VmmConfig
            $script:VmmConfig = @{ Inventory = @{ Defaults = @{ AssignedTechnician = 'Tech A' } }; Staging = @{ OsMediaVersion = 2019 } }
        }
    }
    AfterAll { InModuleScope VmMaintenance { $script:VmmConfig = $script:SavedCfg3 } }

    It 'has the 24 columns in the agreed order, each with help' {
        $want = 'Hostname,Domain,IPAddress,OS Version,Company,Perimeter,Localisation,Phase,Server Owner,Assigned Technician,Actions to be executed,Execution Date,Windows License,QUALYS Cloud AGENT,CrowdStrike Agent,Zabbix,IVANTI,LANSWEEPER AGENT,TLS 1.0-1.1 DISABLED,Actions Status,Domain controller,SQL Present,Comments,Aplication' -split ','
        $cat = @(InModuleScope VmMaintenance { Get-VmmInventoryCatalog -Refresh })
        ($cat | ForEach-Object Header) | Should -Be $want
        @($cat | ForEach-Object Key | Sort-Object -Unique).Count | Should -Be 24
        @($cat | Where-Object { -not $_.Help }).Count | Should -Be 0
        (@($cat | Where-Object { $_.Services.Count }) | ForEach-Object Key) | Should -Be @('Qualys', 'CrowdStrike', 'Zabbix', 'Ivanti', 'LansweeperAgent')
    }
    It 'fills columns from the check, defaults and the workflow, and flags the gaps' {
        $rows = @(InModuleScope VmMaintenance {
            $r = New-VmmHostRecord -Name 'inv-test'
            $r.Platform = 'VMware'; $r.IPv4 = ('192.0.2', '10') -join '.'
            $r.Check = [pscustomobject]@{ OS = 'Microsoft Windows Server 2016 Standard'; Build = '14393'; Sql = 'MSSQLSERVER 13.0.6300.2 Standard Edition' }
            $r.Steps = [pscustomobject]@{ Precheck = [pscustomobject]@{ Status = 'Success'; At = '2026-11-14T08:00:00Z'; Note = '' } }
            Update-VmmInventoryAuto -Record $r -Values ([ordered]@{ Domain = 'corp.example'; TlsLegacyDisabled = 'Yes' }) -Via 'check'
            Update-VmmInventoryAuto -Record $r -Values ([ordered]@{ Domain = ''; Zabbix = 'Running' }) -Via 'host agent (encrypted)'
            Get-VmmInventoryRow -Record $r
        })
        $v = @{}; foreach ($x in $rows) { $v[$x.Key] = $x }
        $v.Hostname.Value | Should -Be 'INV-TEST'
        $v.OSVersion.Value | Should -Be 'Microsoft Windows Server 2016 Standard (build 14393)'
        $v.SqlPresent.Value | Should -Match '^Yes: MSSQLSERVER 13'
        $v.IPAddress.Value | Should -Be (('192.0.2', '10') -join '.')
        $v.Domain.Value | Should -Be 'corp.example'          # an empty later read does not erase it
        $v.Zabbix.Origin | Should -Be 'host agent (encrypted)'
        $v.AssignedTechnician.Origin | Should -Be 'default'
        $v.ActionsStatus.Value | Should -Be 'In progress (last: Precheck)'
        $v.ActionsToExecute.Value | Should -Match 'Upgrade to Windows Server 2019'
        $v.ActionsToExecute.Value | Should -Not -Match 'Precheck'
        $v.Company.Missing | Should -BeTrue
        $v.Comments.Missing | Should -BeFalse
        $v.WindowsLicense.Missing | Should -BeTrue
    }
    It 'the RDP collector carries the same inventory probe as the host agent and parses' {
        $text = InModuleScope VmMaintenance { Get-VmmCollectorScript }
        $text | Should -Match 'function Get-InvProbe'
        $text | Should -Match "'Qualys' = @\('QualysAgent', 'Qualys\*'\)"
        $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$e)
        @($e).Count | Should -Be 0
    }
}

Describe 'Manager and extractor' {
    It 'vmm extractor with no arguments builds the any-host extractor' {
        (Get-Command Export-VmmHostAgent).DefaultParameterSet | Should -Be 'Generic'
    }
    It 'the extractor extracts and saves its result file on start, before the menu' {
        $text = [IO.File]::ReadAllText((Join-Path $repo 'VmMaintenance\Resources\VmmHostAgent.ps1'))
        $text | Should -Match 'function Save-ResultFile'
        $text | Should -Match "VMM_' \+ \`$env:COMPUTERNAME"
        $main = $text.Substring($text.IndexOf('# ============================================================== main'))
        $main.IndexOf('Export-Result -Auto') | Should -BeLessThan $main.IndexOf('while ($true)')
    }
}

Describe 'Theme: deep iceberg blue, colour only for statuses' {
    It 'only statuses map to a colour role; information stays neutral' {
        $r = InModuleScope VmMaintenance { 'Success', 'Green', 'Warn', 'Yellow', 'Error', 'Critical', 'Unreachable', 'Info', 'Cyan', 'Plain', 'Gray', 'Trace', 'DarkGray', '' | ForEach-Object { ConvertTo-VmmColorRole $_ } }
        ($r -join ',') | Should -Be 'Ok,Ok,Warn,Warn,Fail,Fail,Fail,Text,Text,Text,Text,Muted,Muted,Text'
    }
    It 'has one palette with a 16-colour fallback for old consoles' {
        $t = InModuleScope VmMaintenance { $saved = $script:VmmConfig; $script:VmmConfig = @{ Log = @{ ToFile = $false } }; $x = Get-VmmTheme -Refresh; $script:VmmConfig = $saved; $script:VmmThemeCache = $null; $x }
        (@($t.Roles.Keys | Sort-Object) -join ',') | Should -Be 'Accent,AccentBg,BarBg,Bg,Fail,Muted,Ok,Strong,Text,Warn'
        foreach ($k in 'Bg', 'BarBg', 'AccentBg', 'Accent', 'Text', 'Muted') { $t.Roles[$k].B | Should -BeGreaterThan $t.Roles[$k].R -Because "$k is blue" }
        ($t.Roles.Bg.R + $t.Roles.Bg.G + $t.Roles.Bg.B) | Should -BeLessThan 60   # still a dark background
        "$($t.Roles.Bg.Console)" | Should -Be 'Black'
        $t.Roles.AccentBg.B | Should -BeGreaterThan $t.Roles.AccentBg.R      # blue
        "$($t.Roles.AccentBg.Console)" | Should -Be 'DarkBlue'
        "$($t.Roles.Warn.Console)" | Should -Be 'DarkYellow'                  # orange
        "$($t.Roles.Ok.Console),$($t.Roles.Fail.Console)" | Should -Be 'Green,Red'
    }
    It 'writes 24-bit colour when the console takes it, and plain text with --no-color' {
        $o = InModuleScope VmMaintenance {
            $roles = (Get-VmmTheme -Refresh).Roles
            $script:VmmThemeCache = @{ Roles = $roles; TrueColor = $true; Plain = $false }
            $a = "$((Write-VmmColor 'x' -Role Warn 6>&1).MessageData.Message)"
            $b = "$((Write-VmmColor 'x' -Role Strong -BgRole AccentBg 6>&1).MessageData.Message)"
            $script:VmmThemeCache = @{ Roles = $roles; TrueColor = $true; Plain = $true }
            $c = "$((Write-VmmColor 'x' -Role Warn 6>&1).MessageData.Message)"
            $script:VmmThemeCache = $null
            $a, $b, $c
        }
        $e = [char]27
        $o[0] | Should -Be "${e}[38;2;227;136;45mx${e}[0m"
        $o[1] | Should -Be "${e}[38;2;238;247;255m${e}[48;2;24;92;138mx${e}[0m"
        $o[2] | Should -Be 'x'
    }
    It 'no screen sets a colour by hand any more (all go through the theme)' {
        $hits = foreach ($f in (Get-ChildItem (Join-Path $repo 'VmMaintenance\Private'), (Join-Path $repo 'VmMaintenance\Public') -Filter *.ps1)) {
            if ($f.Name -in 'Write-VmmColor.ps1', 'Get-VmmCollectorScript.ps1') { continue }
            if ((Get-Content $f.FullName -Raw) -match '-ForegroundColor|-BackgroundColor') { $f.Name }
        }
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'One vmm at a time' {
    BeforeAll {
        InModuleScope VmMaintenance -Parameters @{ Root = "$TestDrive" } {
            $script:SavedCfgLock = $script:VmmConfig
            New-Item -ItemType Directory -Path (Join-Path $Root 'lockdata') -Force | Out-Null
            $script:VmmConfig = @{ Log = @{ ToFile = $false }; Paths = @{ DataDir = (Join-Path $Root 'lockdata'); ReportDir = (Join-Path $Root 'lockrep') } }
            Exit-VmmInstanceLock
        }
    }
    AfterAll { InModuleScope VmMaintenance { Exit-VmmInstanceLock; $script:VmmConfig = $script:SavedCfgLock } }
    It 'takes the lock once, releases it, and leaves no owner note behind' {
        $r = InModuleScope VmMaintenance {
            $a = Enter-VmmInstanceLock -Owner 'vmm ui'; $b = Enter-VmmInstanceLock
            $note = Get-Content -LiteralPath (Join-Path (Get-VmmPath -Name Data) 'vmm.lock.txt') -Raw
            Exit-VmmInstanceLock
            "$a,$b,$($note -match ('^' + $PID + '\|[\d\- :]+\|vmm ui$')),$(Test-Path -LiteralPath (Join-Path (Get-VmmPath -Name Data) 'vmm.lock.txt'))"
        }
        $r | Should -Be 'True,False,True,False'
    }
    It 'a second vmm stops with VmmInstanceLocked and names the holder; read-only commands still run' {
        $dir = InModuleScope VmMaintenance { Get-VmmPath -Name Data }
        $fs = New-Object System.IO.FileStream((Join-Path $dir 'vmm.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            [IO.File]::WriteAllText((Join-Path $dir 'vmm.lock.txt'), '4242|2026-11-14 19:00:00|vmm ui')
            $err = $null
            try { Invoke-VmmCli -Command remove -Arguments @('-Name', 'x') } catch { $err = $_ }
            "$($err.FullyQualifiedErrorId)" | Should -Match '^VmmInstanceLocked'
            $err.Exception.Message | Should -Match 'process 4242'
            { InModuleScope VmMaintenance { Save-VmmStore -Store ([pscustomobject]@{ Updated = $null; Hosts = @() }) } } | Should -Throw -ErrorId 'VmmInstanceLocked*'
            (Invoke-VmmCli -Command time).ZoneLabel | Should -Not -BeNullOrEmpty
        } finally { $fs.Dispose() }
        InModuleScope VmMaintenance { $x = Enter-VmmInstanceLock; Exit-VmmInstanceLock; $x } | Should -BeTrue
    }
}

Describe 'The CLI logs every command' {
    It 'logs the command line, what it printed, the result, and a failure with its error id' {
        $b = InModuleScope VmMaintenance {
            $saved = $script:VmmConfig; $script:VmmConfig = @{ Log = @{ ToFile = $false } }
            $script:VmmLogBuffer = $null
            Invoke-VmmCli -Command time | Out-Null
            try { Invoke-VmmCli -Command guide -Arguments @('-HostName', 'x', '-Step', 'NoSuchStep') | Out-Null } catch { }
            [pscustomobject]@{ A = 1; B = 'password=Hunter2' } | Out-VmmHost 6>$null
            $script:VmmConfig = $saved
            @($script:VmmLogBuffer | ForEach-Object { "$($_.Level)|$($_.Text)" })
        }
        ($b -join "`n") | Should -Match 'Muted\|Command: vmm time'
        ($b -join "`n") | Should -Match 'Output\|ZoneLabel'
        ($b -join "`n") | Should -Match 'Muted\|vmm time done in [\d\.,]+ s'
        ($b -join "`n") | Should -Match 'Command: vmm guide -HostName -Step'
        ($b -join "`n") | Should -Match 'Error\|vmm guide -HostName -Step FAILED in [\d\.,]+ s: .+\[.+\]'
        ($b -join "`n") | Should -Match 'Output\|1 password=\*\*\*'
        ($b -join "`n") | Should -Not -Match 'Hunter2'
    }
    It 'no file prints a table without logging it (Out-VmmHost, not Out-Host)' {
        $hits = foreach ($f in (Get-ChildItem (Join-Path $repo 'VmMaintenance\Private'), (Join-Path $repo 'VmMaintenance\Public') -Filter *.ps1)) {
            if ($f.Name -eq 'Out-VmmHost.ps1') { continue }
            if ((Get-Content $f.FullName -Raw) -match '\|\s*Out-Host') { $f.Name }
        }
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'Results from a host are untrusted' {
    It 'a host result cannot mark a change step done or record an override while steps are off' {
        $t = [IO.File]::ReadAllText((Join-Path $repo 'VmMaintenance\Public\Import-VmmCollectorResult.ps1'))
        $t | Should -Match "Get-VmmSetting 'Extractor.AllowSteps' -Default \`$false"
        $t | Should -Match "-not \`$hostSteps -and \(\`$res -eq 'Override' -or \(\`$st -in \`$known -and \`$st -notin 'Precheck', 'Verify'\)\)"
    }
}

Describe 'Non-invasive snapshot, terminal first' {
    BeforeAll {
        $script:AgentText = [IO.File]::ReadAllText((Join-Path $repo 'VmMaintenance\Resources\VmmHostAgent.ps1'))
        $b = $script:AgentText.IndexOf('# VMM-STEPS-BEGIN'); $e = $script:AgentText.IndexOf('# VMM-STEPS-END')
        $script:SnapText = $script:AgentText.Substring(0, $b) + $script:AgentText.Substring($e + 15)
    }
    It 'the snapshot build parses and holds no code that changes a host' {
        $err = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($script:SnapText, [ref]$null, [ref]$err)
        @($err).Count | Should -Be 0
        foreach ($w in 'diskpart', 'Start-Process', 'New-Item', 'Set-Content', 'Add-Content', 'icacls', 'Copy-Item', 'Set-ItemProperty', 'New-ItemProperty', 'Set-Service', 'Start-Service', 'Stop-Service', 'Restart-Computer', 'Win32_Product', 'Invoke-WebRequest', 'Net.WebClient', 'Invoke-Expression') {
            $script:SnapText | Should -Not -Match ([regex]::Escape($w))
        }
        # the one write: the result file on the desktop
        ([regex]::Matches($script:SnapText, 'WriteAllText')).Count | Should -Be 1
    }
    It 'steps run only when the block is in the file and the card says Steps' {
        $script:AgentText | Should -Match "Mode = 'Snapshot'"
        $script:AgentText | Should -Match "\(\`$Card\.Mode -eq 'Steps'\) -and \[bool\]\(Get-Command Invoke-StepsMenu"
        $steps = $script:AgentText.Substring($script:AgentText.IndexOf('# VMM-STEPS-BEGIN'))
        $steps | Should -Match 'function Invoke-Extend'
        $steps | Should -Match 'function Invoke-Upgrade'
    }
    It 'a read that fails becomes a Problem line and the rest still goes' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:SnapText, [ref]$null, [ref]$null)
        foreach ($n in 'Protect-Text', 'Add-Problem', 'Get-Facts', 'Get-Wmi', 'Test-Admin') {
            $fn = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true) | Select-Object -First 1
            . ([scriptblock]::Create($fn.Extent.Text))
        }
        function Test-Admin { $false }
        function Get-WmiObject { param($Class, $Filter, $ErrorAction)
            if ($Class -eq 'Win32_LogicalDisk') { throw 'Access denied' }
            if ($Class -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ Caption = 'Microsoft Windows Server 2016 Standard'; Version = '10.0.14393'; BuildNumber = '14393'; ServicePackMajorVersion = 0; OSLanguage = 1036 } }
            [pscustomobject]@{ Manufacturer = 'VMware, Inc.'; Model = 'VMware7,1' }
        }
        $Script:Problems = @(); $Card = @{ TargetFolder = 'C:\Temp' }
        $f = Get-Facts
        $f.OS | Should -Be 'Microsoft Windows Server 2016 Standard'
        $f.Lang | Should -Be 'fr-FR'
        $f.Platform | Should -Be 'VMware'
        $f.CFreeGB | Should -BeNullOrEmpty
        @($Script:Problems | Where-Object { $_ -match '^C: drive: Access denied' }).Count | Should -Be 1
    }
    It 'the fleet check tries DCOM, WinRM and WinRM-SSL and records the route' {
        $t = InModuleScope VmMaintenance { Get-VmmHostCheckScript }
        $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$e)
        @($e).Count | Should -Be 0
        $t | Should -Match "'DCOM' = 135; 'WinRM' = 5985; 'WinRM-SSL' = 5986"
        $t | Should -Match 'New-CimSessionOption -Protocol Wsman'
        $t | Should -Match '\$r\.Route = \$route'
        foreach ($w in 'Set-Item', 'TrustedHosts', 'Enable-PSRemoting', 'Invoke-Command', 'Win32_Product', 'Create\(') { $t | Should -Not -Match $w }
    }
    It 'access state: route works, no route, not tried' {
        $r = InModuleScope VmMaintenance {
            $saved = $script:VmmConfig; $script:VmmConfig = @{ Log = @{ ToFile = $false } }
            $now = (Get-Date).ToUniversalTime()
            $a = New-VmmHostRecord -Name 'acc-a'; $a | Add-Member -NotePropertyName Access -NotePropertyValue ([pscustomobject]@{ At = $now.AddHours(-1).ToString('o'); Route = 'WinRM'; Why = ''; Tried = '' })
            $b = New-VmmHostRecord -Name 'acc-b'; $b | Add-Member -NotePropertyName Access -NotePropertyValue ([pscustomobject]@{ At = $now.AddHours(-1).ToString('o'); Route = 'None'; Why = 'No terminal route'; Tried = '' })
            $c = New-VmmHostRecord -Name 'acc-c'
            $d = New-VmmHostRecord -Name 'acc-d'; $d | Add-Member -NotePropertyName Access -NotePropertyValue ([pscustomobject]@{ At = $now.AddHours(-80).ToString('o'); Route = 'DCOM'; Why = ''; Tried = '' })
            $x = @($a, $b, $c, $d | ForEach-Object { Get-VmmHostAccess -Record $_ }); $script:VmmConfig = $saved; $x }
        $r[0].Terminal | Should -BeTrue;  $r[0].Route | Should -Be 'WinRM'
        $r[1].Terminal | Should -BeFalse; $r[1].Why | Should -Match 'No terminal route'
        $r[2].Terminal | Should -BeNullOrEmpty
        $r[3].Terminal | Should -BeNullOrEmpty; $r[3].Why | Should -Match 'try again'
    }
}

Describe 'External host list (CSV: hostname or FQDN, domain, IP)' {
    BeforeAll {
        $script:ip1 = ('192.0.2', '11') -join '.'; $script:ip2 = ('192.0.2', '12') -join '.'; $script:ip3 = ('198.51.100', '7') -join '.'
        $script:badIp = ('999.1.1', '1') -join '.'
    }
    It 'reads a plain 3-column file without header, FQDN or short names' {
        $f = Join-Path $TestDrive 'a.csv'
        Set-Content -LiteralPath $f -Value @("srv01.corp.example,corp.example,$ip1", "SRV02,,$ip2", '# comment', '', "bad name!,x,$ip1", "srv04,corp.example,$badIp")
        $r = @(InModuleScope VmMaintenance -Parameters @{ F = $f } { Read-VmmHostCsv -Path $F } 3>$null)
        $r.Count | Should -Be 3
        $r[0].Name | Should -Be 'SRV01'; $r[0].Fqdn | Should -Be 'srv01.corp.example'; $r[0].Domain | Should -Be 'corp.example'; $r[0].IP | Should -Be $ip1
        $r[1].Name | Should -Be 'SRV02'; $r[1].Fqdn | Should -BeNullOrEmpty; $r[1].IP | Should -Be $ip2
        $r[2].Name | Should -Be 'SRV04'; $r[2].IP | Should -BeNullOrEmpty; $r[2].Fqdn | Should -Be 'srv04.corp.example'
    }
    It 'reads a header row in any column order, separator ;' {
        $f = Join-Path $TestDrive 'b.csv'
        Set-Content -LiteralPath $f -Value @('IP;Hostname;Domain', "$ip3;srv03;Corp.Example")
        $r = @(InModuleScope VmMaintenance -Parameters @{ F = $f } { Read-VmmHostCsv -Path $F })
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'SRV03'; $r[0].IP | Should -Be $ip3; $r[0].Domain | Should -Be 'corp.example'; $r[0].Fqdn | Should -Be 'srv03.corp.example'
    }
}

Describe 'SQL Server update fetch' {
    BeforeAll {
        # dbatools stand-ins: 2016 SP2 (13.0.5026) -> target SP3 + CU, plus the SP3 base build
        function global:Test-DbaBuild { param($Build, [switch]$Latest, $MaxBehind, [switch]$EnableException)
            if ($Build -like '13.0.7*') { [pscustomobject]@{ Compliant = $true; BuildTarget = $Build } } else { [pscustomobject]@{ Compliant = $false; BuildTarget = '13.0.7050.2' } } }
        function global:Get-DbaBuild { param($Build, $MajorVersion, $ServicePack, [switch]$EnableException, [switch]$Update)
            if ($MajorVersion) { return [pscustomobject]@{ NameLevel = '2016'; SPLevel = 'SP3'; CULevel = ''; KBLevel = @('5003279') } }
            switch -Wildcard ($Build) {
                '13.0.5026*' { [pscustomobject]@{ NameLevel = '2016'; SPLevel = 'SP2'; CULevel = ''; KBLevel = @('4052908') } }
                '13.0.7050*' { [pscustomobject]@{ NameLevel = '2016'; SPLevel = 'SP3'; CULevel = 'CU1'; KBLevel = @('5040944') } }
                default      { [pscustomobject]@{ NameLevel = '2016'; SPLevel = 'SP3'; CULevel = 'CU1'; KBLevel = @('5040944') } }
            } }
    }
    AfterAll { Remove-Item function:global:Test-DbaBuild, function:global:Get-DbaBuild -ErrorAction SilentlyContinue }
    It 'turns PatchLevel into the Microsoft build number' {
        InModuleScope VmMaintenance { (ConvertTo-VmmSqlBuild '13.2.5026.0'), (ConvertTo-VmmSqlBuild '10.53.6000.34'), (ConvertTo-VmmSqlBuild '15.0.4415.2') -join ',' } |
            Should -Be '13.0.5026.0,10.50.6000.34,15.0.4415.2'
    }
    It 'maps install languages to the update file tag' {
        InModuleScope VmMaintenance { (ConvertTo-VmmSqlLanguage '1036'), (ConvertTo-VmmSqlLanguage 'es-ES'), (ConvertTo-VmmSqlLanguage ''), (ConvertTo-VmmSqlLanguage 'pt-BR') -join ',' } |
            Should -Be 'FRA,ESN,ENU,PTB'
    }
    It 'reads instances, with the SQL language before the OS language' {
        $r = @(InModuleScope VmMaintenance {
            $rec = [pscustomobject]@{ Name = 'H1'; Baseline = $null; Check = [pscustomobject]@{ Sql = 'MSSQLSERVER 13.2.5026.0 Standard Edition; SQL2 15.0.4415.2 Express Edition'; SqlLang = 'MSSQLSERVER=1036'; Lang = 'es-ES' } }
            Get-VmmSqlInstance -Record $rec })
        $r.Count | Should -Be 2
        $r[0].Build | Should -Be '13.0.5026.0'
        $r[0].Lang | Should -Be 'FRA'
        $r[1].Lang | Should -Be 'ESN'
    }
    It 'plans the service pack first when the target CU belongs to a newer SP' {
        $p = InModuleScope VmMaintenance { Get-VmmSqlUpdatePlan -Build '13.0.5026.0' }
        (@($p.Steps | ForEach-Object { "$($_.Kind):$($_.Kb)" }) -join ',') | Should -Be 'SP:KB5003279,CU:KB5040944'
    }
    It 'plans nothing for a current build' {
        (InModuleScope VmMaintenance { Get-VmmSqlUpdatePlan -Build '13.0.7050.2' }).Steps.Count | Should -Be 0
    }
    It 'does not treat the download cache as a host folder' {
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'share\_Downloads\SQL'), (Join-Path $TestDrive 'share\H1') -Force | Out-Null
        $inv = InModuleScope VmMaintenance -Parameters @{ S = (Join-Path $TestDrive 'share') } { Get-VmmMediaInventory -Share $S }
        (@($inv.Folders | ForEach-Object Name) -join ',') | Should -Be 'H1'
    }
}

Describe 'Agent health (Extractor and fleet check share the rules)' {
    BeforeAll {
        $agentPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'VmMaintenance\Resources\VmmHostAgent.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($agentPath, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-AgentVerdict' }, $true) | Select-Object -First 1
        . ([scriptblock]::Create($fn.Extent.Text))
        $script:Spec = @{ LogMaxAgeHours = '48'; MinVersion = '7.0' }
        $script:Run = [pscustomobject]@{ Name = 'CSFalconService'; State = 'Running'; StartMode = 'Auto' }
    }
    It 'is OK when running, automatic and new enough, and shows the version' {
        $v = Get-AgentVerdict $script:Run '7.16.18605.0' @() @() 2 $script:Spec
        $v.Status | Should -Be 'OK'
        $v.Text | Should -Be 'OK - Running, v7.16.18605.0'
    }
    It 'is FAIL when not installed, stopped, or the driver is not running' {
        (Get-AgentVerdict $null '' @() @() $null $script:Spec).Text | Should -Be 'FAIL - Not installed'
        (Get-AgentVerdict ([pscustomobject]@{ Name = 'X'; State = 'Stopped'; StartMode = 'Auto' }) '7.1' @() @() $null $script:Spec).Status | Should -Be 'FAIL'
        (Get-AgentVerdict $script:Run '7.1' @('CSAgent') @() $null $script:Spec).Issues | Should -Match 'driver CSAgent not running'
    }
    It 'is WARN for manual start, old version, closed port or a silent log' {
        (Get-AgentVerdict ([pscustomobject]@{ Name = 'X'; State = 'Running'; StartMode = 'Manual' }) '7.1' @() @() $null $script:Spec).Status | Should -Be 'WARN'
        (Get-AgentVerdict $script:Run '6.5.1' @() @() $null $script:Spec).Issues | Should -Match 'version below 7.0'
        (Get-AgentVerdict $script:Run '7.1' @() @('10050 not listening') $null $script:Spec).Status | Should -Be 'WARN'
        (Get-AgentVerdict $script:Run '7.1' @() @() 100 $script:Spec).Issues | Should -Match 'log not written for 100 h'
    }
    It 'gives every agent column a health spec, with minimum versions from the settings' {
        $m = InModuleScope VmMaintenance {
            $saved = $script:VmmConfig; $script:VmmConfig = @{ Log = @{ ToFile = $false }; Agents = @{ MinVersion = @{ CrowdStrike = '7.0' } } }
            $x = Get-VmmAgentCheckMap; $script:VmmConfig = $saved; $x }
        (@($m.Keys) -join ',') | Should -Be 'Qualys,CrowdStrike,Zabbix,Ivanti,LansweeperAgent'
        $m.CrowdStrike.Drivers | Should -Contain 'CSAgent'
        $m.CrowdStrike.MinVersion | Should -Be '7.0'
        $m.Zabbix.Ports | Should -Contain '10050'
    }
    It 'puts the same rules into the fleet check script and the collector' {
        $s = InModuleScope VmMaintenance { (Get-VmmHostCheckScript), (Get-VmmCollectorScript) }
        $s[0] | Should -Match 'function Get-AgentVerdict'
        $s[1] | Should -Match 'function Get-AgentVerdict'
        foreach ($x in $s) { $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($x, [ref]$null, [ref]$e); $e.Count | Should -Be 0 }
    }
    It 'a failed agent makes the host health Warn' {
        InModuleScope VmMaintenance {
            $saved = $script:VmmConfig; $script:VmmConfig = @{ Log = @{ ToFile = $false } }
            $c = [pscustomobject]@{ Reachable = 'Yes'; CFreeGB = 80; PendingReboot = 'No'; Error = $null; Agents = [pscustomobject]@{ Qualys = [pscustomobject]@{ Status = 'FAIL' } } }
            $h = Get-VmmHostHealth -Check $c; $script:VmmConfig = $saved; $h
        } | Should -Be 'Warn'
    }
}

Describe 'Logging and errors' {
    It 'Protect-VmmLogText masks secrets' {
        $o = InModuleScope VmMaintenance { Protect-VmmLogText 'pwd=abc123 token: xyz Bearer eyJhbGci.x.y' }
        $o | Should -Not -Match 'abc123|xyz|eyJhbGci'
    }
    It 'Get-VmmErrorHint knows ScopeLocked' {
        (InModuleScope VmMaintenance { Get-VmmErrorHint -Message 'ScopeLocked: resource is locked' }).Fix | Should -Match 'lock'
    }
    It 'New-VmmErrorRecord carries Activity, Cause and Fix in the message' {
        $e = InModuleScope VmMaintenance { New-VmmErrorRecord -Activity 'Doing X.' -Target 'T1' -Cause 'Because.' -Fix 'Do Y.' -ErrorId 'VmmTest' }
        $e.Exception.Message | Should -Match 'Doing X'
        $e.Exception.Message | Should -Match 'Do Y'
    }
    It 'every log line lands in the live pane buffer, secrets masked' {
        $b = InModuleScope VmMaintenance {
            $saved = $script:VmmConfig; $script:VmmConfig = @{ Log = @{ ToFile = $false } }
            Write-VmmLog 'pane test password=Hunter2' -Level Warn -FileOnly
            $script:VmmConfig = $saved
            $script:VmmLogBuffer[-1]
        }
        $b.Level | Should -Be 'Warn'
        $b.Text | Should -Match 'pane test'
        $b.Text | Should -Not -Match 'Hunter2'
    }
    It 'live log follows the session switch first, then the setting' {
        InModuleScope VmMaintenance {
            $saved = $script:VmmConfig; $script:VmmConfig = @{ Log = @{ ToFile = $false; Live = 'false' } }
            $script:VmmLogLive = $null
            $a = Test-VmmLogLive
            $script:VmmLogLive = $true
            $b = Test-VmmLogLive
            $script:VmmLogLive = $null; $script:VmmConfig = $saved
            "$a,$b"
        } | Should -Be 'False,True'
    }
}

Describe 'Encrypted store' -Skip:(-not (($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows)) {
    BeforeAll {
        InModuleScope VmMaintenance -Parameters @{ Root = "$TestDrive" } {
            $script:SavedCfg = $script:VmmConfig
            New-Item -ItemType Directory -Path (Join-Path $Root 'data'), (Join-Path $Root 'reports') -Force | Out-Null
            $script:VmmConfig = @{ Paths = @{ DataDir = (Join-Path $Root 'data'); ReportDir = (Join-Path $Root 'reports') } }
        }
    }
    AfterAll {
        InModuleScope VmMaintenance { Exit-VmmInstanceLock; $script:VmmConfig = $script:SavedCfg }
    }
    It 'round-trips bytes' {
        InModuleScope VmMaintenance {
            $p = [Text.Encoding]::UTF8.GetBytes('machine-record')
            [Text.Encoding]::UTF8.GetString((Unprotect-VmmBytes -Bytes (Protect-VmmBytes -Bytes $p)))
        } | Should -Be 'machine-record'
    }
    It 'rejects a modified file' {
        {
            InModuleScope VmMaintenance {
                $c = Protect-VmmBytes -Bytes ([byte[]](1..50))
                $c[40] = $c[40] -bxor 1
                Unprotect-VmmBytes -Bytes $c
            }
        } | Should -Throw
    }
    It 'saves and reads the fleet store without plaintext host names on disk' {
        InModuleScope VmMaintenance {
            $s = Read-VmmStore
            $s.Hosts = @($s.Hosts) + (New-VmmHostRecord -Name 'pester-host')
            Save-VmmStore -Store $s
            @((Read-VmmStore).Hosts | Where-Object Name -eq 'PESTER-HOST').Count
        } | Should -Be 1
        $raw = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $TestDrive 'data\fleet.vmm')))
        $raw | Should -Not -Match '(?i)pester-host'
    }
}

Describe 'RDP / RDM handoff' {
    It 'the .rdp file carries no account and shares only the drives asked for' {
        $t = InModuleScope VmMaintenance { Get-VmmRdpFileText -Address 'srv01' -Drive 'C', 'd:' }
        $t | Should -Match '(?m)^full address:s:srv01\r?$'
        $t | Should -Match '(?m)^drivestoredirect:s:C:\\;D:\\;\r?$'
        $t | Should -Not -Match '(?im)^(username|password|domain)'
        { InModuleScope VmMaintenance { Get-VmmRdpFileText -Address 'srv01;x' } } | Should -Throw
    }
    It 'the RDCMan file is valid XML' {
        ([xml](InModuleScope VmMaintenance { Get-VmmRdgFileText -Address 'srv01' })).RDCMan.file.server.properties.name | Should -Be 'srv01'
    }
    It 'reads a VMMSTAGE1 report and judges every file' {
        $r = InModuleScope VmMaintenance {
            $exp = @([pscustomobject]@{ DestName = 'a.iso'; Size = 10; Sha256 = 'AA' }, [pscustomobject]@{ DestName = 'b.exe'; Size = 5; Sha256 = 'BB' })
            $rep = @(ConvertFrom-VmmHandoffReport -Text 'VMMSTAGE1|SRV01|a.iso*10*aa|b.exe*4*BB' -HostName 'srv01')
            (Compare-VmmHandoffFile -Expected $exp -Reported $rep | ForEach-Object Status) -join ','
        }
        $r | Should -Be 'OK,SizeMismatch'
    }
    It 'the host script writes only into the target and reports what it copied' {
        $src = Join-Path $TestDrive 'pkg.bin'; [IO.File]::WriteAllBytes($src, [byte[]](1..64))
        $sha = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
        $dest = Join-Path $TestDrive 'host'
        $text = InModuleScope VmMaintenance -Parameters @{ S = $src; H = $sha; D = $dest } {
            Get-VmmHandoffScript -HostName 'srv01' -Target $D -Items @([pscustomobject]@{ DestName = 'pkg.bin'; Size = 64; Sha256 = $H; Sources = @($S) })
        }
        $text | Should -Not -Match 'Remove-Item|Start-Process|Invoke-Expression'
        $out = (& ([scriptblock]::Create(($text -replace '\$R \| clip\.exe', '$null = $R'))) 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Join-Path $dest 'pkg.bin' | Should -Exist
        $out | Should -Match ('VMMSTAGE1\|SRV01\|pkg\.bin\*64\*' + $sha)
    }
    It 'Stage keeps the terminal copy first and records a handoff only when verified' {
        $t = [IO.File]::ReadAllText((Join-Path $repo 'VmMaintenance\Public\Invoke-VmmWorkflowStep.ps1'))
        $t.IndexOf('Copy-VmmStagingPackage -HostName $name') | Should -BeLessThan $t.IndexOf('Start-VmmRemoteHandoff -HostName')
        $t | Should -Match 'if \(-not \$h\.Verified\) \{ throw \$copyErr \}'
    }
    It 'the CLI has handoff and rdp' {
        $t = [IO.File]::ReadAllText((Join-Path $repo 'VmMaintenance\Public\Invoke-VmmCli.ps1'))
        $t | Should -Match "'handoff'\s*=\s*@\{ F = 'Start-VmmRemoteHandoff'"
        $t | Should -Match "'rdp'\s*=\s*@\{ F = 'Start-VmmRemoteSession'"
    }
}
