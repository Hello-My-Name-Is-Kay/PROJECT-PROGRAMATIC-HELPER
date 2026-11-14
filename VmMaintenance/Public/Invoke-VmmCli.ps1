function Invoke-VmmCli {
    <#
    .SYNOPSIS
        Command-line front end with the same actions as the console UI: vmm <command> [-Option value].
    .EXAMPLE
        Invoke-VmmCli -Command check -Arguments @('-Name', 'srv01')
    #>
    [CmdletBinding()]
    param([string]$Command = 'ui', [object[]]$Arguments = @())

    # -Key value / -Switch pairs -> splat hashtable (a value may be an array from "a,b")
    $p = @{}
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $a = $Arguments[$i]
        if ($a -is [string] -and $a -match '^-([A-Za-z]\w*):?$') {
            $k = $Matches[1]
            $next = if ($i + 1 -lt $Arguments.Count) { $Arguments[$i + 1] } else { $null }
            if ($null -eq $next -or ($next -is [string] -and $next -match '^-[A-Za-z]')) { $p[$k] = $true }
            else {
                # vmm.cmd passes "a,b" as one string: split host lists
                if ($k -in 'Name', 'VMName', 'ComputerName' -and $next -is [string] -and $next -match ',') { $next = @($next -split '\s*,\s*' | Where-Object { $_ }) }
                $p[$k] = $next; $i++
            }
        } else {
            throw (New-VmmErrorRecord -Activity "Unexpected argument '$a'." -Fix 'Options are written -Name value. Run: vmm help' -Category InvalidArgument)
        }
    }

    $map = [ordered]@{
        'ui'       = @{ F = 'Start-VmmConsole';           D = 'open the terminal UI (default)' }
        'status'   = @{ F = 'Get-VmmFleet';               D = 'fleet table            [-Filter srv*]' }
        'check'    = @{ F = 'Invoke-VmmFleetCheck';       D = 'parallel read-only check [-Name a,b] [-Azure]' }
        'import'   = @{ F = 'Import-VmmFleet';            D = 'add hosts              -Path list.txt [-RemoveSource] | -Name a,b' }
        'remove'   = @{ F = 'Remove-VmmFleetHost';        D = 'remove hosts           -Name a,b' }
        'plan'     = @{ F = 'Get-VmmQueue';               D = 'work queue: next step per host, allowed now?' }
        'next'     = @{ F = 'Invoke-VmmNextStep';         D = 'run next auto step     [-HostName x | -All]' }
        'step'     = @{ F = 'Invoke-VmmWorkflowStep';     D = 'run one step           -HostName x -Step Precheck|Stage|PreSnapshot|ExpandDisk|Upgrade|Verify [-Confirmed] [-Override -OverrideReason ".."]' }
        'guide'    = @{ F = 'Get-VmmRdpGuide';            D = 'RDP/RDM checklist      -HostName x -Step y' }
        'agent'    = @{ F = 'Export-VmmHostAgent';        D = 'host agent .ps1 for RDP -HostName x | -Generic' }
        'collect'  = @{ F = 'Import-VmmCollectorResult';  D = 'record host result     [-Line "VMM2|..."] (default: clipboard) [-Step Verify]' }
        'stage'    = @{ F = 'Test-VmmStagingSource';      D = 'staging gate check (share + hashes)' }
        'blocker'  = @{ F = 'New-VmmBlockerReport';       D = 'report for manager     -HostName x -Step y -Message ".." [-Contact Sent|Later|Bypass]' }
        'resolve'  = @{ F = 'Resolve-VmmBlocker';         D = 'access granted         -HostName x [-Step y]' }
        'report'   = @{ F = 'Export-VmmDailyReport';      D = 'daily CSV+HTML+JSON    [-Open]' }
        'progress' = @{ F = 'Get-VmmDailyProgress';       D = 'machines done today vs target' }
        'time'     = @{ F = 'Get-VmmTimeWindow';          D = 'clock, zone and whether changes are allowed now' }
        'prune'    = @{ F = 'Invoke-VmmPrune';            D = 'expired snapshots      preview, or -Apply' }
        'azure'    = @{ F = 'Select-VmmAzureContext';     D = 'sign in + pick subscription [-Save] [-DeviceCode]' }
        'vpn'      = @{ F = 'Get-VmmVpnStatus';           D = 'VPN state (Cisco Secure Client, Windows VPN, probe)' }
        'connect'  = @{ F = 'Connect-VmmVpn';             D = 'start the VPN (you sign in in the VPN client)' }
        'disconnect' = @{ F = 'Disconnect-VmmVpn';        D = 'stop the VPN' }
        'ai'       = @{ F = 'Invoke-VmmAssistant';        D = 'ask the optional AI assistant -Prompt ".." [-IncludeFleet]' }
        'setup'    = @{ F = 'Start-VmmSetupWizard';       D = 'first-run / setup wizard (all options, with explanations)' }
        'set'      = @{ F = 'Set-VmmSetting';             D = 'change a setting       -Name Staging.SourceShare -Value "\\srv\share"' }
        'config'   = @{ F = 'Import-VmmConfig';           D = 'show config path / reload [-Path file]' }
    }
    if ($Command -in 'help', '-h', '--help', '/?') {
        Write-VmmLog 'vmm <command> [-Option value ...]' -Level Info
        foreach ($k in $map.Keys) { Write-VmmLog ('  {0,-11} {1}' -f $k, $map[$k].D) }
        Write-VmmLog 'Full help for a command: Get-Help <Function> -Full  (function names: Get-Command -Module VmMaintenance)' -Level Muted
        return
    }
    if (-not $map.Contains($Command)) {
        throw (New-VmmErrorRecord -Activity "Unknown command '$Command'." -Fix 'Run: vmm help' -Category InvalidArgument -ErrorId 'VmmCliUnknown')
    }
    $fn = $map[$Command].F
    if ($Command -eq 'config' -and -not $p.Count) { Import-VmmConfig; return }
    & $fn @p
}
