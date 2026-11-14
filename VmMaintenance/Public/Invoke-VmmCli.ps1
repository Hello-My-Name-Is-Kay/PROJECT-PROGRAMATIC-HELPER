function Invoke-VmmCli {
    <#
    .SYNOPSIS
        Command-line front end with the same actions as the console UI: vmm <command> [-Option value].
    .DESCRIPTION
        Every command is logged to the encrypted day log (vmm log): the command line (option names, not
        values), every message, the tables it printed, live progress lines, then the result with its
        duration, or the error. Only one vmm that can change things runs at a time (a second one stops with
        VmmInstanceLocked, exit code 6); read-only commands such as log, status and plan always run.
        Long work prints time-stamped progress lines in the terminal (--no-log
        turns those off; the file is still written). A one-line footer shows the duration.
    .EXAMPLE
        Invoke-VmmCli -Command check -Arguments @('-Name', 'srv01')
    #>
    [CmdletBinding()]
    param([string]$Command = 'ui', [object[]]$Arguments = @())

    # -Key value / -Switch pairs -> splat hashtable (a value may be an array from "a,b")
    $p = @{}
    $order = New-Object System.Collections.Generic.List[string]   # options as typed (for the log line)
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $a = $Arguments[$i]
        if ($a -is [string] -and $a -match '^-([A-Za-z]\w*):?$') {
            $k = $Matches[1]
            if (-not $order.Contains($k)) { $order.Add($k) }
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
        'snapshot' = @{ F = 'Invoke-VmmSnapshot';         D = 'read-only snapshot, terminal first; builds the extractor only for hosts with no route [-Name a,b]' }
        'access'   = @{ F = 'Test-VmmHostAccess';         D = 'which terminal route works per host (DCOM, WinRM, WinRM-SSL), who needs hands-on [-Name a,b]' }
        'check'    = @{ F = 'Invoke-VmmFleetCheck';       D = 'parallel read-only check [-Name a,b] [-Azure] [-AccessOnly]' }
        'import'   = @{ F = 'Import-VmmFleet';            D = 'add hosts              -Path hosts.csv (hostname/FQDN, domain, IP) | list.txt [-Preview] [-Update] [-RemoveSource] | -Name a,b' }
        'remove'   = @{ F = 'Remove-VmmFleetHost';        D = 'remove hosts           -Name a,b' }
        'plan'     = @{ F = 'Get-VmmQueue';               D = 'work queue: next step per host, allowed now?' }
        'next'     = @{ F = 'Invoke-VmmNextStep';         D = 'run next auto step     [-HostName x | -All]' }
        'step'     = @{ F = 'Invoke-VmmWorkflowStep';     D = 'run one step           -HostName x -Step Precheck|Stage|PreSnapshot|ExpandDisk|Upgrade|Verify [-Confirmed] [-Override -OverrideReason ".."]' }
        'guide'    = @{ F = 'Get-VmmRdpGuide';            D = 'RDP/RDM checklist      -HostName x -Step y' }
        'agent'    = @{ F = 'Export-VmmHostAgent';        D = 'same as extractor (old name)' }
        'collect'  = @{ F = 'Import-VmmCollectorResult';  D = 'record host result     [-Path VMM_x.vmm | -Line "VMM2|..."] (default: clipboard)' }
        'inbox'    = @{ F = 'Import-VmmResultInbox';      D = 'import all VMM_*.vmm result files from Desktop/Downloads [-Path dir]' }
        'extractor' = @{ F = 'Export-VmmHostAgent';       D = 'build the extractor     -Generic (any host) | -HostName x (with its plan)' }
        'stage'    = @{ F = 'Test-VmmStagingSource';      D = 'staging gate check (share + hashes)' }
        'agents'   = @{ F = 'Get-VmmAgentHealth';         D = 'agent health + version per host (Qualys, CrowdStrike, Zabbix, Ivanti, Lansweeper) [-HostName a,b] [-Problems]' }
        'inventory' = @{ F = 'Get-VmmInventory';          D = 'server inventory (24 columns) [-HostName x] [-Missing] [-Export]' }
        'inventory-set' = @{ F = 'Set-VmmInventoryValue'; D = 'set a column by hand   -HostName x[,y] -Field "Server Owner" -Value ".." | -Clear' }
        'helptext' = @{ F = 'New-VmmHelpTextIssue';       D = 'ask for a help text change on GitHub -Field "<column>" | -Screen "<name>" [-Proposed ..]' }
        'fetch'    = @{ F = 'Save-VmmSqlUpdate';          D = 'SQL Server SP/CU per host: download once (cache on the share), copy into host folders [-Preview] [-HostName a,b]' }
        'media'    = @{ F = 'Get-VmmMediaReport';         D = 'media repository: OS images by language, host folders, what is missing' }
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
        'policy'   = @{ F = 'Get-VmmPolicyReport';        D = 'OS policy: scope per host, management warnings [-Notice]' }
        'order'    = @{ F = 'Set-VmmHostOrder';           D = 'work on a client-OS host by order -HostName x -Reason ".." | -Clear' }
        'github'   = @{ F = 'Get-VmmGitHubStatus';        D = 'GitHub: sign-in, versions, latest commit, checks' }
        'update'   = @{ F = 'Update-VmmFromGitHub';       D = 'update vmm from GitHub [-CheckOnly]' }
        'clone'    = @{ F = 'Install-VmmSourceClone';     D = 'clone the repo for updates/PRs [-Path dir]' }
        'issue'    = @{ F = 'New-VmmGitHubIssue';         D = 'open an issue [-FromErrorLog] [-Title ..] [-Body ..]' }
        'pr'       = @{ F = 'New-VmmGitHubPullRequest';   D = 'pull request from a branch [-NewBranch x -Message ..] [-Title ..] [-Draft]' }
        'log'      = @{ F = 'Get-VmmLog';                 D = 'the vmm log            [-Follow] [-Tail 200] [-Level Error] [-Find text] [-Date yyyy-MM-dd] [-List] [-Export]' }
        'maint'    = @{ F = 'Invoke-VmmMaintenance';      D = 'maintenance of vmm     -Action Diagnose|CheckStore|Backup|ListBackups|Restore|CleanLogs|CleanTemp|ResetUi' }
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
    # One vmm at a time: every command that can change something takes the lock first, so a second window
    # stops here instead of overwriting the first one's work. Read-only commands run beside a busy vmm.
    $readOnly = 'log', 'status', 'plan', 'time', 'progress', 'vpn', 'guide', 'agents', 'media', 'github', 'policy', 'inventory', 'config', 'stage'
    $locked = $false
    if ($Command -notin $readOnly) { $locked = Enter-VmmInstanceLock -Owner "vmm $Command" }
    if ($Command -eq 'ui') { try { & $fn @p } finally { if ($locked) { Exit-VmmInstanceLock } }; return }
    if ($Command -eq 'log') { & $fn @p; return }   # reading the log does not write to it
    # Option names only: values can be host names (they are in the encrypted log anyway, but keep it short)
    $shown = ("vmm {0} {1}" -f $Command, (@($order | ForEach-Object { "-$_" }) -join ' ')).Trim()
    Write-VmmLog "Command: $shown" -Level Muted -FileOnly
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $failed = $null
    $out = $null
    try {
        if ($Command -eq 'config' -and -not $p.Count) { Import-VmmConfig }
        else { & $fn @p | Tee-Object -Variable out }
    } catch {
        $failed = $_
        throw
    } finally {
        $sw.Stop()
        if ($locked) { Exit-VmmInstanceLock }
        # Objects the command returned (the console formats them itself): keep a copy in the log
        if ($out) {
            try {
                $n = 0
                foreach ($l in @(($out | Out-String -Width 200 -Stream) | Where-Object { $_.Trim() } | Select-Object -First 200)) { Add-VmmLogEntry -Text (Protect-VmmLogText $l.TrimEnd()) -Level Output; $n++ }
            } catch { }
        }
        $secs = '{0:N1}' -f $sw.Elapsed.TotalSeconds
        if ($failed) {
            Add-VmmLogEntry -Text (Protect-VmmLogText ("$shown FAILED in $secs s: " + (("$($failed.Exception.Message)" -replace '\s+', ' ').Trim()) + " [$($failed.FullyQualifiedErrorId)]")) -Level Error
        } else {
            Add-VmmLogEntry -Text "$shown done in $secs s" -Level Muted
            if ((Test-VmmLogLive) -and $sw.Elapsed.TotalSeconds -ge 1) { Write-VmmColor "-- $Command done in $secs s | full log: vmm log --" -Role Muted }
        }
    }
}
