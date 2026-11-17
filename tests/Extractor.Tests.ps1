<#
    Pester 5 tests for the Extractor (VmMaintenance\Resources\VmmHostAgent.ps1), the file that is copied to a host
    and run there. Its functions are taken out of the file (parsed, not run) and tested here: no host is read.
    Run:
        Invoke-Pester -Path .\tests\Extractor.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $script:agentPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'VmMaintenance\Resources\VmmHostAgent.ps1'
    $script:agentAst = [System.Management.Automation.Language.Parser]::ParseFile($script:agentPath, [ref]$null, [ref]$null)
    foreach ($name in 'Get-Wmi', 'Get-SqlInstanceNames', 'Get-SqlInstanceLines', 'Get-ExtractExitCode', 'Save-ResultFile', 'Get-AgentVerdict', 'Get-InvProbe') {
        $fn = $script:agentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
        if (-not $fn) { throw "Extractor function $name not found" }
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    # Stand-ins for the two WMI cmdlets: the tests choose the branch with $script:WmiUseCim, so Windows PowerShell 5.1
    # (which has Get-WmiObject) and PowerShell 7 (which has not) run the same tests
    $script:Calls = @()
    $script:TestIp = (192, 0, 2, 7) -join '.'   # built at run time: the leak scan allows no IPv4 text in the repository
    function global:Get-CimInstance {
        [CmdletBinding()] param([string]$ClassName, [string]$Filter)
        $script:Calls += ('cim:' + $ClassName + ':' + $Filter)
        Get-TestWmiRow $ClassName
    }
    function global:Get-WmiObject {
        [CmdletBinding()] param([string]$Class, [string]$Filter)
        $script:Calls += ('wmi:' + $Class + ':' + $Filter)
        Get-TestWmiRow $Class
    }
    function global:Get-TestWmiRow([string]$Class) {
        $ip = $script:TestIp
        switch ($Class) {
            'Win32_ComputerSystem'                { [pscustomobject]@{ Domain = 'corp.example.com'; PartOfDomain = $true; DomainRole = 3 } }
            'Win32_NetworkAdapterConfiguration'   { [pscustomobject]@{ IPAddress = @($ip) } }
            'Win32_Service'                       { [pscustomobject]@{ Name = 'QualysAgent'; DisplayName = 'Qualys Agent'; State = 'Running'; StartMode = 'Auto'; PathName = '' } }
            'Win32_LogicalDisk'                   { [pscustomobject]@{ Size = 100GB; FreeSpace = 40GB } }
            default                               { $null }
        }
    }
}
AfterAll {
    foreach ($f in 'Get-CimInstance', 'Get-WmiObject', 'Get-TestWmiRow') { Remove-Item -LiteralPath "function:global:$f" -ErrorAction SilentlyContinue }
    $script:WmiUseCim = $null
}

Describe 'WMI reads work on Windows PowerShell and on PowerShell 7' {
    BeforeEach { $script:Calls = @() }
    It 'reads through Get-CimInstance where Get-WmiObject does not exist, filter included' {
        $script:WmiUseCim = $true
        $d = Get-Wmi 'Win32_LogicalDisk' "DeviceID='C:'"
        $d.Size | Should -Be 100GB
        @($script:Calls) | Should -Be @("cim:Win32_LogicalDisk:DeviceID='C:'")
    }
    It 'reads through Get-WmiObject where it exists (PowerShell 2.0 to 5.1)' {
        $script:WmiUseCim = $false
        $null = Get-Wmi 'Win32_ComputerSystem'
        @($script:Calls) | Should -Be @('wmi:Win32_ComputerSystem:')
    }
    It 'the inventory probe, which the laptop pastes into the RDP collector, reads the same way on both' {
        foreach ($cim in $true, $false) {
            $script:WmiUseCim = $cim
            $lines = @(Get-InvProbe @{ Qualys = @('QualysAgent') } $null $true)
            $lines | Should -Contain 'Inv.Domain=corp.example.com'
            $lines | Should -Contain 'Inv.DomainController=No'
            $lines | Should -Contain ('Inv.IPAddress=' + $script:TestIp)
            $lines | Should -Contain 'Inv.Qualys=Running'
            @($lines | Where-Object { $_ -like 'Problem=*' -and $_ -match 'Domain|IP address|Services' }) | Should -BeNullOrEmpty
        }
    }
    It 'every Get-WmiObject call sits in the two readers, none is left bare' {
        $calls = @($script:agentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-WmiObject' }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($c in $calls) {
            $p = $c.Parent
            while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }
            $p.Name | Should -BeIn 'Get-Wmi', 'Get-InvProbe'
        }
        @($calls | Where-Object { $p = $_.Parent; while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }; $p.Name -eq 'Get-InvProbe' }).Count | Should -Be 2
    }
}

Describe 'SQL instance names' {
    It 'keeps an instance whose name starts with PS and leaves out only PowerShell''s own properties' {
        $props = New-Object PSObject -Property @{ MSSQLSERVER = 'MSSQL15.MSSQLSERVER'; PSQL01 = 'MSSQL15.PSQL01'; PSPath = 'x'; PSParentPath = 'x'; PSChildName = 'x'; PSDrive = 'x'; PSProvider = 'x' }
        $names = @(Get-SqlInstanceNames $props | ForEach-Object Name | Sort-Object)
        $names | Should -Be @('MSSQLSERVER', 'PSQL01')
    }
    It 'no filter on the PS* prefix is left in the SQL read' {
        [IO.File]::ReadAllText($script:agentPath) | Should -Not -Match "-notlike 'PS\*'"
    }
}

Describe 'The result file keeps the last snapshot until the new one is written' {
    BeforeEach {
        $script:OldComputer = $env:COMPUTERNAME
        $env:COMPUTERNAME = 'TESTHOST'
        $script:Desk = Join-Path $TestDrive ('desk-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Desk -Force | Out-Null
        $script:OldFile = Join-Path $script:Desk 'VMM_TESTHOST_20200101_0000.vmm'
        [IO.File]::WriteAllText($script:OldFile, 'old snapshot')
        [IO.File]::WriteAllText((Join-Path $script:Desk 'VMM_OTHERHOST_20200101_0000.vmm'), 'another host')
    }
    AfterEach { $env:COMPUTERNAME = $script:OldComputer }
    It 'writes the new file, then removes the older ones of this host only' {
        $new = Save-ResultFile 'new snapshot' $script:Desk
        [IO.File]::ReadAllText($new) | Should -Be 'new snapshot'
        $script:OldFile | Should -Not -Exist
        (Join-Path $script:Desk 'VMM_OTHERHOST_20200101_0000.vmm') | Should -Exist
        @(Get-ChildItem -LiteralPath $script:Desk -Filter 'VMM_TESTHOST_*.vmm').Count | Should -Be 1
    }
    It 'keeps the old snapshot when the new file cannot be written' {
        # A folder in the place of the file makes the write fail, for this minute and the next
        foreach ($m in 0, 1) { New-Item -ItemType Directory -Path (Join-Path $script:Desk ('VMM_TESTHOST_' + (Get-Date).AddMinutes($m).ToString('yyyyMMdd_HHmm') + '.vmm')) -Force | Out-Null }
        { Save-ResultFile 'new snapshot' $script:Desk } | Should -Throw
        [IO.File]::ReadAllText($script:OldFile) | Should -Be 'old snapshot'
    }
}

Describe 'Extractor exit code' {
    It '0 when saved and every read worked, 1 when not saved, 2 when saved with failed reads' {
        Get-ExtractExitCode 'C:\x.vmm' 0 | Should -Be 0
        Get-ExtractExitCode $null 0 | Should -Be 1
        Get-ExtractExitCode $null 3 | Should -Be 1
        Get-ExtractExitCode 'C:\x.vmm' 2 | Should -Be 2
    }
    It '-Extract ends through that function' {
        [IO.File]::ReadAllText($script:agentPath) | Should -Match '(?s)\$code = Get-ExtractExitCode \$Script:LastResultFile \$Script:Problems\.Count\s+if \(\$code\) \{ exit \$code \}'
    }
}

Describe 'SQL instances in both registry views' {
    BeforeEach {
        $script:Reg = @{
            'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' = (New-Object PSObject -Property @{ MSSQLSERVER = 'MSSQL15.MSSQLSERVER'; PSQL01 = 'MSSQL15.PSQL01'; PSPath = 'x' })
            'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\Setup' = (New-Object PSObject -Property @{ PatchLevel = '15.0.4000.1'; Edition = 'Standard Edition' })
            'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server\Instance Names\SQL' = (New-Object PSObject -Property @{ MSSQLSERVER = 'MSSQL10.MSSQLSERVER'; OLD32 = 'MSSQL10.OLD32'; PSPath = 'x' })
            'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server\MSSQL10.OLD32\Setup' = (New-Object PSObject -Property @{ PatchLevel = '10.50.6000.34'; Edition = 'Express Edition' })
        }
    }
    It 'lists 64-bit instances, 32-bit ones tagged, a repeated name once, and an unreadable setup key by name' {
        function Test-Path { param($Path) $script:Reg.ContainsKey($Path) -or $Path -like '*PSQL01*' }
        function Get-ItemProperty { param($Path) if ($script:Reg.ContainsKey($Path)) { $script:Reg[$Path] } else { throw 'not found' } }
        $lines = @(Get-SqlInstanceLines | Sort-Object)   # the registry property order is not fixed
        $lines.Count | Should -Be 3
        $lines | Should -Contain 'MSSQLSERVER 15.0.4000.1 Standard Edition'
        $lines | Should -Contain 'PSQL01 (setup key unreadable)'
        $lines | Should -Contain 'OLD32 10.50.6000.34 Express Edition (32-bit)'
    }
    It 'returns nothing when neither view has SQL Server' {
        function Test-Path { param($Path) $false }
        @(Get-SqlInstanceLines).Count | Should -Be 0
    }
    It 'the RDP collector and the fleet check read the 32-bit view too, and keep no PS* name filter' {
        $root = Split-Path -Parent $PSScriptRoot
        foreach ($f in 'Get-VmmCollectorScript.ps1', 'Get-VmmHostCheckScript.ps1') {
            $t = [IO.File]::ReadAllText((Join-Path $root "VmMaintenance\Private\$f"))
            $t | Should -Match 'Wow6432Node\\Microsoft\\Microsoft SQL Server'
            $t | Should -Not -Match "-notlike 'PS\*'"
        }
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'VmMaintenance\Private\Get-VmmHostCheckScript.ps1'), [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
    }
}

Describe 'The repository template and Windows PowerShell 2.0' {
    BeforeAll {
        # Static scan: syntax and commands that Windows PowerShell 2.0 (Server 2008 R2) does not have. Returns one text per finding.
        # Get-CimInstance is allowed only inside the two readers that use it when Get-WmiObject is missing.
        function Get-Ps2Finding([string]$Code) {
            $L = 'System.Management.Automation.Language.'
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$null)
            $found = @()
            foreach ($n in $ast.FindAll({ $true }, $true)) {
                $at = 'line ' + $n.Extent.StartLineNumber + ': '
                if ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and ('' + $n.Operator) -in 'Iin', 'Inotin', 'Cin', 'Cnotin') { $found += $at + '-in/-notin' }
                if ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and ('' + $n.Operator) -in 'Shl', 'Shr') { $found += $at + '-shl/-shr' }
                if ($n -is [System.Management.Automation.Language.ConvertExpressionAst] -and $n.Type.TypeName.Name -in 'ordered', 'pscustomobject') { $found += $at + '[' + $n.Type.TypeName.Name + ']' }
                if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                    $m = '' + $n.Member
                    if ($m -in 'Where', 'ForEach', 'new', 'IsNullOrWhiteSpace', 'HasFlag', 'EnumerateFiles', 'ReadLines', 'CopyTo', 'TryParse') { $found += $at + '.' + $m + '()' }
                }
                if ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and ('' + $n.Member) -in 'Is64BitOperatingSystem', 'Is64BitProcess') { $found += $at + '.NET 4 property ' + $n.Member }
                if ($n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -in 'PSScriptRoot', 'PSCommandPath') { $found += $at + '$' + $n.VariablePath.UserPath }
                if ($n -is [System.Management.Automation.Language.TypeDefinitionAst]) { $found += $at + 'class/enum' }
                if ($n -is [System.Management.Automation.Language.CommandAst]) {
                    $c = '' + $n.GetCommandName()
                    if ($c -in 'Get-CimInstance', 'New-CimSession', 'ConvertFrom-Json', 'ConvertTo-Json', 'Get-FileHash', 'Set-Clipboard', 'Get-Clipboard', 'Get-ItemPropertyValue', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Write-Information', 'Get-NetAdapter', 'Get-NetIPAddress', 'Test-NetConnection') {
                        $p = $n.Parent
                        while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }
                        if (-not ($c -eq 'Get-CimInstance' -and $p -and $p.Name -in 'Get-Wmi', 'Get-InvProbe')) { $found += $at + $c }
                    }
                    $hasBlock = $false
                    foreach ($el in $n.CommandElements) {
                        if ($el -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $hasBlock = $true }
                        if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -in 'Raw', 'File', 'Directory', 'AdditionalChildPath', 'Depth') { $found += $at + $c + ' -' + $el.ParameterName }
                    }
                    if ($c -in 'Where-Object', 'ForEach-Object' -and -not $hasBlock) { $found += $at + $c + ' without a script block' }
                }
            }
            $found
        }
    }
    It 'the scan finds what Windows PowerShell 2.0 lacks (it is not blind)' {
        $code = "`$a = 1 -in @(1)`n`$b = [ordered]@{}`n`$c = @(1).Where({ `$_ })`n`$d = Get-ChildItem -File`n`$e = Get-Item . | Where-Object Name`nGet-CimInstance Win32_BIOS`n`$f = 256 -shr 8`n`$g = 1 -shl 8`n"
        @(Get-Ps2Finding $code).Count | Should -Be 8
    }
    It 'the Extractor code (steps code cut out, as in a snapshot build) has nothing Windows PowerShell 2.0 lacks' {
        $t = [IO.File]::ReadAllText($script:agentPath)
        $b = $t.IndexOf('# VMM-STEPS-BEGIN'); $e = $t.IndexOf('# VMM-STEPS-END')
        $b | Should -BeGreaterThan 0
        $e | Should -BeGreaterThan $b
        $snapshot = $t.Substring(0, $b) + $t.Substring($e + '# VMM-STEPS-END'.Length)
        @(Get-Ps2Finding $snapshot) | Should -BeNullOrEmpty
    }
    It 'the whole file, steps code included, has no -shl/-shr (PowerShell 3.0 operators: a parse error on 2.0 stops the whole file)' {
        $t = [IO.File]::ReadAllText($script:agentPath)
        @(Get-Ps2Finding $t | Where-Object { $_ -like '*-shl/-shr*' }) | Should -BeNullOrEmpty
    }
    It 'the repository file is the generic template: empty plan card, no key, and no address, share, e-mail or id' {
        $t = [IO.File]::ReadAllText($script:agentPath)
        @([regex]::Matches($t, "(?m)^\`$CardText = '[^']*'")).Count | Should -Be 1
        $t | Should -Match "(?m)^\`$CardText = ''   # VMM-CARD"
        $t | Should -Not -Match 'RSAKeyValue|PRIVATE KEY'
        $t | Should -Not -Match '\b(?:\d{1,3}\.){3}\d{1,3}\b'
        $t | Should -Not -Match '\\\\[A-Za-z0-9][\w\.-]*\\'
        $t | Should -Not -Match '[\w\.-]+@[\w\.-]+\.[A-Za-z]{2,}'
        $t | Should -Not -Match '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'
    }
}

Describe 'Encrypted result header (PowerShell 2.0 safe length bytes)' {
    BeforeAll {
        $fn = $script:agentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Protect-Result' }, $true) | Select-Object -First 1
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    It 'writes the wrapped key length big-endian and the laptop key can unwrap it' {
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 2048
        try {
            $script:Card = @{ PublicKey = $rsa.ToXmlString($false) }
            $line = Protect-Result 'Name=HOSTA'
            $line | Should -Match '^VMM2\|'
            $all = [Convert]::FromBase64String($line.Substring(5))
            [Text.Encoding]::ASCII.GetString($all, 0, 4) | Should -Be 'VMM2'
            $wl = ([int]$all[4] * 256) + [int]$all[5]
            $wl | Should -Be 256
            $wrapped = New-Object byte[] $wl; [Array]::Copy($all, 6, $wrapped, 0, $wl)
            $rsa.Decrypt($wrapped, $true).Length | Should -Be 64
        } finally { $rsa.Clear() }
    }
}

Describe 'Steps plan: host and age are enforced, not only shown' {
    BeforeAll {
        foreach ($name in 'Test-PlanHost', 'Get-PlanProblem') {
            $fn = $script:agentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
            if (-not $fn) { throw "Extractor function $name not found" }
            . ([scriptblock]::Create($fn.Extent.Text))
        }
        $script:Inv = [Globalization.CultureInfo]::InvariantCulture
        $script:Here = $env:COMPUTERNAME; if (-not $script:Here) { $script:Here = 'HOSTA'; $env:COMPUTERNAME = 'HOSTA' }
        $script:Fresh = [DateTime]::UtcNow.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    It 'matches short name, FQDN and a NetBIOS name cut at 15 characters, any case' {
        Test-PlanHost 'hosta' 'HOSTA' | Should -BeTrue
        Test-PlanHost 'HOSTA.corp.example.com' 'HOSTA' | Should -BeTrue
        Test-PlanHost 'SQLSERVERPROD0123' 'SQLSERVERPROD01' | Should -BeTrue
        Test-PlanHost 'HOSTB' 'HOSTA' | Should -BeFalse
        Test-PlanHost '' 'HOSTA' | Should -BeFalse
    }
    It 'a fresh plan for this host has no problem' {
        $script:Card = @{ Host = $script:Here; Generated = $script:Fresh; ValidHours = '48' }
        Get-PlanProblem | Should -Be ''
    }
    It 'a plan for another host blocks change steps' {
        $script:Card = @{ Host = 'OTHERHOST'; Generated = $script:Fresh; ValidHours = '48' }
        Get-PlanProblem | Should -Match 'not this host'
    }
    It 'an expired, undated or host-less plan blocks change steps' {
        $script:Card = @{ Host = $script:Here; Generated = [DateTime]::UtcNow.AddHours(-49).ToString('yyyy-MM-ddTHH:mm:ssZ'); ValidHours = '48' }
        Get-PlanProblem | Should -Match 'h old'
        $script:Card = @{ Host = $script:Here; Generated = ''; ValidHours = '48' }
        Get-PlanProblem | Should -Match 'no build time'
        $script:Card = @{ Host = ''; Generated = $script:Fresh; ValidHours = '48' }
        Get-PlanProblem | Should -Match 'names no host'
    }
    It 'Get-Plan, Confirm-Change, Stage and the snapshot confirmation all ask Get-PlanProblem' {
        foreach ($name in 'Get-Plan', 'Confirm-Change', 'Invoke-Stage', 'Invoke-PreSqlSnapshotConfirm') {
            $fn = $script:agentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
            $fn.Extent.Text | Should -Match 'Get-PlanProblem' -Because "$name must refuse a plan for another host"
        }
    }
    It 'Confirm-Change reads the time window again after the prompts, and never overrides disk expansion' {
        $fn = $script:agentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Confirm-Change' }, $true) | Select-Object -First 1
        @([regex]::Matches($fn.Extent.Text, 'Get-Window')).Count | Should -BeGreaterThan 1
        $fn.Extent.Text | Should -Match "ExpandDisk'\) \{ Bad"
    }
}

Describe 'Platform and work folder guards' {
    BeforeAll {
        foreach ($name in 'Get-PlatformName', 'Test-UnderTemp') {
            $fn = $script:agentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
            . ([scriptblock]::Create($fn.Extent.Text))
        }
    }
    It 'names hypervisors other than VMware/Hyper-V as OtherVirtual, not Physical' {
        Get-PlatformName 'QEMU' 'Standard PC (Q35 + ICH9, 2009)' $false | Should -Be 'OtherVirtual'
        Get-PlatformName 'Nutanix' 'AHV' $false | Should -Be 'OtherVirtual'
        Get-PlatformName 'Xen' 'HVM domU' $false | Should -Be 'OtherVirtual'
        Get-PlatformName 'VMware, Inc.' 'VMware7,1' $false | Should -Be 'VMware'
        Get-PlatformName 'Microsoft Corporation' 'Virtual Machine' $true | Should -Be 'Azure'
        Get-PlatformName 'Microsoft Corporation' 'Virtual Machine' $false | Should -Be 'Hyper-V'
        Get-PlatformName 'Dell Inc.' 'PowerEdge R740' $false | Should -Be 'Physical'
    }
    It 'Finish and the steps log only touch a work folder under C:\Temp' {
        Test-UnderTemp 'C:\Temp\VmmAgent' | Should -BeTrue
        Test-UnderTemp 'C:\Temp' | Should -BeFalse
        Test-UnderTemp 'C:\Windows' | Should -BeFalse
        Test-UnderTemp 'C:\Temp\..\Windows' | Should -BeFalse
        foreach ($name in 'Invoke-Finish', 'Initialize-WorkDir') {
            $fn = $script:agentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
            $fn.Extent.Text | Should -Match 'Test-UnderTemp'
        }
    }
    It 'the Extractor and the Fallback use the same platform list' {
        $fbPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'VmMaintenance\Resources\Fallback\VmmFallback.ps1'
        $fbAst = [System.Management.Automation.Language.Parser]::ParseFile($fbPath, [ref]$null, [ref]$null)
        $a = ($script:agentAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PlatformName' }, $true) | Select-Object -First 1).Body.Extent.Text
        $b = ($fbAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PlatformName' }, $true) | Select-Object -First 1).Body.Extent.Text
        ($a -replace 'Fallback|Extractor', 'X') | Should -Be ($b -replace 'Fallback|Extractor', 'X')
    }
}
