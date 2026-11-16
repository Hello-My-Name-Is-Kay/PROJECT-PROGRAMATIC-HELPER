<#
    Pester 5 tests for the last-fallback host script (VmMaintenance\Resources\Fallback\VmmFallback.ps1) and its
    companion file (VmmFallback.psd1). Functions are parsed out of the script (not run) and tested here; the
    process tests start the script in a new PowerShell process and check its exit codes. No host is changed:
    the Windows-only process tests use a throwaway work folder under C:\Temp and the read-only paths.
    Run:
        Invoke-Pester -Path .\tests\Fallback.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $script:dir = Join-Path (Split-Path -Parent $PSScriptRoot) 'VmMaintenance\Resources\Fallback'
    $script:fbPath = Join-Path $script:dir 'VmmFallback.ps1'
    $script:dataPath = Join-Path $script:dir 'VmmFallback.psd1'
    $tokens = $null; $errs = $null
    $script:fbAst = [System.Management.Automation.Language.Parser]::ParseFile($script:fbPath, [ref]$tokens, [ref]$errs)
    $script:fbTokens = $tokens
    if ($errs -and $errs.Count) { throw "VmmFallback.ps1 does not parse: $($errs[0].Message)" }
    # Every top-level function of the script, defined here (the main block at the bottom is not run)
    foreach ($fn in $script:fbAst.EndBlock.Statements) {
        if ($fn -is [System.Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($fn.Extent.Text)) }
    }
    $script:FallbackVersion = 'test'
    $script:Inv = [Globalization.CultureInfo]::InvariantCulture
    $script:Problems = @()
    $script:StepIds = @('Snapshot', 'Precheck', 'WindowsPatch', 'SqlPatch', 'SqlUpgrade', 'OsUpgrade', 'Disk', 'Postcheck', 'Finish')
    $script:NoColor = $true
    $script:Data = Read-Companion $script:dataPath

    function script:New-Facts([string]$Os, [string]$Platform = 'Azure') {
        New-Object PSObject -Property @{ OS = $Os; Platform = $Platform; DomainController = 'No'; Cluster = 'No'; Exchange = 'No' }
    }
    function script:Copy-Data { Read-Companion $script:dataPath }   # a fresh, independent copy to break
    # The PowerShell executable of this run, for the process tests
    $script:Ps = (Get-Process -Id $PID).Path
    function script:Invoke-Fallback {
        param([string[]]$ArgumentList)
        $out = & $script:Ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:fbPath @ArgumentList 2>&1
        [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out | Out-String) }
    }
    $script:OnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

Describe 'Companion file' {
    It 'the shipped VmmFallback.psd1 is valid' {
        @(Test-Companion $script:Data) | Should -BeNullOrEmpty
    }
    It 'names the key of each problem' {
        $d = Copy-Data
        $d.Settings.Remove('TargetOs')
        $d.Settings.WorkDir = 'D:\Work'
        $d.Settings.BusinessStart = '18:00'
        $d.Settings.Holidays = @('25/12/2026')
        $d.Settings.BusinessDays = @('Monday', 'Funday')
        $d.Steps = @($d.Steps | Where-Object { $_.Id -ne 'Finish' }) + @(@{ Id = 'Reboot'; Title = 'x'; Advice = @('a'); Manual = @('m') }, @{ Id = 'Disk'; Title = 'x'; Advice = @('a'); Manual = @('m') })
        $d.OsPath[3].NextBuild = ''
        $d.SqlVersions[0].OnTarget = 'CU5'
        $p = (@(Test-Companion $d) -join "`n")
        foreach ($want in 'Settings.TargetOs', 'Settings.WorkDir must be a folder under C:\Temp', 'BusinessStart must be before', 'Holidays: ''25/12/2026''', 'Funday', 'Id ''Reboot'' is unknown', 'Id ''Disk'' is listed twice', 'Steps must include Finish', 'OsPath entry 4: State Upgrade needs', 'SqlVersions entry 1: OnTarget') {
            $p | Should -Match ([regex]::Escape($want))
        }
    }
    It 'rejects a wrong schema version and a non-hashtable' {
        $d = Copy-Data; $d.SchemaVersion = 2
        (@(Test-Companion $d) -join ' ') | Should -Match 'SchemaVersion must be 1'
        @(Test-Companion 'text').Count | Should -Be 1
    }
    It 'step with no Manual lines is refused (guidance-only must always exist)' {
        $d = Copy-Data; $d.Steps[2].Manual = @()
        (@(Test-Companion $d) -join ' ') | Should -Match 'Steps.WindowsPatch: Manual needs at least one line'
    }
    It 'every step id the script knows has a handler, and every companion step is known' {
        foreach ($id in $script:StepIds) {
            $fn = $script:fbAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq ('Invoke-Step' + $id) }, $true)
            @($fn).Count | Should -Be 1 -Because "Invoke-Step$id must exist"
        }
        foreach ($s in $script:Data.Steps) { $script:StepIds | Should -Contain $s.Id }
    }
    It 'holds no host names, IP addresses or user names (generic data only)' {
        $t = [IO.File]::ReadAllText($script:dataPath)
        $t | Should -Not -Match '\b(?:\d{1,3}\.){3}\d{1,3}\b'
        $t | Should -Not -Match '\\\\[A-Za-z0-9]'
    }
}

Describe 'Work folder rule' {
    It 'accepts only folders below C:\Temp' {
        Test-UnderTemp 'C:\Temp\VmmFallback' | Should -BeTrue
        Test-UnderTemp 'c:\temp\a\b\' | Should -BeTrue
        Test-UnderTemp 'C:\Temp' | Should -BeFalse
        Test-UnderTemp 'D:\Temp\x' | Should -BeFalse
        Test-UnderTemp 'C:\Temp\..\Windows' | Should -BeFalse
        Test-UnderTemp 'C:\TempX\a' | Should -BeFalse
    }
}

Describe 'Time window (Mon-Fri 08:00-17:00 Lisbon)' {
    BeforeAll { $script:S = $script:Data.Settings }
    # 2026-11-16 is a Monday; Lisbon is UTC+0 in November
    It 'Monday 10:00 is business hours: changes refused' {
        $w = Get-Window $script:S ([DateTime]::SpecifyKind([DateTime]'2026-11-16T10:00:00', 'Utc'))
        $w.InHours | Should -BeTrue
        $w.ChangesAllowed | Should -BeFalse
        $w.Why | Should -Match 'only reads and staging'
    }
    It 'Monday 17:00 and later, and Saturday, allow changes' {
        (Get-Window $script:S ([DateTime]::SpecifyKind([DateTime]'2026-11-16T17:00:00', 'Utc'))).ChangesAllowed | Should -BeTrue
        (Get-Window $script:S ([DateTime]::SpecifyKind([DateTime]'2026-11-21T10:00:00', 'Utc'))).ChangesAllowed | Should -BeTrue
    }
    It 'a holiday allows changes all day' {
        $s = @{} + $script:S; $s.Holidays = @('2026-11-16')
        (Get-Window $s ([DateTime]::SpecifyKind([DateTime]'2026-11-16T10:00:00', 'Utc'))).ChangesAllowed | Should -BeTrue
    }
    It 'summer time is respected (Lisbon is UTC+1 in July: 07:30 UTC = 08:30 local)' {
        (Get-Window $script:S ([DateTime]::SpecifyKind([DateTime]'2026-07-06T07:30:00', 'Utc'))).ChangesAllowed | Should -BeFalse
        (Get-Window $script:S ([DateTime]::SpecifyKind([DateTime]'2026-07-06T06:30:00', 'Utc'))).ChangesAllowed | Should -BeTrue
    }
}

Describe 'OS policy' {
    It '<os> -> <scope>, next <next>' -TestCases @(
        @{ os = 'Microsoft Windows Server 2008 Standard';      scope = 'InScope';         next = 'Windows Server 2012';    change = $true;  osup = $true }
        @{ os = 'Microsoft Windows Server 2008 R2 Enterprise'; scope = 'InScope';         next = 'Windows Server 2012 R2'; change = $true;  osup = $true }
        @{ os = 'Microsoft Windows Server 2012 Standard';      scope = 'InScope';         next = 'Windows Server 2016';    change = $true;  osup = $true }
        @{ os = 'Microsoft Windows Server 2012 R2 Standard';   scope = 'InScope';         next = 'Windows Server 2019';    change = $true;  osup = $true }
        @{ os = 'Microsoft Windows Server 2016 Datacenter';    scope = 'InScope';         next = 'Windows Server 2019';    change = $true;  osup = $true }
        @{ os = 'Microsoft Windows Server 2019 Standard';      scope = 'AtTarget';        next = '';                       change = $true;  osup = $false }
        @{ os = 'Microsoft Windows Server 2022 Standard';      scope = 'NewerThanTarget'; next = '';                       change = $true;  osup = $false }
        @{ os = 'Microsoft Windows Server 2003 R2 Standard';   scope = 'Unsupported';     next = '';                       change = $false; osup = $false }
        @{ os = 'Microsoft Windows 10 Enterprise';             scope = 'ClientOs';        next = $null;                    change = $false; osup = $false }
        @{ os = 'Microsoft Windows 11 Pro';                    scope = 'ClientOs';        next = $null;                    change = $false; osup = $false }
        @{ os = 'Microsoft Windows Server 2030 Standard';      scope = 'Unknown';         next = $null;                    change = $false; osup = $false }
    ) {
        param($os, $scope, $next, $change, $osup)
        $p = Get-Policy (New-Facts $os) $script:Data ''
        $p.Scope | Should -Be $scope
        $p.ChangeOk | Should -Be $change
        $p.OsUpgradeOk | Should -Be $osup
        if ($null -ne $next) { "$($p.Entry.Next)" | Should -Be $next }
    }
    It 'a client OS with an order may be patched but never OS-upgraded' {
        $p = Get-Policy (New-Facts 'Microsoft Windows 10 Pro') $script:Data 'Ticket 1234 approved by the owner'
        $p.Scope | Should -Be 'ClientOsOrdered'
        $p.ChangeOk | Should -BeTrue
        $p.OsUpgradeOk | Should -BeFalse
    }
    It 'warns about Server 2008 (not R2) and physical machines' {
        $w = (Get-Policy (New-Facts 'Microsoft Windows Server 2008 Standard' 'Physical') $script:Data '').Warnings -join ' '
        $w | Should -Match '2008 \(not R2\)'
        $w | Should -Match 'Physical machine'
        ((Get-Policy (New-Facts 'Microsoft Windows Server 2008 R2 Standard') $script:Data '').Warnings -join ' ') | Should -Not -Match 'not R2'
    }
    It 'domain controllers, clusters and Exchange get guidance-only OS upgrades' {
        foreach ($k in 'DomainController', 'Cluster', 'Exchange') {
            $f = New-Facts 'Microsoft Windows Server 2016 Standard'; $f.$k = 'Yes'
            $p = Get-Policy $f $script:Data ''
            $p.OsUpgradeOk | Should -BeFalse -Because $k
            $p.ChangeOk | Should -BeTrue -Because "$k may still be patched"
        }
    }
    It 'the Server 2008 caption with registered-trademark signs is matched after cleaning' {
        $r = [string][char]0xAE
        $os = ConvertTo-Ascii ('Microsoft' + $r + ' Windows Server' + $r + ' 2008 Standard ')
        $os | Should -Be 'Microsoft Windows Server 2008 Standard'
        (Get-Policy (New-Facts $os) $script:Data '').Entry.Next | Should -Be 'Windows Server 2012'
    }
}

Describe 'SQL rules' {
    It 'major version from <v> is <m>' -TestCases @(
        @{ v = '10.50.6000.34'; m = 10.5 }, @{ v = '10.0.6556.0'; m = 10 }, @{ v = '15.0.4355.3'; m = 15 }, @{ v = '9.00.5000'; m = 9 }
    ) { param($v, $m) Get-SqlMajor $v | Should -Be $m }
    It 'an unreadable version gives no major' { Get-SqlMajor 'unknown' | Should -BeNullOrEmpty }
    It '<v> <l> on the target OS -> <want>' -TestCases @(
        @{ v = '10.50.6000.34'; l = 'SP3'; want = 'UpgradeFirst' }
        @{ v = '10.0.6000.29';  l = 'SP4'; want = 'UpgradeFirst' }
        @{ v = '11.0.7001.0';   l = 'SP4'; want = 'OK' }
        @{ v = '11.0.6020.0';   l = 'SP3'; want = 'PatchFirst' }
        @{ v = '13.0.5026.0';   l = 'SP2'; want = 'PatchFirst' }
        @{ v = '13.0.6300.2';   l = 'SP3'; want = 'OK' }
        @{ v = '15.0.2000.5';   l = 'RTM'; want = 'OK' }
        @{ v = '8.0.2039';      l = 'SP4'; want = 'Unknown' }
    ) {
        param($v, $l, $want)
        (Get-SqlVerdict ([pscustomobject]@{ Version = $v; Level = $l }) $script:Data).Verdict | Should -Be $want
    }
    It 'upgrade options need the minimum level of the source version' {
        $o = Get-SqlUpgradeOption ([pscustomobject]@{ Version = '10.50.4000.0'; Level = 'SP2' }) $script:Data
        $o.LevelOk | Should -BeFalse
        $o.To | Should -Contain 'SQL Server 2016'
        (Get-SqlUpgradeOption ([pscustomobject]@{ Version = '10.50.6000.34'; Level = 'SP3' }) $script:Data).LevelOk | Should -BeTrue
        Get-SqlUpgradeOption ([pscustomobject]@{ Version = '16.0.1000.6'; Level = 'RTM' }) $script:Data | Should -BeNullOrEmpty
    }
    It 'level ranks: RTM 0, SPn n, unknown -1' {
        Get-LevelRank 'RTM' | Should -Be 0
        Get-LevelRank 'SP4' | Should -Be 4
        Get-LevelRank '' | Should -Be -1
    }
    It 'SQL instance names keep names that start with PS' {
        $props = [pscustomobject]@{ PSPath = 'x'; PSChildName = 'SQL'; MSSQLSERVER = 'MSSQL15.MSSQLSERVER'; PSQL01 = 'MSSQL13.PSQL01' }
        @(Get-SqlInstanceNames $props | ForEach-Object { $_.Name }) | Should -Be @('MSSQLSERVER', 'PSQL01')
    }
}

Describe 'OS image, disk and native exit codes' {
    It 'picks the install.wim index with the same edition and form' {
        $imgs = @(
            [pscustomobject]@{ Index = 1; Name = 'Windows Server 2019 Standard' }
            [pscustomobject]@{ Index = 2; Name = 'Windows Server 2019 Standard (Desktop Experience)' }
            [pscustomobject]@{ Index = 3; Name = 'Windows Server 2019 Datacenter' }
            [pscustomobject]@{ Index = 4; Name = 'Windows Server 2019 Datacenter (Desktop Experience)' }
        )
        Select-ImageIndex $imgs 'ServerStandard' $false | Should -Be 2
        Select-ImageIndex $imgs 'ServerStandard' $true | Should -Be 1
        Select-ImageIndex $imgs 'ServerDatacenter' $false | Should -Be 4
        $old = @([pscustomobject]@{ Index = 1; Name = 'Windows Server 2012 R2 SERVERSTANDARDCORE' }, [pscustomobject]@{ Index = 2; Name = 'Windows Server 2012 R2 SERVERSTANDARD' })
        Select-ImageIndex $old 'ServerStandard' $false | Should -Be 2
        Select-ImageIndex @() 'ServerStandard' $false | Should -Be 0
    }
    It 'next Azure disk tier' {
        Get-NextDiskTier 30 $script:Data.Settings.DiskTiersGB | Should -Be 64
        Get-NextDiskTier 127 $script:Data.Settings.DiskTiersGB | Should -Be 256
        Get-NextDiskTier 2048 $script:Data.Settings.DiskTiersGB | Should -BeNullOrEmpty
    }
    It 'native exit <e> -> <r>' -TestCases @(
        @{ e = 0; r = 'Ok' }, @{ e = 3010; r = 'Reboot' }, @{ e = 1641; r = 'Reboot' }, @{ e = 2359302; r = 'Skip' }, @{ e = -2145124329; r = 'Skip' },
        @{ e = -1047526896; r = 'Ok' }, @{ e = -1047526904; r = 'Fail' }, @{ e = 1603; r = 'Fail' }
    ) { param($e, $r) (Get-NativeVerdict 'tool' $e).Result | Should -Be $r }
    It 'guide session exit code: failure wins, then reboot, then failed reads' {
        Get-SessionExitCode @(0, 9, 1) 0 | Should -Be 1
        Get-SessionExitCode @(0, 9, 8) 3 | Should -Be 9
        Get-SessionExitCode @(0, 8, 3, 5) 2 | Should -Be 7
        Get-SessionExitCode @(0, 8) 0 | Should -Be 0
    }
}

Describe 'Change gate (policy 5, time window 3, administrator 10)' {
    BeforeAll {
        $script:Open = New-Object PSObject -Property @{ ChangesAllowed = $true; Why = 'open' }
        $script:Closed = New-Object PSObject -Property @{ ChangesAllowed = $false; Why = 'Business hours' }
    }
    BeforeEach { $script:Policy = Get-Policy (New-Facts 'Microsoft Windows Server 2016 Standard') $script:Data '' }
    It 'all clear -> 0' { (Test-Gate 'x' -Window $script:Open -IsAdmin $true).Code | Should -Be 0 }
    It 'client OS without order -> 5 (before the window and admin checks)' {
        $script:Policy = Get-Policy (New-Facts 'Microsoft Windows 11 Pro') $script:Data ''
        (Test-Gate 'x' -Window $script:Closed -IsAdmin $false).Code | Should -Be 5
    }
    It 'OS upgrade on the target OS -> 5, patching still 0' {
        $script:Policy = Get-Policy (New-Facts 'Microsoft Windows Server 2019 Standard') $script:Data ''
        (Test-Gate 'x' -OsUpgrade -Window $script:Open -IsAdmin $true).Code | Should -Be 5
        (Test-Gate 'x' -Window $script:Open -IsAdmin $true).Code | Should -Be 0
    }
    It 'business hours -> 3' {
        $g = Test-Gate 'x' -Window $script:Closed -IsAdmin $true
        $g.Code | Should -Be 3
        $g.Why | Should -Match 'Business hours'
    }
    It 'not administrator -> 10' { (Test-Gate 'x' -Window $script:Open -IsAdmin $false).Code | Should -Be 10 }
}

Describe 'Result file and sanitizing' {
    It 'writes Extractor-compatible keys plus the fallback ones' {
        $script:Problems = @('Event log System: access denied')
        $f = New-Object PSObject -Property @{
            Name = 'HOSTA'; OS = 'Microsoft Windows Server 2016 Standard'; Edition = 'ServerStandard'; InstallType = 'Server'; Lang = 'en-US'
            Version = '10.0.14393'; Build = '14393'; UBR = '7000'; SP = '0'; Arch = '64-bit'; InstallDate = ''; LastBoot = ''; UptimeDays = 3
            Manufacturer = 'Microsoft Corporation'; Model = 'Virtual Machine'; Platform = 'Azure'; Cpus = '4'; RamGB = 16; Domain = 'corp.example.com'
            DomainController = 'No'; Cluster = 'No'; Iis = 'No'; Exchange = 'No'; CTotalGB = 127; CFreeGB = 20.5
            Disks = @([pscustomobject]@{ Drive = 'C:'; FileSystem = 'NTFS'; SizeGB = 127; FreeGB = 20.5 }); PendingReboot = @('servicing')
            Patches = @([pscustomobject]@{ Id = 'KB5000001'; Date = [DateTime]'2026-10-15' }); PatchCount = '1'; LastPatch = '2026-10-15'
            WuService = 'Running (Manual)'; Wsus = 'No'; Features = @('FS-FileServer'); Software = @('App|1.0')
            Sql = @([pscustomobject]@{ Name = 'MSSQLSERVER'; Bits = '32-bit'; Version = '13.0.5026.0'; Level = 'SP2'; Update = ''; Edition = 'Standard Edition'; Service = 'Running'; Clustered = 'No'; Hadr = 'No'; Databases = '3'; Stale = @('AppDb|never') })
            Agents = @{ Qualys = 'Running' }; TlsLegacy = 'Yes'; Licence = 'Licensed'; DotNet = '4.x release 528049'; TimeZone = 'GMT Standard Time'
            EventsSystem = '2'; EventsApplication = '0'; PSVersion = '5.1'; Admin = $true
        }
        $l = ConvertTo-ResultLines $f (Get-Policy $f $script:Data '') $script:Data 'snapshot'
        $l[0] | Should -Be 'Format=VMMF1'
        foreach ($k in 'Name=HOSTA', 'Platform=Azure', 'CTotalGB=127', 'CFreeGB=20.5', 'PendingReboot=Yes', 'Sql=MSSQLSERVER 13.0.5026.0 Standard Edition (32-bit)',
                       'Inv.Domain=corp.example.com', 'Inv.SqlPresent=Yes', 'Inv.Qualys=Running', 'Disk=C:|NTFS|127|20.5', 'Patch=KB5000001|2026-10-15',
                       'SqlStaleBackup=MSSQLSERVER|AppDb|never', 'Policy.Scope=InScope', 'Policy.NextOs=Windows Server 2019', 'Problem=Event log System: access denied') {
            $l | Should -Contain $k
        }
        ($l | Where-Object { $_ -like 'SqlInstance=*' }) | Should -Match '\|PatchFirst$'
    }
    It 'masks secrets, product keys, IP addresses and e-mail addresses in log and Problem lines' {
        $ip = (192, 0, 2, 7) -join '.'
        $t = Protect-Text ("setup /PID=AAAAA-BBBBB password=hunter2 from $ip by " + ('someone' + '@' + 'example.com'))
        $t | Should -Not -Match 'AAAAA|hunter2|someone@'
        $t | Should -Not -Match ([regex]::Escape($ip))
    }
    It 'fills the placeholders of advice lines' {
        Expand-Text 'Copy to {MediaDir}\Sql for {Instance}' @{ MediaDir = 'C:\Temp\M'; Instance = 'X' } | Should -Be 'Copy to C:\Temp\M\Sql for X'
    }
}

Describe 'PowerShell 2.0 compatibility and exits (static)' {
    It 'uses no PowerShell 3+ syntax' {
        $text = [IO.File]::ReadAllText($script:fbPath)
        foreach ($bad in '\[pscustomobject\]', '\[ordered\]', '::new\(', '\$PSScriptRoot', 'ConvertTo-Json', 'ConvertFrom-Json', '-ErrorAction\s+Ignore', '\?\?', '\?\.') {
            $text | Should -Not -Match $bad -Because "$bad is not PowerShell 2.0"
        }
        $ops = @($script:fbTokens | Where-Object { $_.Text -eq '-in' -or $_.Text -eq '-notin' -or $_.Text -eq '-iin' -or $_.Text -eq '-inotin' -or $_.Text -eq '-cin' -or $_.Text -eq '-cnotin' })
        $ops.Count | Should -Be 0 -Because 'the -in / -notin operators need PowerShell 3'
    }
    It 'calls Get-CimInstance only inside Get-Wmi (PowerShell 7 fallback)' {
        $calls = $script:fbAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-CimInstance' }, $true)
        foreach ($c in $calls) {
            $p = $c.Parent
            while ($p -and -not ($p -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $p = $p.Parent }
            $p.Name | Should -Be 'Get-Wmi'
        }
    }
    It 'has exactly one exit statement (every path ends through it with a known code)' {
        @($script:fbAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)).Count | Should -Be 1
    }
    It 'only uses the documented exit codes' {
        $codes = @(0, 1, 2, 3, 5, 6, 7, 8, 9, 10)
        $rets = $script:fbAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] -and $n.Pipeline -and $n.Pipeline.Extent.Text -match '^\d+$' }, $true)
        foreach ($r in $rets) { $codes | Should -Contain ([int]$r.Pipeline.Extent.Text) }
    }
    It 'never reboots the host' {
        $text = [IO.File]::ReadAllText($script:fbPath)
        $text | Should -Not -Match 'Restart-Computer|shutdown(\.exe)?\s+/r'
    }
    It 'is ASCII only' {
        foreach ($f in $script:fbPath, $script:dataPath) { @([IO.File]::ReadAllBytes($f) | Where-Object { $_ -gt 127 }).Count | Should -Be 0 }
    }
}

Describe 'Process exit codes' {
    It '-Check on the shipped companion file exits 0' { (Invoke-Fallback '-Check').Code | Should -Be 0 }
    It '-Help exits 0' { (Invoke-Fallback '-Help').Code | Should -Be 0 }
    It 'usage errors exit 2: <why>' -TestCases @(
        @{ why = 'two modes';           a = @('-Snapshot', '-Check') }
        @{ why = 'unknown step';        a = @('-Step', 'Reboot') }
        @{ why = 'unknown action';      a = @('-Step', 'Disk', '-Action', 'Now') }
        @{ why = 'instance alone';      a = @('-Instance', 'X') }
        @{ why = 'short order';         a = @('-Order', 'yes') }
        @{ why = 'work dir not C:\Temp'; a = @('-Check', '-WorkDir', 'D:\Work') }
        @{ why = 'missing companion';   a = @('-Check', '-DataFile', 'no-such-file.psd1') }
    ) {
        param($why, $a)
        (Invoke-Fallback $a).Code | Should -Be 2
    }
    It 'an invalid companion file exits 2 and names the problem' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('vmmf-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $bad = Join-Path $tmp 'VmmFallback.psd1'
            ([IO.File]::ReadAllText($script:dataPath)) -replace 'SchemaVersion = 1', 'SchemaVersion = 7' | Set-Content -LiteralPath $bad -Encoding ASCII
            $r = Invoke-Fallback @('-Check', '-DataFile', $bad)
            $r.Code | Should -Be 2
            $r.Text | Should -Match 'SchemaVersion must be 1'
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }
    It 'Run without a console exits 2 (a person must type YES)' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $wd = 'C:\Temp\VmmFallbackTest' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        try { (Invoke-Fallback @('-Step', 'WindowsPatch', '-Action', 'Run', '-WorkDir', $wd)).Code | Should -Be 2 }
        finally { Remove-Item -LiteralPath $wd -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'snapshot on this machine exits 0 or 7 and saves a VMMF1 result' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $wd = 'C:\Temp\VmmFallbackTest' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        try {
            $r = Invoke-Fallback @('-Snapshot', '-NoColor', '-WorkDir', $wd)
            @(0, 7) | Should -Contain $r.Code -Because $r.Text
            $f = @(Get-ChildItem -LiteralPath $wd -Filter 'VMMF_*_snapshot_*.txt')
            $f.Count | Should -Be 1
            $l = Get-Content -LiteralPath $f[0].FullName
            $l[0] | Should -Be 'Format=VMMF1'
            ($l -join "`n") | Should -Match "(?m)^Name=$([regex]::Escape($env:COMPUTERNAME))$"
            @(Get-ChildItem -LiteralPath $wd -Filter 'fallback_*.log').Count | Should -Be 1
            Test-Path -LiteralPath (Join-Path $wd 'fallback.lock') | Should -BeFalse
        } finally { Remove-Item -LiteralPath $wd -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'guidance-only steps change nothing and exit 0' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $wd = 'C:\Temp\VmmFallbackTest' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        try {
            foreach ($s in 'Precheck', 'SqlPatch', 'OsUpgrade', 'Disk', 'Finish') {
                $r = Invoke-Fallback @('-Step', $s, '-Action', 'Guide', '-NoColor', '-WorkDir', $wd)
                $r.Code | Should -Be 0 -Because "$s guidance: $($r.Text)"
            }
        } finally { Remove-Item -LiteralPath $wd -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'a second copy exits 6 while the lock is held' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $wd = 'C:\Temp\VmmFallbackTest' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        New-Item -ItemType Directory -Path $wd | Out-Null
        $lock = [IO.File]::Open((Join-Path $wd 'fallback.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try { (Invoke-Fallback @('-Snapshot', '-WorkDir', $wd)).Code | Should -Be 6 }
        finally { $lock.Close(); Remove-Item -LiteralPath $wd -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
