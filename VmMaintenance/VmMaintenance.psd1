@{
    RootModule           = 'VmMaintenance.psm1'
    ModuleVersion        = '2.1.0'
    GUID                 = '63eba97e-c6ef-4ccb-b686-dd907935872a'
    Author               = 'Kay'
    Description          = 'Fleet maintenance console for Windows servers and Azure VMs: parallel checks, time-window rules, staging gate, guided RDP steps, checkpoint snapshots, blocker reports, daily CSV/HTML export. Encrypted local store; no stored credentials.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    # Az modules are checked per function (Lansweeper and WMI reports do not need them)
    FunctionsToExport    = @(
        'Connect-VmmVpn'
        'Copy-VmmStagingPackage'
        'Disconnect-VmmVpn'
        'Dismount-VmmUpgradeMedia'
        'Expand-VmmOsDisk'
        'Export-VmmDailyReport'
        'Export-VmmHostAgent'
        'Get-VmmAzureVmDisk'
        'Get-VmmDailyProgress'
        'Get-VmmFleet'
        'Get-VmmLansweeperDiskSpace'
        'Get-VmmRdpGuide'
        'Get-VmmServerPlatform'
        'Get-VmmTimeWindow'
        'Get-VmmVpnStatus'
        'Import-VmmCollectorResult'
        'Import-VmmConfig'
        'Import-VmmFleet'
        'Initialize-VmmConfig'
        'Invoke-VmmAssistant'
        'Invoke-VmmCli'
        'Invoke-VmmFleetCheck'
        'Invoke-VmmNextStep'
        'Invoke-VmmPrune'
        'Invoke-VmmWorkflowStep'
        'Mount-VmmUpgradeMedia'
        'New-VmmBlockerReport'
        'New-VmmDiskFromSnapshot'
        'New-VmmSnapshot'
        'Remove-VmmExpiredSnapshot'
        'Remove-VmmFleetHost'
        'Resolve-VmmBlocker'
        'Select-VmmAzureContext'
        'Set-VmmSetting'
        'Start-VmmConsole'
        'Start-VmmSetupWizard'
        'Test-VmmStagingSource'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{ PSData = @{ Tags = @('Azure', 'VM', 'Snapshot', 'Lansweeper', 'Maintenance', 'TUI', 'Fleet', 'Windows') } }
}
