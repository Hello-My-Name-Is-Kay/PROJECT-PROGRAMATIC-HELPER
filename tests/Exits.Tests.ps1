<#
    Pester 5 tests for how vmm ends: exit codes, Ctrl+C, failed and blocked steps, batch failures, the
    power-state recovery of disk expansion, lock and log failures, and the masking of text that leaves this
    laptop. No host, Azure or SQL access: Azure, the fleet store and the host calls are replaced by mocks, or
    by stand-in functions inside a separate runspace for the Ctrl+C tests.
    Run:
        Invoke-Pester -Path .\tests -Output Detailed
#>

BeforeAll {
    $script:repo = Split-Path -Path $PSScriptRoot -Parent
    $script:mod  = Import-Module (Join-Path $script:repo 'VmMaintenance\VmMaintenance.psd1') -Force -PassThru
    $script:exe  = (Get-Process -Id $PID).Path   # the same PowerShell (5.1 or 7) for the child-process tests

    function script:New-TestConfigFile {
        # A throw-away config: data, logs, reports and work folders under $Root, plaintext day log so the test can read it
        param([Parameter(Mandatory)][string]$Root)
        foreach ($d in 'data', 'reports', 'work') { New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force | Out-Null }
        $q = { param($p) "'" + ("$p" -replace "'", "''") + "'" }
        $file = Join-Path $Root 'test-config.psd1'
        Set-Content -LiteralPath $file -Encoding ASCII -Value @(
            '@{'
            "    Paths = @{ DataDir = $(& $q (Join-Path $Root 'data')); ReportDir = $(& $q (Join-Path $Root 'reports')); WorkDir = $(& $q (Join-Path $Root 'work')) }"
            '    Log   = @{ ToFile = $true; Encrypt = $false }'
            '}'
        )
        $file
    }

    function script:Invoke-TestChild {
        # Runs a script in a new PowerShell process (same version as this one) and returns its exit code and output
        param([Parameter(Mandatory)][string]$File, [string[]]$ArgumentList = @())
        $out = & $script:exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $File @ArgumentList 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    }

    function script:Read-TestDayLog {
        param([Parameter(Mandatory)][string]$Root)
        (@(Get-ChildItem -LiteralPath (Join-Path $Root 'logs') -Filter 'vmm_*.log' | Sort-Object Name | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n")
    }

    function script:Invoke-TestStoppedRun {
        # Runs $Setup and then $Run inside the module, in their own runspace. $Setup puts a stand-in command in
        # place that sets $script:TestSync.Entered and then waits; the run is stopped right there, the way Ctrl+C
        # stops it (PowerShell.Stop: catch blocks are skipped, finally blocks run). $Inspect then runs inside the
        # module and its output is returned, with the run state and the shared hashtable.
        param([Parameter(Mandatory)][scriptblock]$Setup, [Parameter(Mandatory)][scriptblock]$Run, [scriptblock]$Inspect = { }, [Parameter(Mandatory)][string]$Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $sync = [hashtable]::Synchronized(@{ Entered = $false })
        $ps = [powershell]::Create()
        try {
            # Script blocks travel as text: each runspace runs only its own script blocks
            $null = $ps.AddScript({
                param($Mod, $Root, $Sync, $SetupText, $RunText)
                $m = Import-Module $Mod -Force -PassThru
                & $m ([scriptblock]::Create($SetupText)) $Root $Sync
                & $m ([scriptblock]::Create($RunText)) $Root
            }).AddArgument((Join-Path $script:repo 'VmMaintenance\VmMaintenance.psd1')).AddArgument($Root).AddArgument($sync).AddArgument("$Setup").AddArgument("$Run")
            $h = $ps.BeginInvoke()
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not $sync.Entered -and -not $h.IsCompleted -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 50 }
            if (-not $sync.Entered) {
                $why = try { $null = $ps.EndInvoke($h); 'it ended first' } catch { $_.Exception.Message }
                throw "The run never reached the point where the test stops it: $why"
            }
            $ps.Stop()
            $state = "$($ps.InvocationStateInfo.State)"
            $ps.Commands.Clear()
            $null = $ps.AddScript({ param($t, $Root) & (Get-Module VmMaintenance) ([scriptblock]::Create($t)) $Root }).AddArgument("$Inspect").AddArgument($Root)
            [pscustomobject]@{ State = $state; Result = @($ps.Invoke()); Sync = $sync }
        } finally { $ps.Dispose() }
    }

    function script:New-TestExpandItem {
        # One row of the disk-expansion plan, as New-VmmExpandPlan returns it
        param([string]$VMName, [string]$InitialState = 'running', [switch]$Started)
        [pscustomobject]@{ ComputerName = $VMName; VMName = $VMName; MatchedBy = 'VM name'; SubscriptionId = 'sub'; ResourceGroup = 'rg'
                           InitialState = $InitialState; Sku = 'Premium_LRS'; CurrentGB = 127; NewGB = 256; Action = 'Resize'; Status = 'Ready'
                           Notes = ''; Job = $null; Started = [bool]$Started; Snapshot = $null; CBeforeGB = $null; CAfterGB = $null; FinalState = $null }
    }

    function script:New-TestError {
        # An error as the module raises it: message and error id (mock bodies cannot reach New-VmmErrorRecord)
        param([string]$Message, [string]$ErrorId, [string]$Category = 'NotSpecified')
        New-Object System.Management.Automation.ErrorRecord -ArgumentList (New-Object System.InvalidOperationException -ArgumentList $Message), $ErrorId, ([System.Management.Automation.ErrorCategory]$Category), $null
    }
}

Describe 'Exit codes: one table for vmm and the entry scripts' {
    It 'maps each error id to its exit code' {
        $r = InModuleScope VmMaintenance {
            foreach ($id in 'VmmCliUnknown', 'VmmWindowBlocked', 'VmmVpnDown', 'VmmStoreIntegrity', 'VmmAgentResultRejected', 'VmmInstanceLocked', 'VmmStepFailed', 'VmmError') {
                Get-VmmExitCode -ErrorRecord (New-VmmErrorRecord -Activity 'test' -ErrorId $id)
            }
            try { throw 'a plain error' } catch { Get-VmmExitCode -ErrorRecord $_ }
            try { throw (New-VmmErrorRecord -Activity 'thrown' -ErrorId 'VmmVpnDown') } catch { Get-VmmExitCode -ErrorRecord $_ }
        }
        ($r -join ',') | Should -Be '2,3,4,5,5,6,1,1,1,4'
    }
    It 'vmm.ps1 and every entry script end through it, and the entry scripts log and clear credentials' {
        [IO.File]::ReadAllText((Join-Path $repo 'Scripts\vmm.ps1')) | Should -Match 'Get-VmmExitCode -ErrorRecord'
        $boot = [IO.File]::ReadAllText((Join-Path $repo 'Scripts\_Bootstrap.ps1'))
        foreach ($want in 'Get-VmmExitCode -ErrorRecord', 'Clear-VmmSessionCredentialStore', 'INTERRUPTED \(Ctrl\+C\)', 'exit \$code') { $boot | Should -Match $want }
        $missing = foreach ($f in Get-ChildItem -LiteralPath (Join-Path $repo 'Scripts') -Filter '*.ps1') {
            if ($f.Name -in '_Bootstrap.ps1', 'vmm.ps1') { continue }
            if ([IO.File]::ReadAllText($f.FullName) -notmatch "(?m)^Invoke-VmmEntryScript -Command '[\w-]+' -Parameters \`$PSBoundParameters") { $f.Name }
        }
        $missing | Should -BeNullOrEmpty
    }
    It 'vmm.ps1 exits 2 for an unknown command and 6 while another vmm holds the lock, and logs the exit code' {
        $root = Join-Path $TestDrive 'vmmexit'
        $cfg = New-TestConfigFile -Root $root
        $vmm = Join-Path $repo 'Scripts\vmm.ps1'
        $r = Invoke-TestChild -File $vmm -ArgumentList '--config', $cfg, '--no-color', 'nosuchcommand'
        $r.Code | Should -Be 2
        $r.Out | Should -Match "Unknown command 'nosuchcommand'"
        $fs = New-Object System.IO.FileStream((Join-Path $root 'data\vmm.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $r = Invoke-TestChild -File $vmm -ArgumentList '--config', $cfg, '--no-color', 'remove', '-Name', 'x'
        } finally { $fs.Dispose() }
        $r.Code | Should -Be 6
        $r.Out | Should -Match 'vmm is already running'
        $log = Read-TestDayLog -Root $root
        $log | Should -Match '\|ERROR\|vmm nosuchcommand exit code 2: Unknown command'
        $log | Should -Match '\|ERROR\|vmm remove exit code 6: vmm is already running'
    }
    It 'an entry script exits 3 when the time window blocks it and 0 when it worked, and logs both' {
        $root = Join-Path $TestDrive 'entry'
        $cfg = New-TestConfigFile -Root $root
        $script = Join-Path $root 'Test-Entry.ps1'
        Set-Content -LiteralPath $script -Encoding ASCII -Value @(
            'param([switch]$Block)'
            "`$ConfigPath = '$($cfg -replace "'", "''")'"
            ". '$((Join-Path $repo 'Scripts\_Bootstrap.ps1') -replace "'", "''")'"
            'function Test-VmmEntry { param([switch]$Block) if ($Block) { throw (& (Get-Module VmMaintenance) { New-VmmErrorRecord -Activity ''Blocked by the test time window.'' -Category PermissionDenied -ErrorId ''VmmWindowBlocked'' }) }; ''worked'' }'
            'Invoke-VmmEntryScript -Command ''Test-VmmEntry'' -Parameters $PSBoundParameters -Name ''Test-Entry.ps1'''
        )
        $r = Invoke-TestChild -File $script -ArgumentList '-Block'
        $r.Code | Should -Be 3
        $r.Out | Should -Match 'ERROR: Blocked by the test time window'
        $r = Invoke-TestChild -File $script
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'worked'
        $log = Read-TestDayLog -Root $root
        $log | Should -Match '\|MUTED\|Script: Test-Entry\.ps1'
        $log | Should -Match '\|ERROR\|Test-Entry\.ps1 failed: Blocked by the test time window\. \[VmmWindowBlocked'
        $log | Should -Match '\|ERROR\|Test-Entry\.ps1 FAILED, exit code 3 after [\d\.,]+ s'
        $log | Should -Match '\|MUTED\|Test-Entry\.ps1 done after [\d\.,]+ s'
    }
}

Describe 'Ctrl+C leaves an honest trace' {
    It 'vmm step: INTERRUPTED in the log, the step recorded as Failed, lock released, credentials cleared' {
        $root = Join-Path $TestDrive 'stop-step'
        $r = Invoke-TestStoppedRun -Root $root -Setup {
            param($Root, $Sync)
            $script:VmmConfig = @{ Log = @{ ToFile = $false }; Paths = @{ DataDir = (Join-Path $Root 'data'); ReportDir = (Join-Path $Root 'reports') } }
            $script:TestSync = $Sync
            $rec = New-VmmHostRecord -Name 'stop-host'
            Set-VmmStepState -Record $rec -Step 'Precheck' -Status 'Success'
            $script:TestStore = [pscustomobject]@{ Updated = $null; Hosts = @($rec) }
            function script:Read-VmmStore { $script:TestStore }
            function script:Save-VmmStore { param($Store) }
            function script:Assert-VmmWindow { }
            function script:Get-VmmHostPolicy { param($Record) [pscustomobject]@{ Workable = $true; Warnings = @(); Scope = 'Server'; Os = 'test'; Why = '' } }
            function script:Copy-VmmStagingPackage { param($HostName) $script:TestSync.Entered = $true; Start-Sleep -Seconds 120 }
            $s = New-Object System.Security.SecureString; $s.AppendChar('x')
            $script:VmmCredentials = @{ Windows = New-Object System.Management.Automation.PSCredential -ArgumentList 'test', $s }
        } -Run {
            Invoke-VmmCli -Command step -Arguments @('-HostName', 'stop-host', '-Step', 'Stage')
        } -Inspect {
            param($Root)
            [pscustomobject]@{
                Log   = (@($script:VmmLogBuffer | ForEach-Object { "$($_.Level)|$($_.Text)" }) -join "`n")
                Step  = $script:TestStore.Hosts[0].Steps.Stage
                Lock  = [bool]$script:VmmInstanceLock
                Owner = Test-Path -LiteralPath (Join-Path $Root 'data\vmm.lock.txt')
                Creds = @($script:VmmCredentials.Keys).Count
            }
        }
        $r.State | Should -Be 'Stopped'
        $o = $r.Result[0]
        $o.Log | Should -Match 'Error\|\[STOP-HOST\] Stage INTERRUPTED \(Ctrl\+C\) after \d+ s: result not recorded'
        $o.Log | Should -Match 'Error\|vmm step -HostName -Step INTERRUPTED \(Ctrl\+C\) after [\d\.,]+ s'
        $o.Log | Should -Not -Match 'step -HostName -Step done in'
        $o.Step.Status | Should -Be 'Failed'
        $o.Step.Note | Should -Match 'INTERRUPTED \(Ctrl\+C\) after \d+ s, before the result was known: check the host before running Stage again'
        $o.Lock | Should -BeFalse
        $o.Owner | Should -BeFalse
        $o.Creds | Should -Be 0
    }
    It 'a staging copy stopped with Ctrl+C leaves no .part file and no destination file' {
        $root = Join-Path $TestDrive 'stop-copy'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $root 'src.bin'), [byte[]](1..255))
        $r = Invoke-TestStoppedRun -Root $root -Setup {
            param($Root, $Sync)
            $script:VmmConfig = @{ Log = @{ ToFile = $false } }
            $script:TestSync = $Sync
            # Stand-in for the final rename: the whole file is in <dest>.part when Ctrl+C comes
            function script:Move-Item { $script:TestSync.Entered = $true; Start-Sleep -Seconds 120 }
        } -Run {
            param($Root)
            Copy-VmmFileWithProgress -Source (Join-Path $Root 'src.bin') -Destination (Join-Path $Root 'dest.bin')
        }
        $r.State | Should -Be 'Stopped'
        Join-Path $root 'dest.bin.part' | Should -Not -Exist
        Join-Path $root 'dest.bin' | Should -Not -Exist
    }
    It 'disk expansion stopped after the VMs went down: the recovery runs and the results are written' {
        $root = Join-Path $TestDrive 'stop-expand'
        $r = Invoke-TestStoppedRun -Root $root -Setup {
            param($Root, $Sync)
            $script:VmmConfig = @{ Log = @{ ToFile = $false } }
            $script:TestSync = $Sync
            function script:Read-VmmServerList { 'srv-stop' }
            function script:Start-Transcript { }
            function script:Stop-Transcript { }
            function script:Assert-VmmModule { }
            function script:Connect-VmmAzure { }
            function script:Assert-VmmWindow { }
            function script:Set-VmmSubscription { }
            function script:New-VmmExpandPlan {
                [pscustomobject]@{ ComputerName = 'srv-stop'; VMName = 'vm-stop'; MatchedBy = 'VM name'; SubscriptionId = 'sub'; ResourceGroup = 'rg'; InitialState = 'running'; Sku = 'Premium_LRS'
                                   CurrentGB = 127; NewGB = 256; Action = 'Resize'; Status = 'Ready'; Notes = ''; Job = $null; Started = $false; Snapshot = $null; CBeforeGB = $null; CAfterGB = $null; FinalState = $null }
            }
            function script:Stop-AzVM { 'job' }
            function script:Wait-VmmJob { param($Item, $Label) if ($Label -eq 'Deallocate') { $script:TestSync.Entered = $true; Start-Sleep -Seconds 120 } }
            function script:Invoke-VmmPowerRecovery { param($Item) $script:TestSync.Recovered = (@($Item | ForEach-Object VMName) -join ',') }
        } -Run {
            param($Root)
            $name = 'srv-stop'
            Expand-VmmOsDisk -ComputerName $name -Apply -Confirm:$false -TenantId 'test' -SnapshotTags @{ Purpose = 'test' } -LogDir (Join-Path $Root 'expand')
        } -Inspect {
            (@($script:VmmLogBuffer | ForEach-Object { "$($_.Level)|$($_.Text)" }) -join "`n")
        }
        $r.State | Should -Be 'Stopped'
        $r.Sync.Recovered | Should -Be 'vm-stop'
        $r.Result[0] | Should -Match 'Error\|Disk expansion stopped half way; results: vm-stop=Ready/'
        @(Get-ChildItem -LiteralPath (Join-Path $root 'expand') -Filter 'Results_*.csv').Count | Should -Be 1
    }
}

Describe 'A failed or blocked step is recorded, then raised' {
    BeforeAll {
        InModuleScope VmMaintenance { $script:SavedCfgStep = $script:VmmConfig; $script:VmmConfig = @{ Log = @{ ToFile = $false } } }
    }
    AfterAll { InModuleScope VmMaintenance { $script:VmmConfig = $script:SavedCfgStep } }
    BeforeEach {
        $script:StepStore = InModuleScope VmMaintenance { [pscustomobject]@{ Updated = $null; Hosts = @(New-VmmHostRecord -Name 'step-host') } }
        Mock -ModuleName VmMaintenance Read-VmmStore { $script:StepStore }
        Mock -ModuleName VmMaintenance Save-VmmStore { }
        Mock -ModuleName VmMaintenance Assert-VmmWindow { }
    }
    It 'a failure is recorded as Failed and ends with VmmStepFailed (exit code 1)' {
        Mock -ModuleName VmMaintenance Invoke-VmmFleetCheck { throw 'WinRM timed out after 30 s' }
        $err = $null
        try { Invoke-VmmWorkflowStep -HostName 'step-host' -Step Precheck } catch { $err = $_ }
        "$($err.FullyQualifiedErrorId)" | Should -BeLike 'VmmStepFailed*'
        $err.Exception.Message | Should -Match 'Precheck on STEP-HOST FAILED \(recorded as Failed\)'
        $err.Exception.Message | Should -Match 'WinRM timed out'
        $script:StepStore.Hosts[0].Steps.Precheck.Status | Should -Be 'Failed'
        $script:StepStore.Hosts[0].Steps.Precheck.Note | Should -Match 'WinRM timed out'
        InModuleScope VmMaintenance -Parameters @{ E = $err } { Get-VmmExitCode -ErrorRecord $E } | Should -Be 1
        Should -Invoke -ModuleName VmMaintenance Save-VmmStore -Times 1 -Exactly
    }
    It 'missing access writes the blocker report and ends with VmmStepBlocked' {
        Mock -ModuleName VmMaintenance Invoke-VmmFleetCheck { throw 'Access is denied. (0x80070005)' }
        Mock -ModuleName VmMaintenance New-VmmBlockerReport { 'Blockers\STEP-HOST_Precheck.txt' }
        $err = $null
        try { Invoke-VmmWorkflowStep -HostName 'step-host' -Step Precheck -Contact Later } catch { $err = $_ }
        "$($err.FullyQualifiedErrorId)" | Should -BeLike 'VmmStepBlocked*'
        $err.Exception.Message | Should -Match 'STEP-HOST_Precheck\.txt'
        Should -Invoke -ModuleName VmMaintenance New-VmmBlockerReport -Times 1 -Exactly -ParameterFilter { $HostName -eq 'STEP-HOST' -and $Step -eq 'Precheck' -and $Contact -eq 'Later' }
    }
    It 'VPN down keeps its own error (exit code 4) and is still recorded as Failed' {
        Mock -ModuleName VmMaintenance Invoke-VmmFleetCheck { throw (New-TestError -Message 'The VPN is not connected.' -ErrorId 'VmmVpnDown' -Category ConnectionError) }
        $err = $null
        try { Invoke-VmmWorkflowStep -HostName 'step-host' -Step Precheck } catch { $err = $_ }
        "$($err.FullyQualifiedErrorId)" | Should -BeLike 'VmmVpnDown*'
        $script:StepStore.Hosts[0].Steps.Precheck.Status | Should -Be 'Failed'
        InModuleScope VmMaintenance -Parameters @{ E = $err } { Get-VmmExitCode -ErrorRecord $E } | Should -Be 4
    }
    It 'vmm next runs every host, then fails naming the ones that did not succeed (VmmNextStepFailed)' {
        Mock -ModuleName VmMaintenance Get-VmmQueue {
            foreach ($h in 'NEXT-A', 'NEXT-B', 'NEXT-C') { [pscustomobject]@{ Host = $h; Step = [pscustomobject]@{ Name = 'Precheck' }; Allowed = $true; Guided = $false; State = 'Ready' } }
        }
        Mock -ModuleName VmMaintenance Invoke-VmmWorkflowStep {
            if ($HostName -eq 'NEXT-B') { throw (New-TestError -Message 'Precheck on NEXT-B FAILED (recorded as Failed).' -ErrorId 'VmmStepFailed') }
        }
        $err = $null
        try { Invoke-VmmNextStep -All } catch { $err = $_ }
        Should -Invoke -ModuleName VmMaintenance Invoke-VmmWorkflowStep -Times 3 -Exactly
        "$($err.FullyQualifiedErrorId)" | Should -BeLike 'VmmNextStepFailed*'
        $err.Exception.Message | Should -Match '1 of 3 step\(s\) did not succeed \(0 blocked, 1 failed\)'
        $err.Exception.Message | Should -Match 'NEXT-B/Precheck'
    }
}

Describe 'Stage copies through the admin-share drive and checks every file' {
    BeforeAll {
        InModuleScope VmMaintenance { $script:SavedCfgStage = $script:VmmConfig; $script:VmmConfig = @{ Log = @{ ToFile = $false } } }
    }
    AfterAll { InModuleScope VmMaintenance { $script:VmmConfig = $script:SavedCfgStage } }
    BeforeEach {
        $script:FakeC = Join-Path $TestDrive ('hostC-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:FakeC -Force | Out-Null
        $script:Src = Join-Path $TestDrive 'share-pkg.bin'
        [IO.File]::WriteAllBytes($script:Src, [byte[]](1..200))
        $script:SrcSha = (Get-FileHash -LiteralPath $script:Src -Algorithm SHA256).Hash
        $script:StageStore = InModuleScope VmMaintenance { [pscustomobject]@{ Updated = $null; Hosts = @(New-VmmHostRecord -Name 'stage-host') } }
        Mock -ModuleName VmMaintenance Read-VmmStore { $script:StageStore }
        Mock -ModuleName VmMaintenance Test-VmmStagingSource { [pscustomobject]@{ Name = 'pkg.bin'; File = $script:Src; DestName = 'pkg.bin'; Sha256 = $script:SrcSha; SizeMB = 0; Gate = $null; Note = $null } }
        Mock -ModuleName VmMaintenance Assert-VmmVpn { }
        Mock -ModuleName VmMaintenance Get-VmmSessionCredential { $null }
        # The host's C$ share is a local folder here; Stage maps it as a PowerShell drive, as it does for a real host
        Mock -ModuleName VmMaintenance New-PSDrive { Microsoft.PowerShell.Management\New-PSDrive -Name $Name -PSProvider FileSystem -Root $script:FakeC -Scope Global }
    }
    AfterEach { Get-PSDrive -Name 'VmmStage*' -ErrorAction SilentlyContinue | Remove-PSDrive -Force -ErrorAction SilentlyContinue }
    It 'copies into C:\Temp on the host through the drive, verified, with no .part file and nothing written elsewhere' {
        $cwd = [Environment]::CurrentDirectory
        $before = @(Get-ChildItem -LiteralPath $cwd -Force | ForEach-Object Name)
        @(Copy-VmmStagingPackage -HostName 'stage-host') | Should -Be 'pkg.bin'
        $dest = Join-Path $script:FakeC 'Temp\pkg.bin'
        (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash | Should -Be $script:SrcSha
        "$dest.part" | Should -Not -Exist
        @(Get-ChildItem -LiteralPath $cwd -Force | ForEach-Object Name | Where-Object { $_ -notin $before }) | Should -BeNullOrEmpty
        @(Get-PSDrive -Name 'VmmStage*' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
    It 'a same-size file with the wrong SHA256 on the host is copied again' {
        New-Item -ItemType Directory -Path (Join-Path $script:FakeC 'Temp') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $script:FakeC 'Temp\pkg.bin'), [byte[]](200..1))   # right size, wrong content
        InModuleScope VmMaintenance { $script:VmmLogBuffer = $null }
        @(Copy-VmmStagingPackage -HostName 'stage-host') | Should -Be 'pkg.bin'
        (Get-FileHash -LiteralPath (Join-Path $script:FakeC 'Temp\pkg.bin') -Algorithm SHA256).Hash | Should -Be $script:SrcSha
        (InModuleScope VmMaintenance { @($script:VmmLogBuffer | ForEach-Object Text) -join "`n" }) | Should -Match 'right size but the wrong SHA256: copying it again'
    }
    It 'a copy that arrives corrupt is deleted and ends with VmmHashMismatch' {
        Mock -ModuleName VmMaintenance Copy-VmmFileWithProgress { Microsoft.PowerShell.Management\Set-Content -LiteralPath $Destination -Value 'corrupt' -NoNewline }
        { Copy-VmmStagingPackage -HostName 'stage-host' } | Should -Throw -ErrorId 'VmmHashMismatch*'
        Join-Path $script:FakeC 'Temp\pkg.bin' | Should -Not -Exist
    }
    It 'a copy that fails at the end leaves no .part file and no destination file' {
        Mock -ModuleName VmMaintenance Move-Item { throw 'There is not enough space on the disk.' }
        $dest = Join-Path $TestDrive 'end-fail.bin'
        { InModuleScope VmMaintenance -Parameters @{ S = $script:Src; D = $dest } { Copy-VmmFileWithProgress -Source $S -Destination $D } } | Should -Throw '*not enough space*'
        "$dest.part" | Should -Not -Exist
        $dest | Should -Not -Exist
    }
}

Describe 'Disk expansion never leaves a VM down' {
    BeforeAll {
        # Az is not needed: stand-ins that the mocks replace
        function global:Start-AzVM { [CmdletBinding()] param($ResourceGroupName, $Name, [switch]$AsJob) }
        function global:Stop-AzVM { [CmdletBinding()] param($ResourceGroupName, $Name, [switch]$Force, [switch]$StayProvisioned, [switch]$AsJob) }
        InModuleScope VmMaintenance { $script:SavedCfgExp = $script:VmmConfig; $script:VmmConfig = @{ Log = @{ ToFile = $false } } }
    }
    AfterAll {
        Remove-Item -Path function:global:Start-AzVM, function:global:Stop-AzVM -ErrorAction SilentlyContinue
        InModuleScope VmMaintenance { $script:VmmConfig = $script:SavedCfgExp }
    }
    Context 'Expand-VmmOsDisk' {
        BeforeEach {
            $script:ExpName = 'srv-exp'
            Mock -ModuleName VmMaintenance Read-VmmServerList { 'srv-exp' }
            Mock -ModuleName VmMaintenance Start-Transcript { }
            Mock -ModuleName VmMaintenance Stop-Transcript { }
            Mock -ModuleName VmMaintenance Assert-VmmModule { }
            Mock -ModuleName VmMaintenance Connect-VmmAzure { }
            Mock -ModuleName VmMaintenance Assert-VmmWindow { }
            Mock -ModuleName VmMaintenance Set-VmmSubscription { }
            Mock -ModuleName VmMaintenance New-VmmExpandPlan { New-TestExpandItem -VMName 'vm-exp' -InitialState 'running' }
            Mock -ModuleName VmMaintenance Invoke-VmmPowerRecovery { }
            Mock -ModuleName VmMaintenance Stop-AzVM { 'job' }
        }
        It 'an unexpected error after the VMs went down runs the recovery, writes the results, and is raised' {
            Mock -ModuleName VmMaintenance Wait-VmmJob { throw 'Azure answered 500 Internal Server Error' }
            $log = Join-Path $TestDrive 'exp-error'
            { Expand-VmmOsDisk -ComputerName $script:ExpName -Apply -Confirm:$false -TenantId 'test' -SnapshotTags @{ Purpose = 'test' } -LogDir $log } | Should -Throw '*500 Internal Server Error*'
            Should -Invoke -ModuleName VmMaintenance Invoke-VmmPowerRecovery -Times 1 -Exactly -ParameterFilter { @($Item).Count -eq 1 -and $Item[0].VMName -eq 'vm-exp' }
            @(Get-ChildItem -LiteralPath $log -Filter 'Results_*.csv').Count | Should -Be 1
        }
        It 'a plan-only run changes nothing and needs no recovery' {
            $log = Join-Path $TestDrive 'exp-plan'
            $r = @(Expand-VmmOsDisk -ComputerName $script:ExpName -TenantId 'test' -LogDir $log -PassThru)
            $r[0].VMName | Should -Be 'vm-exp'
            Should -Invoke -ModuleName VmMaintenance Stop-AzVM -Times 0 -Exactly
            Should -Invoke -ModuleName VmMaintenance Invoke-VmmPowerRecovery -Times 0 -Exactly
            @(Get-ChildItem -LiteralPath $log -Filter 'Plan_*.csv').Count | Should -Be 1
        }
    }
    Context 'Invoke-VmmPowerRecovery' {
        BeforeEach {
            Mock -ModuleName VmMaintenance Set-VmmSubscription { }
            Mock -ModuleName VmMaintenance Wait-VmmJob { }
            Mock -ModuleName VmMaintenance Get-VmmPowerState { $script:Power[$VMName] }
        }
        It 'starts the VMs that were running and switches off again the off VMs the run had started' {
            $script:Power = @{ 'vm-run' = 'deallocated'; 'vm-off' = 'running'; 'vm-stopped' = 'running'; 'vm-quiet' = 'deallocated' }
            Mock -ModuleName VmMaintenance Start-AzVM { $script:Power[$Name] = 'running'; 'job' }
            Mock -ModuleName VmMaintenance Stop-AzVM { $script:Power[$Name] = $(if ($StayProvisioned) { 'stopped' } else { 'deallocated' }); 'job' }
            $items = @(
                (New-TestExpandItem -VMName 'vm-run' -InitialState 'running')
                (New-TestExpandItem -VMName 'vm-off' -InitialState 'deallocated' -Started)
                (New-TestExpandItem -VMName 'vm-stopped' -InitialState 'stopped' -Started)
                (New-TestExpandItem -VMName 'vm-quiet' -InitialState 'deallocated')
            )
            $log = InModuleScope VmMaintenance -Parameters @{ I = $items } {
                $script:VmmLogBuffer = $null
                Invoke-VmmPowerRecovery -Item $I -WaitSeconds 1
                @($script:VmmLogBuffer | ForEach-Object { "$($_.Level)|$($_.Text)" }) -join "`n"
            }
            Should -Invoke -ModuleName VmMaintenance Start-AzVM -Times 1 -Exactly
            Should -Invoke -ModuleName VmMaintenance Start-AzVM -Times 1 -Exactly -ParameterFilter { $Name -eq 'vm-run' }
            Should -Invoke -ModuleName VmMaintenance Stop-AzVM -Times 2 -Exactly
            Should -Invoke -ModuleName VmMaintenance Stop-AzVM -Times 1 -Exactly -ParameterFilter { $Name -eq 'vm-off' -and -not $StayProvisioned }
            Should -Invoke -ModuleName VmMaintenance Stop-AzVM -Times 1 -Exactly -ParameterFilter { $Name -eq 'vm-stopped' -and $StayProvisioned }
            (@($items | ForEach-Object FinalState) -join ',') | Should -Be 'running,deallocated,stopped,deallocated'
            $items[0].Notes | Should -Match 'RUN STOPPED: recovery put the power state back'
            $log | Should -Match 'Success\|\[Recovery\] every VM is back in its power state from before the run'
        }
        It 'names a VM it could not put back, to fix in the Azure portal' {
            $script:Power = @{ 'vm-run' = 'deallocated' }
            Mock -ModuleName VmMaintenance Start-AzVM { throw 'AuthorizationFailed: no permission to start the VM' }
            $items = @(New-TestExpandItem -VMName 'vm-run' -InitialState 'running')
            $log = InModuleScope VmMaintenance -Parameters @{ I = $items } {
                $script:VmmLogBuffer = $null
                Invoke-VmmPowerRecovery -Item $I -WaitSeconds 1
                @($script:VmmLogBuffer | ForEach-Object { "$($_.Level)|$($_.Text)" }) -join "`n"
            }
            $log | Should -Match 'Error\|\[Recovery\] put these back in the Azure portal NOW: vm-run \(deallocated, was running\)'
            $items[0].Notes | Should -Match 'RECOVERY failed'
            $items[0].Notes | Should -Match 'RUN STOPPED: recovery could not put the power state back \(deallocated, was running\)'
        }
    }
}

Describe 'Batch commands finish every item, then fail when one failed' {
    BeforeAll {
        InModuleScope VmMaintenance { $script:SavedCfgBatch = $script:VmmConfig; $script:VmmConfig = @{ Log = @{ ToFile = $false } } }
    }
    AfterAll { InModuleScope VmMaintenance { $script:VmmConfig = $script:SavedCfgBatch } }
    It 'prune goes through every subscription, then fails with VmmPruneIncomplete' {
        Mock -ModuleName VmMaintenance Read-VmmStore {
            [pscustomobject]@{ Hosts = @([pscustomobject]@{ Name = 'A'; Azure = [pscustomobject]@{ SubscriptionId = 'sub-one' } }, [pscustomobject]@{ Name = 'B'; Azure = [pscustomobject]@{ SubscriptionId = 'sub-two' } }) }
        }
        Mock -ModuleName VmMaintenance Remove-VmmExpiredSnapshot {
            if ($PassThru) { [pscustomobject]@{ Action = 'WouldDelete'; Snapshot = "snap-$Subscription"; ResourceGroup = 'rg'; AgeDays = 40; RetentionDays = 30 } }
            elseif ($Subscription -eq 'sub-one') { throw 'snap-sub-one could not be deleted: ScopeLocked' }
        }
        Mock -ModuleName VmMaintenance Assert-VmmWindow { }
        { Invoke-VmmPrune -Apply -Confirm:$false } | Should -Throw -ErrorId 'VmmPruneIncomplete*'
        Should -Invoke -ModuleName VmMaintenance Remove-VmmExpiredSnapshot -Times 2 -Exactly -ParameterFilter { -not $PassThru }
    }
    It 'the inbox import keeps a file it could not import and fails with VmmInboxFailed (unless -Quiet or -PassThru)' {
        $dir = Join-Path $TestDrive 'inbox'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $f = Join-Path $dir 'VMM_PESTER_20261116-010000.vmm'
        Set-Content -LiteralPath $f -Value 'not a result line'
        { Import-VmmResultInbox -Path $dir } | Should -Throw -ErrorId 'VmmInboxFailed*'
        $f | Should -Exist
        @((Import-VmmResultInbox -Path $dir -PassThru).Failed).Count | Should -Be 1
        { Import-VmmResultInbox -Path $dir -Quiet } | Should -Not -Throw
    }
    It 'every batch command and tool names its own failure error' {
        $want = [ordered]@{
            'Public\Mount-VmmUpgradeMedia.ps1' = 'VmmMediaIncomplete'; 'Public\Dismount-VmmUpgradeMedia.ps1' = 'VmmMediaIncomplete'
            'Public\Remove-VmmExpiredSnapshot.ps1' = 'VmmPruneIncomplete'; 'Public\Invoke-VmmPrune.ps1' = 'VmmPruneIncomplete'
            'Public\New-VmmDiskFromSnapshot.ps1' = 'VmmRestoreDiskIncomplete'; 'Public\Save-VmmSqlUpdate.ps1' = 'VmmFetchIncomplete'
            'Public\New-VmmSnapshot.ps1' = 'VmmSnapshotIncomplete'; 'Public\Expand-VmmOsDisk.ps1' = 'VmmExpandIncomplete'
            'Public\Start-VmmRemoteHandoff.ps1' = 'VmmHandoffNotVerified'; 'Public\Connect-VmmVpn.ps1' = 'VmmVpnDown'
            'Public\Invoke-VmmNextStep.ps1' = 'VmmNextStepFailed'; 'Public\Import-VmmResultInbox.ps1' = 'VmmInboxFailed'
            'Public\Invoke-VmmMaintenance.ps1' = 'VmmCleanIncomplete'; 'Public\Import-VmmFleet.ps1' = 'VmmSourceNotRemoved'
            'Public\Invoke-VmmWorkflowStep.ps1' = 'VmmStepFailed'; 'Private\Enter-VmmInstanceLock.ps1' = 'VmmInstanceLockFile'
        }
        $missing = foreach ($k in $want.Keys) {
            if ([IO.File]::ReadAllText((Join-Path $repo "VmMaintenance\$k")) -notmatch ("'" + $want[$k] + "'")) { "$k ($($want[$k]))" }
        }
        $missing | Should -BeNullOrEmpty
    }
    It 'Extractor: -Finish and -Extract exit 1 when they did not finish' {
        $t = [IO.File]::ReadAllText((Join-Path $repo 'VmMaintenance\Resources\VmmHostAgent.ps1'))
        $t | Should -Match 'if \(\$Finish\) \{ if \(-not \(Invoke-Finish -Force\)\) \{ exit 1 \}; return \}'
        $t | Should -Match 'if \(\$Extract\) \{ \$Script:LastResultFile = \$null; Export-Result -Auto; if \(-not \$Script:LastResultFile\) \{ exit 1 \}; return \}'
    }
    It 'the leak scan with -History fails outside a git clone instead of passing unchecked' {
        $copy = Join-Path $TestDrive 'leak'
        New-Item -ItemType Directory -Path $copy -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo 'Tools'), (Join-Path $repo 'VmMaintenance') -Destination $copy -Recurse
        $r = Invoke-TestChild -File (Join-Path $copy 'Tools\Test-Sanitized.ps1') -ArgumentList '-History'
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'Not a git repository|git not found'
    }
}

Describe 'Text that leaves the laptop (AI, GitHub issue) is masked' {
    BeforeAll {
        InModuleScope VmMaintenance {
            $script:SavedCfgAi = $script:VmmConfig
            $script:VmmConfig = @{ Log = @{ ToFile = $false }; Azure = @{ Subscription = 'Pester Subscription Name' }; Reports = @{ ManagerName = 'Pat Pester' }
                                   Lansweeper = @{ SqlInstance = 'SQLPESTER\LANSWEEPER' } }
        }
    }
    AfterAll { InModuleScope VmMaintenance { $script:VmmConfig = $script:SavedCfgAi } }
    It 'masks ids, Azure resource ids, config values, domains, resource groups, VM and host names' {
        Mock -ModuleName VmMaintenance Read-VmmStore {
            [pscustomobject]@{ Hosts = @([pscustomobject]@{ Name = 'SRVPESTER1'; Fqdn = 'srvpester1.corp-pester.example'
                                                            Azure = [pscustomobject]@{ ResourceGroup = 'rg-pester-app'; VMName = 'vm-pester-one'; SubscriptionId = 'x' } }) }
        }
        $g = [guid]::NewGuid().ToString()
        $text = "Tenant $($g): srvpester1.corp-pester.example failed. VM vm-pester-one in rg-pester-app, /subscriptions/$g/resourceGroups/rg-pester-app/providers/Microsoft.Compute/virtualMachines/vm-pester-one. " +
                "Subscription 'Pester Subscription Name', SQL SQLPESTER\LANSWEEPER, manager Pat Pester, from 127.0.0.1, mail pat@example.com, also SRVPESTER1 in corp-pester.example"
        $r = InModuleScope VmMaintenance -Parameters @{ T = $text } { ConvertTo-VmmAiSafeText -Text $T }
        foreach ($leak in $g, 'srvpester1', 'corp-pester', 'vm-pester-one', 'rg-pester-app', 'Pester Subscription Name', 'SQLPESTER', 'Pat Pester', '127.0.0.1', 'pat@example.com') {
            $r.Text | Should -Not -Match ([regex]::Escape($leak))
        }
        $r.Text | Should -Match 'HOST01'
        $r.Map['SRVPESTER1'] | Should -Be 'HOST01'
    }
    It 'fails closed (VmmAiUnsafe) when the fleet store cannot be read' {
        Mock -ModuleName VmMaintenance Read-VmmStore { throw 'The fleet store failed its integrity check.' }
        { InModuleScope VmMaintenance { ConvertTo-VmmAiSafeText -Text 'srvpester1 is down' } } | Should -Throw -ErrorId 'VmmAiUnsafe*'
    }
}

Describe 'Lock and log problems are named, never hidden' {
    It 'a lock file that cannot be opened is VmmInstanceLockFile, not "vmm is already running"' {
        $data = Join-Path $TestDrive 'lockbad'
        New-Item -ItemType Directory -Path (Join-Path $data 'vmm.lock') -Force | Out-Null   # a folder where the lock file belongs
        $r = InModuleScope VmMaintenance -Parameters @{ D = $data } {
            $saved = $script:VmmConfig
            Exit-VmmInstanceLock
            $script:VmmConfig = @{ Log = @{ ToFile = $false }; Paths = @{ DataDir = $D; ReportDir = $D } }
            try { Enter-VmmInstanceLock | Out-Null; 'no error' }
            catch { "$($_.FullyQualifiedErrorId)|$($_.Exception.Message)" }
            finally { Exit-VmmInstanceLock; $script:VmmConfig = $saved }
        }
        $r | Should -Match '^VmmInstanceLockFile'
        $r | Should -Match 'Could not open the single-instance lock file'
        $r | Should -Not -Match 'already running'
    }
    It 'a log file that cannot be written is reported once, and every line stays in the on-screen log' {
        $root = Join-Path $TestDrive 'logbad'
        New-Item -ItemType Directory -Path (Join-Path $root 'data') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'logs') -Value 'a file where the logs folder belongs'
        $r = InModuleScope VmMaintenance -Parameters @{ R = $root } {
            $saved = $script:VmmConfig; $savedErr = $script:VmmLogFileError
            $script:VmmConfig = @{ Log = @{ ToFile = $true; Encrypt = $false }; Paths = @{ DataDir = (Join-Path $R 'data'); ReportDir = (Join-Path $R 'reports') } }
            $script:VmmLogFileError = $null; $script:VmmLogBuffer = $null; $script:VmmLogPending = $null
            try {
                $w = @(Add-VmmLogEntry -Text 'first line' -Level Info 3>&1) + @(Add-VmmLogEntry -Text 'second line' -Level Info 3>&1)
                [pscustomobject]@{
                    Warnings = @($w | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count
                    Buffer   = (@($script:VmmLogBuffer | ForEach-Object { "$($_.Level)|$($_.Text)" }) -join "`n")
                }
            } finally { $script:VmmConfig = $saved; $script:VmmLogFileError = $savedErr; $script:VmmLogPending = $null }
        }
        $r.Warnings | Should -Be 1
        $r.Buffer | Should -Match 'Info\|first line'
        $r.Buffer | Should -Match 'Info\|second line'
        $r.Buffer | Should -Match 'Error\|Log file not written'
    }
    It 'a line logged while another line is being written is written after it, not dropped' {
        $root = Join-Path $TestDrive 'lognest'
        $r = InModuleScope VmMaintenance -Parameters @{ R = $root } {
            $saved = $script:VmmConfig; $savedErr = $script:VmmLogFileError
            $script:VmmConfig = @{ Log = @{ ToFile = $true; Encrypt = $false }; Paths = @{ DataDir = (Join-Path $R 'data'); ReportDir = (Join-Path $R 'reports') } }
            $script:VmmLogFileError = $null; $script:VmmLogPending = $null
            try {
                $script:VmmLogWriting = $true            # as if a line were being written (config load, key creation)
                Add-VmmLogEntry -Text 'nested line' -Level Muted
                $script:VmmLogWriting = $false
                Add-VmmLogEntry -Text 'outer line' -Level Info
                @(Get-ChildItem -LiteralPath (Join-Path $R 'logs') -Filter 'vmm_*.log' | Sort-Object Name | ForEach-Object { Get-Content -LiteralPath $_.FullName }) -join "`n"
            } finally { $script:VmmConfig = $saved; $script:VmmLogFileError = $savedErr; $script:VmmLogWriting = $false; $script:VmmLogPending = $null }
        }
        $r | Should -Match '(?s)\|MUTED\|nested line.*\|INFO\|outer line'
    }
}
