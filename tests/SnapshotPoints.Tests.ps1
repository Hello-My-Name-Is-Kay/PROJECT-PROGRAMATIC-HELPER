<#
    Pester 5 tests for the four Azure snapshot points (SnapStart, SnapPreSql, SnapPostSql, SnapFinal) and the
    manual check: step order, when a set is taken or skipped, the console questions, the 2.17.0 store migration,
    and that the old per-step checkpoints are gone. Azure and the fleet store are mocks: nothing is snapshotted.
    Run:
        Invoke-Pester -Path .\tests\SnapshotPoints.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $script:repo = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:repo 'VmMaintenance\VmMaintenance.psd1') -Force
    InModuleScope VmMaintenance { $script:SavedCfgSnap = $script:VmmConfig; $script:VmmConfig = @{ Log = @{ ToFile = $false } } }
}
AfterAll { InModuleScope VmMaintenance { $script:VmmConfig = $script:SavedCfgSnap } }

Describe 'Workflow definition' {
    It 'has ten steps with the four snapshot points around the SQL-invasive steps' {
        $d = InModuleScope VmMaintenance { @(Get-VmmWorkflowDefinition) }
        ($d.Name -join ',') | Should -Be 'Precheck,SnapStart,Stage,SnapPreSql,ExpandDisk,Upgrade,SnapPostSql,Verify,ManualCheck,SnapFinal'
        (@($d | Where-Object Snapshot).Name -join ',') | Should -Be 'SnapStart,SnapPreSql,SnapPostSql,SnapFinal'
        (@($d | Where-Object SqlInvasive).Name -join ',') | Should -Be 'ExpandDisk,Upgrade'
        $d[-1].Name | Should -Be 'SnapFinal'
        (1..10) -join ',' | Should -Be (($d.Order) -join ',')
    }
    It 'lets SnapStart run in business hours only while Policy.SnapStartInBusinessHours is on' {
        $c = InModuleScope VmMaintenance {
            $a = (Get-VmmWorkflowDefinition | Where-Object Name -eq 'SnapStart').Class
            $script:VmmConfig = @{ Log = @{ ToFile = $false }; Policy = @{ SnapStartInBusinessHours = $false } }
            $b = (Get-VmmWorkflowDefinition | Where-Object Name -eq 'SnapStart').Class
            $script:VmmConfig = @{ Log = @{ ToFile = $false } }
            "$a,$b"
        }
        $c | Should -Be 'Staging,Change'
        (InModuleScope VmMaintenance { @(Get-VmmWorkflowDefinition | Where-Object { $_.Snapshot -and $_.Name -ne 'SnapStart' }).Class | Select-Object -Unique }) | Should -Be 'Change'
    }
}

Describe 'Snapshot points on an Azure VM' {
    BeforeEach {
        $script:SnapStore = InModuleScope VmMaintenance {
            $r = New-VmmHostRecord -Name 'pt-host'
            $r.Azure = [pscustomobject]@{ SubscriptionId = 'sub'; ResourceGroup = 'rg'; VMName = 'vm-pt'; PowerState = 'running' }
            $r.Check = [pscustomobject]@{ CFreeGB = 80 }
            [pscustomobject]@{ Updated = $null; Hosts = @($r) }
        }
        $script:Recent = $null
        Mock -ModuleName VmMaintenance Read-VmmStore { $script:SnapStore }
        Mock -ModuleName VmMaintenance Save-VmmStore { }
        Mock -ModuleName VmMaintenance Assert-VmmWindow { }
        Mock -ModuleName VmMaintenance Assert-VmmModule { }
        Mock -ModuleName VmMaintenance Connect-VmmAzure { }
        Mock -ModuleName VmMaintenance Get-VmmHostPolicy { [pscustomobject]@{ Workable = $true; Warnings = @(); Scope = 'Server'; Os = 'test'; Why = '' } }
        Mock -ModuleName VmMaintenance Get-VmmRecentSnapshotSet { $script:Recent }
        Mock -ModuleName VmMaintenance New-VmmSnapshot { [pscustomobject]@{ Snapshot = "$($VMName)_$($Label)_OsDisk_snap" } }
    }
    It 'SnapStart takes a set when no full set from the last hour exists' {
        InModuleScope VmMaintenance -Parameters @{ S = $script:SnapStore } { Set-VmmStepState -Record $S.Hosts[0] -Step Precheck -Status Success }
        Invoke-VmmWorkflowStep -HostName 'pt-host' -Step SnapStart 6>$null
        Should -Invoke -ModuleName VmMaintenance New-VmmSnapshot -Times 1 -Exactly -ParameterFilter { $Label -eq 'snap-Start' -and $ExtraTags.SnapPoint -eq 'SnapStart' -and $ExtraTags.RetentionDays -eq '7' }
        $script:SnapStore.Hosts[0].Steps.SnapStart.Status | Should -Be 'Success'
        $script:SnapStore.Hosts[0].Steps.SnapStart.Snapshot | Should -Be 'vm-pt_snap-Start_OsDisk_snap'
    }
    It 'SnapStart is NotNeeded when every disk has a recent snapshot, and Skipped when declined' {
        InModuleScope VmMaintenance -Parameters @{ S = $script:SnapStore } { Set-VmmStepState -Record $S.Hosts[0] -Step Precheck -Status Success }
        $script:Recent = [pscustomobject]@{ Complete = $true; Disks = 1; Missing = @(); Snapshots = @('portal-os'); Newest = (Get-Date).ToUniversalTime(); MaxAgeMinutes = 60 }
        Invoke-VmmWorkflowStep -HostName 'pt-host' -Step SnapStart 6>$null
        $script:SnapStore.Hosts[0].Steps.SnapStart.Status | Should -Be 'NotNeeded'
        $script:SnapStore.Hosts[0].Steps.SnapStart.Note | Should -Match 'portal-os'
        Invoke-VmmWorkflowStep -HostName 'pt-host' -Step SnapStart -Decline 6>$null
        $script:SnapStore.Hosts[0].Steps.SnapStart.Status | Should -Be 'Skipped'
        Should -Invoke -ModuleName VmMaintenance New-VmmSnapshot -Times 0 -Exactly
    }
    It 'no checkpoint snapshot after ExpandDisk or Upgrade' {
        InModuleScope VmMaintenance -Parameters @{ S = $script:SnapStore } { foreach ($n in 'Precheck', 'SnapStart', 'Stage', 'SnapPreSql') { Set-VmmStepState -Record $S.Hosts[0] -Step $n -Status Success } }
        Invoke-VmmWorkflowStep -HostName 'pt-host' -Step ExpandDisk 6>$null
        Invoke-VmmWorkflowStep -HostName 'pt-host' -Step Upgrade -Confirmed 6>$null
        Should -Invoke -ModuleName VmMaintenance New-VmmSnapshot -Times 0 -Exactly
    }
    It 'SnapPostSql and SnapFinal are always taken, even with a recent set' {
        InModuleScope VmMaintenance -Parameters @{ S = $script:SnapStore } { foreach ($n in 'Precheck', 'SnapStart', 'Stage', 'SnapPreSql', 'ExpandDisk', 'Upgrade') { Set-VmmStepState -Record $S.Hosts[0] -Step $n -Status Success } }
        $script:Recent = [pscustomobject]@{ Complete = $true; Disks = 1; Missing = @(); Snapshots = @('s'); Newest = (Get-Date).ToUniversalTime(); MaxAgeMinutes = 60 }
        Invoke-VmmWorkflowStep -HostName 'pt-host' -Step SnapPostSql 6>$null
        InModuleScope VmMaintenance -Parameters @{ S = $script:SnapStore } { foreach ($n in 'Verify', 'ManualCheck') { Set-VmmStepState -Record $S.Hosts[0] -Step $n -Status Success } }
        Invoke-VmmWorkflowStep -HostName 'pt-host' -Step SnapFinal 6>$null
        Should -Invoke -ModuleName VmMaintenance New-VmmSnapshot -Times 1 -Exactly -ParameterFilter { $Label -eq 'snap-PostSql' }
        Should -Invoke -ModuleName VmMaintenance New-VmmSnapshot -Times 1 -Exactly -ParameterFilter { $Label -eq 'snap-Final' }
        (InModuleScope VmMaintenance -Parameters @{ S = $script:SnapStore } { Get-VmmNextStep -Record $S.Hosts[0] }) | Should -BeNullOrEmpty
    }
    It 'ManualCheck needs -Confirmed or -Bypass with a reason of 10+ characters' {
        InModuleScope VmMaintenance -Parameters @{ S = $script:SnapStore } { foreach ($n in 'Precheck', 'SnapStart', 'Stage', 'SnapPreSql', 'ExpandDisk', 'Upgrade', 'SnapPostSql', 'Verify') { Set-VmmStepState -Record $S.Hosts[0] -Step $n -Status Success } }
        { Invoke-VmmWorkflowStep -HostName 'pt-host' -Step ManualCheck 6>$null } | Should -Throw -ErrorId 'VmmGuided*'
        { Invoke-VmmWorkflowStep -HostName 'pt-host' -Step ManualCheck -Bypass -BypassReason 'short' 6>$null } | Should -Throw -ErrorId 'VmmBypassReason*'
        Invoke-VmmWorkflowStep -HostName 'pt-host' -Step ManualCheck -Bypass -BypassReason 'checked by the application owner' 6>$null
        $script:SnapStore.Hosts[0].Steps.ManualCheck.Status | Should -Be 'Skipped'
        $script:SnapStore.Hosts[0].Steps.ManualCheck.Note | Should -Match 'BYPASSED by operator: checked by the application owner'
    }
}

Describe 'Console questions for the snapshot points' {
    BeforeEach {
        Mock -ModuleName VmMaintenance Get-VmmTimeWindow { [pscustomobject]@{ ChangesAllowed = $true; ZoneTime = (Get-Date); ZoneLabel = 'Lisbon'; NextChangeAt = (Get-Date); UntilChangeText = 'now' } }
        Mock -ModuleName VmMaintenance Invoke-VmmWorkflowStep { }
    }
    It 'SnapStart: Enter takes it, n declines it' {
        Mock -ModuleName VmMaintenance Read-VmmPrompt { '' }
        InModuleScope VmMaintenance { Invoke-VmmStepFromTui -HostName 'pt-host' -Step SnapStart 6>$null }
        Should -Invoke -ModuleName VmMaintenance Invoke-VmmWorkflowStep -Times 1 -Exactly -ParameterFilter { $Step -eq 'SnapStart' -and -not $Decline }
        Mock -ModuleName VmMaintenance Read-VmmPrompt { 'n' }
        InModuleScope VmMaintenance { Invoke-VmmStepFromTui -HostName 'pt-host' -Step SnapStart 6>$null }
        Should -Invoke -ModuleName VmMaintenance Invoke-VmmWorkflowStep -Times 1 -Exactly -ParameterFilter { $Step -eq 'SnapStart' -and $Decline }
    }
    It 'ManualCheck: Y confirms, BYPASS asks for a reason, anything else cancels' {
        Mock -ModuleName VmMaintenance Read-VmmPrompt { 'Y' }
        InModuleScope VmMaintenance { Invoke-VmmStepFromTui -HostName 'pt-host' -Step ManualCheck 6>$null }
        Should -Invoke -ModuleName VmMaintenance Invoke-VmmWorkflowStep -Times 1 -Exactly -ParameterFilter { $Step -eq 'ManualCheck' -and $Confirmed }
        $script:Answers = [System.Collections.Generic.Queue[string]]::new()
        foreach ($a in 'BYPASS', 'app owner checked, ticket 4711') { $script:Answers.Enqueue($a) }
        Mock -ModuleName VmMaintenance Read-VmmPrompt { $script:Answers.Dequeue() }
        InModuleScope VmMaintenance { Invoke-VmmStepFromTui -HostName 'pt-host' -Step ManualCheck 6>$null }
        Should -Invoke -ModuleName VmMaintenance Invoke-VmmWorkflowStep -Times 1 -Exactly -ParameterFilter { $Bypass -and $BypassReason -eq 'app owner checked, ticket 4711' }
        Mock -ModuleName VmMaintenance Read-VmmPrompt { 'no' }
        InModuleScope VmMaintenance { Invoke-VmmStepFromTui -HostName 'pt-host' -Step ManualCheck 6>$null }
        Should -Invoke -ModuleName VmMaintenance Invoke-VmmWorkflowStep -Times 2 -Exactly
    }
}

Describe 'Store migration and leftovers' {
    It 'PreSnapshot becomes SnapPreSql; passed points are Skipped; ManualCheck stays to do' {
        $r = InModuleScope VmMaintenance {
            $h = New-VmmHostRecord -Name 'old'
            foreach ($s in 'Precheck', 'Stage', 'PreSnapshot', 'ExpandDisk', 'Upgrade', 'Verify') { Set-VmmStepState -Record $h -Step $s -Status Success }
            Update-VmmStepName -Record $h
            $h
        }
        $r.Steps.PSObject.Properties['PreSnapshot'] | Should -BeNullOrEmpty
        $r.Steps.SnapPreSql.Status | Should -Be 'Success'
        $r.Steps.SnapStart.Status | Should -Be 'Skipped'
        $r.Steps.SnapPostSql.Status | Should -Be 'Skipped'
        (InModuleScope VmMaintenance -Parameters @{ H = $r } { (Get-VmmNextStep -Record $H).Name }) | Should -Be 'ManualCheck'
    }
    It 'a new host gets nothing filled in' {
        $r = InModuleScope VmMaintenance { $h = New-VmmHostRecord -Name 'new'; Update-VmmStepName -Record $h; $h }
        @($r.Steps.PSObject.Properties).Count | Should -Be 0
    }
    It 'the per-step checkpoint settings are gone from the code and the example config' {
        $hits = @(Get-ChildItem -Path (Join-Path $script:repo 'VmMaintenance'), (Join-Path $script:repo 'config') -Recurse -File -Include '*.ps1', '*.psd1' |
            Select-String -Pattern 'SnapshotAfter|cp-\$Step|PreSnapshot' | Where-Object { $_.Path -notlike '*Update-VmmStepName.ps1' })
        ($hits | ForEach-Object { "$($_.Path):$($_.LineNumber)" }) | Should -BeNullOrEmpty
    }
}
