function Get-VmmHostCheckScript {
    # Self-contained snapshot of one host, run inside a runspace. Read-only: DNS, ping, TCP ports, then CIM for
    # OS, model, C:, Azure agent, SQL instances, pending reboot and watched software (registry Uninstall keys -
    # never Win32_Product, which triggers MSI repairs).
    # Terminal routes are tried in order (Fleet.Routes): DCOM (TCP 135, same transport as Get-WmiObject), WinRM
    # (TCP 5985), WinRM-SSL (TCP 5986). The first that answers is used and recorded in Route; every failure is
    # kept in Tried. Route = None means hands-on (the Extractor over RDP/RDM) is the only way left.
    # Nothing is written, started, stopped or configured on the host, and nothing is changed on this laptop
    # (no TrustedHosts edit, no firewall change).
    # Agent health uses Get-AgentVerdict from the Extractor (Resources\VmmHostAgent.ps1): one set of rules.
    [CmdletBinding()]
    param()
    $text = @'
param($Name, $A)
# VMM-AGENTVERDICT
$r = [ordered]@{
    Name = $Name; CheckedAt = (Get-Date).ToUniversalTime().ToString('o'); IPv4 = $null; Ping = 'No'; Ports = ''
    Reachable = 'No'; Route = 'None'; Tried = ''; OS = $null; Lang = $null; Version = $null; Build = $null; SP = $null; LastBoot = $null
    Manufacturer = $null; Model = $null; Platform = $null; CTotalGB = $null; CFreeGB = $null
    PendingReboot = $null; Sql = ''; SqlLang = ''; Software = ''; Inv = $null; Agents = $null; AgentSummary = ''; Error = $null
}
# Live log: each step goes to the laptop's log as it happens (Invoke-VmmParallel drains the queue)
$say = { param($m) if ($A.Trace) { $A.Trace.Enqueue("${Name}: $m") } }
# Connect by the FQDN from the import file when there is one; if the name does not resolve, use the imported IP.
$conn = if ($A.Addr -and $A.Addr[$Name]) { $A.Addr[$Name] } else { $Name }
& $say "resolving $conn"
try {
    $ip = [System.Net.Dns]::GetHostAddresses($conn) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
    if (-not $ip) { throw 'no IPv4 address' }
    $r.IPv4 = "$ip"
    & $say "address $ip"
} catch {
    if ($A.IpMap -and $A.IpMap[$Name]) { $conn = $A.IpMap[$Name]; $r.IPv4 = $conn; & $say "name does not resolve, using the imported IP $conn" }
    else { & $say 'stopped: name does not resolve and no IP was imported'; $r.Error = "DNS: $conn does not resolve from this laptop ($($_.Exception.InnerException.Message)). Import the host with its FQDN or IP (vmm import -Path hosts.csv)."; return [pscustomobject]$r }
}

try { $png = New-Object System.Net.NetworkInformation.Ping; if ($png.Send($conn, $A.TimeoutMs).Status -eq 'Success') { $r.Ping = 'Yes' } } catch { } finally { if ($png) { $png.Dispose() } }

$open = @()
$routePort = @{ 'DCOM' = 135; 'WinRM' = 5985; 'WinRM-SSL' = 5986 }
$order = @(@($A.Routes) | Where-Object { $routePort.ContainsKey("$_") }); if (-not $order) { $order = @('DCOM', 'WinRM', 'WinRM-SSL') }
$probe = @(@($A.Ports) + @($order | ForEach-Object { $routePort[$_] }) | ForEach-Object { [int]$_ } | Sort-Object -Unique)
foreach ($port in $probe) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $ar = $c.BeginConnect($conn, [int]$port, $null, $null); if ($ar.AsyncWaitHandle.WaitOne($A.TimeoutMs) -and $c.Connected) { $open += $port } } catch { } finally { $c.Close() }
}
$r.Ports = $open -join ','
& $say ("ping {0}, open ports: {1}" -f $r.Ping, $(if ($open) { $open -join ',' } else { 'none' }))
$routes = @($order | Where-Object { $open -contains $routePort[$_] })
if (-not $routes) {
    & $say 'stopped: no terminal route open (TCP 135, 5985, 5986 all closed)'
    $r.Reachable = if ($r.Ping -eq 'Yes' -or $open) { 'Partial' } else { 'No' }
    $r.Tried = (@($order | ForEach-Object { "${_}: TCP $($routePort[$_]) closed" }) -join ' | ')
    $r.Error = if ($r.Reachable -eq 'No') { 'No answer at all (no ping, no open port): host down, wrong address, or not reachable from this network/VPN.' }
               else { 'No terminal route: TCP 135 (WMI), 5985 and 5986 (WinRM) are closed from this laptop. Hands-on needed: run the Extractor on the host (RDP/RDM).' }
    return [pscustomobject]$r
}

$s = $null
try {
    # Try each open route in order; the first that answers a real query wins.
    $os = $null; $tried = @()
    foreach ($route in $routes) {
        & $say "trying $route (TCP $($routePort[$route]))"
        try {
            $opt = switch ($route) { 'DCOM' { New-CimSessionOption -Protocol Dcom } 'WinRM' { New-CimSessionOption -Protocol Wsman } 'WinRM-SSL' { New-CimSessionOption -UseSsl } }
            $sp = @{ ComputerName = $conn; SessionOption = $opt; ErrorAction = 'Stop'; OperationTimeoutSec = 30 }
            if ($route -eq 'WinRM-SSL') { $sp.Port = 5986 }
            if ($A.Credential) { $sp.Credential = $A.Credential }
            $s = New-CimSession @sp
            $os = Get-CimInstance -CimSession $s -ClassName Win32_OperatingSystem -ErrorAction Stop
            $r.Route = $route
            & $say "$route answered"
            break
        } catch {
            $m = "$($_.Exception.Message)" -replace '\s+', ' '
            $tried += "${route}: $m"
            & $say "$route failed: $m"
            if ($s) { Remove-CimSession -CimSession $s -ErrorAction SilentlyContinue; $s = $null }
        }
    }
    $r.Tried = $tried -join ' | '
    if (-not $s) {
        $r.Reachable = 'Partial'
        $r.Error = 'Terminal access failed on every open route (' + ($routes -join ', ') + '): ' + $r.Tried
        return [pscustomobject]$r
    }
    if ($A.AccessOnly) {
        $r.Reachable = 'Yes'; $r.OS = $os.Caption; $r.Build = $os.BuildNumber
        return [pscustomobject]$r
    }
    $cs = Get-CimInstance -CimSession $s -ClassName Win32_ComputerSystem -ErrorAction Stop
    $c  = Get-CimInstance -CimSession $s -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
    $r.Reachable = 'Yes'
    $r.OS = $os.Caption; $r.Version = $os.Version; $r.Build = $os.BuildNumber; $r.SP = $os.ServicePackMajorVersion
    # Install language (e.g. fr-FR): an in-place upgrade needs media in the same language.
    try { $r.Lang = [Globalization.CultureInfo]::GetCultureInfo([int]$os.OSLanguage).Name } catch { }
    $r.LastBoot = if ($os.LastBootUpTime) { ([datetime]$os.LastBootUpTime).ToUniversalTime().ToString('o') } else { $null }
    $r.Manufacturer = $cs.Manufacturer; $r.Model = $cs.Model
    $r.CTotalGB = [math]::Round($c.Size / 1GB, 1); $r.CFreeGB = [math]::Round($c.FreeSpace / 1GB, 1)
    & $say ("{0}, C: {1} GB free of {2} GB" -f $r.OS, $r.CFreeGB, $r.CTotalGB)

    if ($cs.Manufacturer -like '*VMware*') { $r.Platform = 'VMware' }
    elseif ($cs.Model -like '*Virtual Machine*' -and $cs.Manufacturer -like '*Microsoft*') {
        $agent = Get-CimInstance -CimSession $s -ClassName Win32_Service -Filter "Name='WindowsAzureGuestAgent'" -ErrorAction SilentlyContinue
        $r.Platform = if ($agent) { 'Azure' } else { 'Hyper-V' }
    } else { $r.Platform = 'Physical' }

    # Registry through StdRegProv (HKLM = 2147483650)
    $hk = [uint32]2147483650
    $reg = { param($m, $a) Invoke-CimMethod -CimSession $s -Namespace root/default -ClassName StdRegProv -MethodName $m -Arguments $a -ErrorAction Stop }
    $str = { param($k, $v) (& $reg 'GetStringValue' @{ hDefKey = $hk; sSubKeyName = $k; sValueName = $v }).sValue }

    # SQL Server instances: name, version (PatchLevel), edition
    & $say 'reading SQL instances and pending reboot (registry)'
    # 64-bit registry view first, then the 32-bit one (Wow6432Node, tagged "(32-bit)"); a name found in both is listed once
    $sqlParts = @(); $langs = @(); $seenSql = @()
    foreach ($root in @(@('SOFTWARE\Microsoft\Microsoft SQL Server', ''), @('SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server', ' (32-bit)'))) {
        $inst = & $reg 'EnumValues' @{ hDefKey = $hk; sSubKeyName = ($root[0] + '\Instance Names\SQL') }
        if ($inst.ReturnValue -ne 0 -or -not $inst.sNames) { continue }
        foreach ($n in $inst.sNames) {
            if ($seenSql -contains $n) { continue }
            $seenSql += $n
            $id = & $str ($root[0] + '\Instance Names\SQL') $n
            $ver = & $str ($root[0] + "\$id\Setup") 'PatchLevel'
            $ed  = & $str ($root[0] + "\$id\Setup") 'Edition'
            # Install language (LCID): service packs before SQL 2017 come in one file per language
            $lc = & $reg 'GetDWORDValue' @{ hDefKey = $hk; sSubKeyName = ($root[0] + "\$id\Setup"); sValueName = 'Language' }
            if ($lc.ReturnValue -eq 0 -and $lc.uValue) { $langs += "$n=$($lc.uValue)" }
            $sqlParts += ("$n $ver $ed".Trim() + $root[1])
        }
    }
    if ($sqlParts.Count) {
        $r.Sql = $sqlParts -join '; '
        $r.SqlLang = $langs -join '; '
    } else { $r.Sql = 'none' }

    # Pending reboot (CBS, Windows Update, file rename operations)
    $pend = $false
    if ((& $reg 'EnumKey' @{ hDefKey = $hk; sSubKeyName = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' }).ReturnValue -eq 0) { $pend = $true }
    if ((& $reg 'EnumKey' @{ hDefKey = $hk; sSubKeyName = 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' }).ReturnValue -eq 0) { $pend = $true }
    $pfr = & $reg 'GetMultiStringValue' @{ hDefKey = $hk; sSubKeyName = 'SYSTEM\CurrentControlSet\Control\Session Manager'; sValueName = 'PendingFileRenameOperations' }
    if ($pfr.ReturnValue -eq 0 -and $pfr.sValue) { $pend = $true }
    $r.PendingReboot = if ($pend) { 'Yes' } else { 'No' }

    # Inventory columns: domain, DC role, Windows licence, agent services, legacy TLS (failures leave a column empty)
    $inv = [ordered]@{}
    $inv.Domain = if ($cs.PartOfDomain) { "$($cs.Domain)" } else { "WORKGROUP ($($cs.Domain))" }
    $inv.DomainController = if ($cs.DomainRole -ge 4) { 'Yes' } else { 'No' }
    $names = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'Grace period (OOB)'; 3 = 'Grace period (OOT)'; 4 = 'Grace period (non-genuine)'; 5 = 'Notification'; 6 = 'Grace period (extended)' }
    # The licence query wakes the Software Protection service on the host for a moment: Fleet.WindowsLicence = $false skips it
    if ($A.Licence -ne $false) {
        & $say 'Windows licence query (can take up to 90 s)'
        try {
            $lp = @(Get-CimInstance -CimSession $s -ClassName SoftwareLicensingProduct -Filter "Name LIKE 'Windows%' AND PartialProductKey IS NOT NULL" -Property LicenseStatus -OperationTimeoutSec 90 -ErrorAction Stop)
            $inv.WindowsLicense = if ($lp.Count) { $names[[int]$lp[0].LicenseStatus] } else { 'No product key installed' }
        } catch { & $say "licence not read: $($_.Exception.Message)" }
    }
    # Installed programs (name + version) from both Uninstall keys, read once (agent versions, watch list)
    $cache = @{}
    $getApps = {
        if (-not $cache.ContainsKey('apps')) {
            $list = @()
            foreach ($root in 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
                $keys = & $reg 'EnumKey' @{ hDefKey = $hk; sSubKeyName = $root }
                if ($keys.ReturnValue -ne 0) { continue }
                foreach ($k in $keys.sNames) {
                    $dn = & $str "$root\$k" 'DisplayName'
                    if ($dn) { $list += [pscustomobject]@{ Name = "$dn"; Version = "$(& $str "$root\$k" 'DisplayVersion')" } }
                }
            }
            $cache.apps = $list
        }
        $cache.apps
    }
    if ($A.Agents -and $A.Agents.Count -and (Get-Command Get-AgentVerdict -ErrorAction SilentlyContinue)) {
        & $say 'agent health: services, versions, drivers, ports, logs'
        try {
            $svc = @(Get-CimInstance -CimSession $s -ClassName Win32_Service -Property Name, DisplayName, State, StartMode, PathName -ErrorAction Stop)
            $apps = @(& $getApps)
            $file = { param($path) Get-CimInstance -CimSession $s -ClassName CIM_DataFile -Filter ("Name='" + ($path -replace '\\', '\\' -replace "'", "\'") + "'") -ErrorAction SilentlyContinue }
            $agents = [ordered]@{}; $bad = @()
            foreach ($k in @($A.Agents.Keys)) {
                $spec = $A.Agents[$k]
                $hit = $null
                foreach ($pat in @($spec.Services)) { if (-not $hit -and $pat) { $hit = $svc | Where-Object { $_.Name -like $pat -or $_.DisplayName -like $pat } | Select-Object -First 1 } }
                $ver = ''; $dd = @(); $pc = @(); $age = $null
                if ($hit) {
                    foreach ($pat in @($spec.Products)) { if (-not $ver -and $pat) { $a = $apps | Where-Object { $_.Name -like $pat -and $_.Version } | Select-Object -First 1; if ($a) { $ver = $a.Version } } }
                    if (-not $ver -and $hit.PathName) {
                        $exe = ''
                        if ("$($hit.PathName)" -match '^\s*"([^"]+)"') { $exe = $Matches[1] } elseif ("$($hit.PathName)" -match '^\s*(\S+\.exe)') { $exe = $Matches[1] }
                        if ($exe) { $fi = & $file $exe; if ($fi -and $fi.Version) { $ver = "$($fi.Version)" } }
                    }
                    foreach ($d in @($spec.Drivers)) {
                        if (-not $d) { continue }
                        $dr = Get-CimInstance -CimSession $s -ClassName Win32_SystemDriver -Filter "Name='$d'" -ErrorAction SilentlyContinue
                        if (-not $dr -or $dr.State -ne 'Running') { $dd += $d }
                    }
                    foreach ($port in @($spec.Ports)) {
                        if (-not $port) { continue }
                        $tc = New-Object System.Net.Sockets.TcpClient
                        try { $ar = $tc.BeginConnect($conn, [int]$port, $null, $null); if (-not ($ar.AsyncWaitHandle.WaitOne($A.TimeoutMs) -and $tc.Connected)) { $pc += "$port not reachable from this laptop (agent not listening, or a firewall)" } }
                        catch { $pc += "$port not reachable from this laptop (agent not listening, or a firewall)" } finally { $tc.Close() }
                    }
                    if ($spec.Log) { $lf = & $file $spec.Log; if ($lf -and $lf.LastModified) { $age = ((Get-Date) - [datetime]$lf.LastModified).TotalHours } }
                }
                $v = Get-AgentVerdict $hit $ver $dd $pc $age $spec
                $inv[$k] = $v.Text
                $agents[$k] = [pscustomobject]@{ Status = $v.Status; State = $v.State; StartMode = $v.StartMode; Version = $v.Version; Issues = $v.Issues }
                if ($v.Status -ne 'OK') { $bad += ($k + ' ' + $v.Status) }
            }
            $r.Agents = [pscustomobject]$agents
            $r.AgentSummary = if ($bad) { $bad -join ', ' } else { 'all OK' }
        } catch { & $say "agent health could not be read: $($_.Exception.Message)" }
    } elseif ($A.Services -and $A.Services.Count) {
        try {
            $svc = @(Get-CimInstance -CimSession $s -ClassName Win32_Service -Property Name, DisplayName, State -ErrorAction Stop)
            foreach ($k in @($A.Services.Keys)) {
                $hit = $null
                foreach ($pat in @($A.Services[$k])) { if (-not $hit) { $hit = $svc | Where-Object { $_.Name -like $pat -or $_.DisplayName -like $pat } | Select-Object -First 1 } }
                $inv[$k] = if (-not $hit) { 'Not installed' } elseif ($hit.State -eq 'Running') { 'Running' } else { "Installed ($($hit.State))" }
            }
        } catch { }
    }
    # Same rule as the Extractor (Get-TlsLegacyText): Enabled / DisabledByDefault, else the default of that Windows build
    $rd = { param($t, $n) $q = & $reg 'GetDWORDValue' @{ hDefKey = $hk; sSubKeyName = "SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS $t\Server"; sValueName = $n }; if ($q.ReturnValue -eq 0) { [int]$q.uValue } else { $null } }
    if (Get-Command Get-TlsLegacyText -ErrorAction SilentlyContinue) { $inv.TlsLegacyDisabled = Get-TlsLegacyText "$($r.Build)" $rd }
    $r.Inv = [pscustomobject]$inv

    # Watched software (only names matching Fleet.SoftwareWatch)
    if ($A.Watch) {
        & $say 'installed software (watch list)'
        $found = @()
        foreach ($app in @(& $getApps)) {
            foreach ($w in $A.Watch) { if ($app.Name -like $w) { $found += "$($app.Name) $($app.Version)".Trim(); break } }
        }
        $r.Software = (@($found | Sort-Object -Unique)) -join '; '
    }
} catch {
    if ($r.Reachable -ne 'Yes') { $r.Reachable = 'Partial' }
    $r.Error = "$($r.Route): $($_.Exception.Message)"
    & $say "WMI error: $($_.Exception.Message)"
} finally { if ($s) { Remove-CimSession -CimSession $s -ErrorAction SilentlyContinue } }
[pscustomobject]$r
'@
    # Paste the Extractor's verdict and TLS functions in (same rules on the host and from the laptop)
    $verdict = ''
    try {
        $agent = Join-Path $script:ModuleRoot 'Resources\VmmHostAgent.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($agent, [ref]$null, [ref]$null)
        foreach ($name in 'Get-AgentVerdict', 'Get-TlsLegacyText') {
            $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
            if ($fn) { $verdict += $fn.Extent.Text + "`r`n" }
        }
    } catch { }
    $text.Replace('# VMM-AGENTVERDICT', $verdict)
}
