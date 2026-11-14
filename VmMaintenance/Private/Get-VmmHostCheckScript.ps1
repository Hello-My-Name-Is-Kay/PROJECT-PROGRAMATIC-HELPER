function Get-VmmHostCheckScript {
    # Self-contained check run per host inside a runspace. Read-only: DNS, ping, TCP ports, then CIM over
    # DCOM (same transport as Get-WmiObject) for OS, model, C:, Azure agent, SQL instances, pending
    # reboot and watched software (registry Uninstall keys - never Win32_Product, which triggers MSI repairs).
    [CmdletBinding()]
    param()
    @'
param($Name, $A)
$r = [ordered]@{
    Name = $Name; CheckedAt = (Get-Date).ToUniversalTime().ToString('o'); IPv4 = $null; Ping = 'No'; Ports = ''
    Reachable = 'No'; OS = $null; Lang = $null; Version = $null; Build = $null; SP = $null; LastBoot = $null
    Manufacturer = $null; Model = $null; Platform = $null; CTotalGB = $null; CFreeGB = $null
    PendingReboot = $null; Sql = ''; Software = ''; Inv = $null; Error = $null
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
foreach ($port in $A.Ports) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $ar = $c.BeginConnect($conn, [int]$port, $null, $null); if ($ar.AsyncWaitHandle.WaitOne($A.TimeoutMs) -and $c.Connected) { $open += $port } } catch { } finally { $c.Close() }
}
$r.Ports = $open -join ','
& $say ("ping {0}, open ports: {1}" -f $r.Ping, $(if ($open) { $open -join ',' } else { 'none' }))
if ($open -notcontains 135) {
    & $say 'stopped: TCP 135 (RPC) closed, WMI checks skipped'
    $r.Reachable = if ($r.Ping -eq 'Yes' -or $open) { 'Partial' } else { 'No' }
    $r.Error = 'TCP 135 (RPC) closed: WMI/DCOM checks skipped. Host down, firewall, or RDP-only access - use the RDP collector.'
    return [pscustomobject]$r
}

$s = $null
try {
    & $say 'connecting over WMI/DCOM'
    $sp = @{ ComputerName = $conn; SessionOption = (New-CimSessionOption -Protocol Dcom); ErrorAction = 'Stop'; OperationTimeoutSec = 30 }
    if ($A.Credential) { $sp.Credential = $A.Credential }
    $s = New-CimSession @sp
    $os = Get-CimInstance -CimSession $s -ClassName Win32_OperatingSystem -ErrorAction Stop
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
    $inst = & $reg 'EnumValues' @{ hDefKey = $hk; sSubKeyName = 'SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' }
    if ($inst.ReturnValue -eq 0 -and $inst.sNames) {
        $r.Sql = (@(foreach ($n in $inst.sNames) {
            $id = & $str 'SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' $n
            $ver = & $str "SOFTWARE\Microsoft\Microsoft SQL Server\$id\Setup" 'PatchLevel'
            $ed  = & $str "SOFTWARE\Microsoft\Microsoft SQL Server\$id\Setup" 'Edition'
            "$n $ver $ed".Trim()
        })) -join '; '
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
    & $say 'Windows licence query (can take up to 90 s)'
    try {
        $lp = @(Get-CimInstance -CimSession $s -ClassName SoftwareLicensingProduct -Filter "Name LIKE 'Windows%' AND PartialProductKey IS NOT NULL" -Property LicenseStatus -OperationTimeoutSec 90 -ErrorAction Stop)
        $inv.WindowsLicense = if ($lp.Count) { $names[[int]$lp[0].LicenseStatus] } else { 'No product key installed' }
    } catch { }
    if ($A.Services -and $A.Services.Count) {
        & $say 'inventory agent services'
        try {
            $svc = @(Get-CimInstance -CimSession $s -ClassName Win32_Service -Property Name, DisplayName, State -ErrorAction Stop)
            foreach ($k in @($A.Services.Keys)) {
                $hit = $null
                foreach ($pat in @($A.Services[$k])) { if (-not $hit) { $hit = $svc | Where-Object { $_.Name -like $pat -or $_.DisplayName -like $pat } | Select-Object -First 1 } }
                $inv[$k] = if (-not $hit) { 'Not installed' } elseif ($hit.State -eq 'Running') { 'Running' } else { "Installed ($($hit.State))" }
            }
        } catch { }
    }
    $on = @()
    foreach ($t in '1.0', '1.1') {
        $q = & $reg 'GetDWORDValue' @{ hDefKey = $hk; sSubKeyName = "SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS $t\Server"; sValueName = 'Enabled' }
        if (-not ($q.ReturnValue -eq 0 -and $q.uValue -eq 0)) { $on += "TLS $t" }   # no key = Windows default = enabled
    }
    $inv.TlsLegacyDisabled = if ($on) { "No ($($on -join ', ') enabled)" } else { 'Yes' }
    $r.Inv = [pscustomobject]$inv

    # Watched software (only names matching Fleet.SoftwareWatch)
    if ($A.Watch) {
        & $say 'installed software (watch list)'
        $found = @()
        foreach ($root in 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
            $keys = & $reg 'EnumKey' @{ hDefKey = $hk; sSubKeyName = $root }
            if ($keys.ReturnValue -ne 0) { continue }
            foreach ($k in $keys.sNames) {
                $dn = & $str "$root\$k" 'DisplayName'
                if (-not $dn) { continue }
                foreach ($w in $A.Watch) { if ($dn -like $w) { $found += "$dn $(& $str "$root\$k" 'DisplayVersion')".Trim(); break } }
            }
        }
        $r.Software = (@($found | Sort-Object -Unique)) -join '; '
    }
} catch {
    if ($r.Reachable -ne 'Yes') { $r.Reachable = 'Partial' }
    $r.Error = "CIM/DCOM: $($_.Exception.Message)"
    & $say "WMI error: $($_.Exception.Message)"
} finally { if ($s) { Remove-CimSession -CimSession $s -ErrorAction SilentlyContinue } }
[pscustomobject]$r
'@
}
