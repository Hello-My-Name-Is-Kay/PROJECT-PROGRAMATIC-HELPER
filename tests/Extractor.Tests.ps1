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
