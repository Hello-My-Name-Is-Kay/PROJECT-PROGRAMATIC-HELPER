function Get-VmmLansweeperDiskSpace {
    <#
    .SYNOPSIS
        Pulls C: size/free space, domain, IP and VM platform from the Lansweeper database for a
        list of servers.
    .DESCRIPTION
        Queries Lansweeper only (tblAssets, tblDiskdrives, tblAssetCustom). Columns:
            ComputerName, Domain, IPAddress, VMPlatform, SizeGB, FreeGB, Status, LastSeen

        VMPlatform comes from manufacturer/model, with the primary NIC's MAC prefix used to tell Azure
        from on-prem Hyper-V. "(MAC only)" = manufacturer/model said nothing, only the MAC was used.

        Status (free space on C:):
            CRITICAL  under -CriticalGB  (below OS minimum; upgrade likely to fail or be blocked)
            LOW       under -OkGB        (may work, little margin for setup + Windows.old)
            OK        -OkGB or more
        Names Lansweeper doesn't know are reported as "Not found in Lansweeper".
        Sorted worst first, shown on screen and exported to CSV.

        SQL Server authentication. You are prompted for the login unless you pass -Credential.
    .EXAMPLE
        Get-VmmLansweeperDiskSpace
    .EXAMPLE
        $cred = Get-Credential
        Get-VmmLansweeperDiskSpace -ComputerName srv01, srv02 -Credential $cred
    #>
    [CmdletBinding()]
    param(
        [string[]]$ComputerName,
        [string]$ServerList,
        [string]$SqlInstance,
        [string]$Database,
        [int]$CriticalGB,
        [int]$OkGB,
        [string]$OutCsv,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$PassThru
    )
    if (-not $PSBoundParameters.ContainsKey('SqlInstance')) { $SqlInstance = Get-VmmSetting 'Lansweeper.SqlInstance' -Required }
    if (-not $PSBoundParameters.ContainsKey('Database'))    { $Database    = Get-VmmSetting 'Lansweeper.Database' -Default 'lansweeperdb' }
    if (-not $PSBoundParameters.ContainsKey('CriticalGB'))  { $CriticalGB  = Get-VmmSetting 'Lansweeper.CriticalGB' -Default 32 }
    if (-not $PSBoundParameters.ContainsKey('OkGB'))        { $OkGB        = Get-VmmSetting 'Lansweeper.OkGB' -Default 40 }
    $trustCert = [bool](Get-VmmSetting 'Lansweeper.TrustServerCertificate' -Default $false)

    if ($CriticalGB -gt $OkGB) {
        throw (New-VmmErrorRecord -Activity 'Free-space thresholds are inverted.' -Target "CriticalGB=$CriticalGB OkGB=$OkGB" `
            -Fix 'CriticalGB must be lower than or equal to OkGB.' -Category InvalidArgument)
    }

    $servers = @(Read-VmmServerList -Name $ComputerName -Path $ServerList -ListKey 'DiskSpace' -Case Upper)

    # --- SQL login: asked once per session, memory only (never stored - no username in the config either)
    if (-not $Credential) { $Credential = Get-VmmSessionCredential -Purpose Sql }
    if (-not $Credential) {
        throw (New-VmmErrorRecord -Activity 'A SQL login is required.' -Target $SqlInstance `
            -Cause 'The credential prompt was cancelled.' -Fix 'Re-run and enter the SQL login, or pass -Credential.' -Category AuthenticationError)
    }

    # Parameterized IN list (@p0, @p1, ...) so names are never concatenated into SQL.
    # Batches stay well under SQL Server's 2100-parameter limit.
    $template = @'
SELECT
    a.AssetName,
    a.Domain,
    a.IPAddress,
    a.Mac,
    c.Manufacturer,
    c.Model,
    CAST(CAST(d.Size      AS DECIMAL(20,0)) / 1073741824.0 AS DECIMAL(10,1)) AS SizeGB,
    CAST(CAST(d.Freespace AS DECIMAL(20,0)) / 1073741824.0 AS DECIMAL(10,1)) AS FreeGB,
    a.Lastseen AS LastSeen
FROM tblAssets a
JOIN tblDiskdrives d       ON d.AssetID = a.AssetID
LEFT JOIN tblAssetCustom c ON c.AssetID = a.AssetID
WHERE d.Caption = 'C:'
  AND a.AssetName IN (__NAMES__)
'@
    $batchSize = 500

    $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $csb['Data Source']            = $SqlInstance
    $csb['Initial Catalog']        = $Database
    $csb['Integrated Security']    = $false
    $csb['TrustServerCertificate'] = $trustCert

    $conn = New-Object System.Data.SqlClient.SqlConnection -ArgumentList $csb.ConnectionString
    # Password goes in as a SecureString via SqlCredential, never into the connection string
    $securePwd = $Credential.Password.Copy()
    $securePwd.MakeReadOnly()
    $conn.Credential = New-Object System.Data.SqlClient.SqlCredential -ArgumentList $Credential.UserName, $securePwd

    $table = New-Object System.Data.DataTable
    try {
        try { $conn.Open() }
        catch {
            throw (New-VmmErrorRecord -Activity 'Could not connect to the Lansweeper database.' `
                -Target "$SqlInstance / $Database" -Exception $_.Exception -Category ConnectionError -ErrorId 'VmmSqlConnect')
        }
        try {
            for ($start = 0; $start -lt $servers.Count; $start += $batchSize) {
                $end   = [math]::Min($start + $batchSize, $servers.Count) - 1
                $batch = @($servers[$start..$end])
                $cmd   = $conn.CreateCommand()
                $cmd.CommandText = $template.Replace('__NAMES__', ((0..($batch.Count - 1) | ForEach-Object { "@p$_" }) -join ', '))
                for ($i = 0; $i -lt $batch.Count; $i++) { [void]$cmd.Parameters.AddWithValue("@p$i", [string]$batch[$i]) }
                Write-VmmLog 'Lansweeper: query sent, waiting for rows' -Level Trace
                $table.Load($cmd.ExecuteReader())
                Write-VmmLog "Lansweeper: $($table.Rows.Count) row(s) received" -Level Trace
            }
        } catch {
            throw (New-VmmErrorRecord -Activity 'Lansweeper query failed.' -Target "$SqlInstance / $Database" -Exception $_.Exception `
                -Category ReadError -ErrorId 'VmmSqlQuery')
        }
    } finally {
        $conn.Close()
        $conn.Dispose()
        $securePwd.Dispose()   # [SEC] the copy made for SqlCredential
    }

    # --- Index results by name (case-insensitive)
    $found = @{}
    foreach ($row in $table.Rows) { $found[([string]$row.AssetName).ToUpper()] = $row }

    $results = foreach ($name in $servers) {
        if ($found.ContainsKey($name)) {
            $r    = $found[$name]
            $free = ConvertFrom-VmmDbNull $r.FreeGB
            [pscustomobject]@{
                ComputerName = $r.AssetName
                Domain       = ConvertFrom-VmmDbNull $r.Domain
                IPAddress    = ConvertFrom-VmmDbNull $r.IPAddress
                VMPlatform   = Get-VmmVmPlatform -Manufacturer (ConvertFrom-VmmDbNull $r.Manufacturer) `
                                                 -Model        (ConvertFrom-VmmDbNull $r.Model) `
                                                 -Mac          (ConvertFrom-VmmDbNull $r.Mac)
                SizeGB       = ConvertFrom-VmmDbNull $r.SizeGB
                FreeGB       = $free
                Status       = if     ($null -eq $free)       { 'No disk data' }
                               elseif ($free -lt $CriticalGB) { 'CRITICAL' }
                               elseif ($free -lt $OkGB)       { 'LOW' }
                               else                           { 'OK' }
                LastSeen     = ConvertFrom-VmmDbNull $r.LastSeen
            }
        } else {
            [pscustomobject]@{
                ComputerName = $name; Domain = $null; IPAddress = $null; VMPlatform = $null
                SizeGB = $null; FreeGB = $null; Status = 'Not found in Lansweeper'; LastSeen = $null
            }
        }
    }

    # --- Worst first: CRITICAL, LOW, OK, then the rest; free space ascending within each group
    $severity = @{ 'CRITICAL' = 0; 'LOW' = 1; 'OK' = 2 }
    $results = @($results | Sort-Object @{ Expression = { if ($severity.ContainsKey($_.Status)) { $severity[$_.Status] } else { 3 } } },
                                        @{ Expression = { $_.FreeGB } },
                                        ComputerName)

    $results | Format-Table -AutoSize | Out-VmmHost
    Export-VmmCsv -InputObject $results -Path (Resolve-VmmOutputPath -Path $OutCsv -BaseName 'LansweeperDiskSpace')

    $crit = @($results | Where-Object Status -eq 'CRITICAL').Count
    $low  = @($results | Where-Object Status -eq 'LOW').Count
    $nf   = @($results | Where-Object Status -eq 'Not found in Lansweeper').Count
    if ($crit) { Write-VmmLog "$crit server(s) CRITICAL (< $CriticalGB GB free on C:)" -Level Error }
    if ($low)  { Write-VmmLog "$low server(s) LOW (< $OkGB GB free on C:)" -Level Warn }
    if ($nf)   { Write-VmmLog "$nf name(s) not found in Lansweeper - check spelling or whether the asset was ever scanned" -Level Warn }
    if (-not ($crit -or $low -or $nf)) { Write-VmmLog "All $($results.Count) server(s) OK" -Level Success }
    if ($PassThru) { $results }
}
