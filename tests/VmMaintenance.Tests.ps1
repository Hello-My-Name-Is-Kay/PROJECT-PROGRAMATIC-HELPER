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
        InModuleScope VmMaintenance { $script:VmmConfig = $script:SavedCfg }
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
