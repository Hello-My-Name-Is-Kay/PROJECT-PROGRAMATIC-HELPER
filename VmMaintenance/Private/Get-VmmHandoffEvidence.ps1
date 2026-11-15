function Get-VmmHandoffEvidence {
    # After a hands-on copy: are the files really on the host? Tries, in this order, and stops at the first
    # that proves every file:
    #   1. the VMMSTAGE1 report from the handoff script (-Pasted, else the clipboard)   size + SHA256 read on the host
    #   2. WinRM / WinRM-SSL (Invoke-Command, read-only)                               size + SHA256 read on the host
    #   3. admin share \\host\C$ (TCP 445)                                              size (+ SHA256 under Handoff.ShareHashMaxMB)
    #   4. WMI over DCOM (CIM_DataFile, TCP 135)                                        size only
    # Size-only proof counts only for files with no known SHA256, unless Handoff.AcceptSizeOnly = $true.
    # Returns Method, Verified and the per-file rows (Compare-VmmHandoffFile) of the best attempt, or $null.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][object[]]$Items, [Parameter(Mandatory)][string]$Target,
          [string]$Pasted, [switch]$NoNetwork)
    $name = $Record.Name
    $addr = if ($Record.PSObject.Properties['Fqdn'] -and $Record.Fqdn) { $Record.Fqdn } else { $Record.Name }
    $names = @($Items | ForEach-Object { $_.DestName })
    $sizeOnly = [bool](Get-VmmSetting 'Handoff.AcceptSizeOnly' -Default $false)
    $script:VmmHandoffBest = $null
    $judge = {
        param($Method, $Reported)
        $rows = @(Compare-VmmHandoffFile -Expected $Items -Reported @($Reported) -Method $Method)
        $okStates = if ($sizeOnly) { @('OK', 'NotHashed') } else { @('OK') }
        $res = [pscustomobject]@{ Method = $Method; Verified = (-not @($rows | Where-Object { $_.Status -notin $okStates }).Count); Rows = $rows
                                  Good = @($rows | Where-Object { $_.Status -in $okStates }).Count }
        if (-not $script:VmmHandoffBest -or $res.Good -gt $script:VmmHandoffBest.Good) { $script:VmmHandoffBest = $res }
        $res
    }

    # 1. Report line from the host (pasted, or on the clipboard via the RDP clipboard)
    $text = $Pasted
    if (-not $text) { $text = try { (@(Get-Clipboard -ErrorAction Stop) -join "`n") } catch { '' } }
    $rep = @(ConvertFrom-VmmHandoffReport -Text $text -HostName $name)
    if ($rep.Count) {
        $r = & $judge 'host report (VMMSTAGE1)' $rep
        if ($r.Verified) { return $r }
    } else { Write-VmmLog "[$name] no VMMSTAGE1 report for this host on the clipboard" -Level Trace }
    if ($NoNetwork) { return $script:VmmHandoffBest }

    # Credential: asked once per session by Get-VmmSessionCredential (memory only), $null = current identity

    # 2. WinRM: size and SHA256 read on the host itself (PowerShell 2.0 compatible, read-only)
    $block = {
        param($T, $Names)
        foreach ($n in $Names) {
            $d = Join-Path $T $n
            if (Test-Path -LiteralPath $d) {
                $len = (Get-Item -LiteralPath $d).Length
                $st = [IO.File]::OpenRead($d)
                try { $sha = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($st) | ForEach-Object { $_.ToString('X2') }) } finally { $st.Close() }
                New-Object PSObject -Property @{ DestName = $n; Size = $len; Sha256 = $sha }
            } else { New-Object PSObject -Property @{ DestName = $n; Size = -1; Sha256 = '' } }
        }
    }
    foreach ($route in @(@{ N = 'WinRM'; P = 5985 }, @{ N = 'WinRM-SSL'; P = 5986 })) {
        if (-not (Test-VmmTcpPort -ComputerName $addr -Port $route.P)) { Write-VmmLog "[$name] verify: $($route.N) port $($route.P) closed" -Level Trace; continue }
        try {
            $ic = @{ ComputerName = $addr; ScriptBlock = $block; ArgumentList = @($Target, $names); ErrorAction = 'Stop' }
            $cred = Get-VmmSessionCredential -Purpose Windows
            if ($cred) { $ic.Credential = $cred }
            if ($route.N -eq 'WinRM-SSL') { $ic.UseSSL = $true }
            Write-VmmLog "[$name] verifying over $($route.N): size and SHA256 are read on the host (large images take a minute)..." -Level Info
            $rep = @(Invoke-Command @ic | ForEach-Object { [pscustomobject]@{ DestName = "$($_.DestName)"; Size = [long]$_.Size; Sha256 = "$($_.Sha256)" } })
            $r = & $judge $route.N $rep
            if ($r.Verified) { return $r }
            break
        } catch { Write-VmmLog "[$name] verify over $($route.N) failed: $(($_.Exception.Message -split "`n")[0])" -Level Muted }
    }

    # 3. Admin share
    if ($Target -match '^([A-Za-z]):\\(.*)$' -and (Test-VmmTcpPort -ComputerName $addr -Port 445)) {
        $uncRoot = "\\$addr\$($Matches[1])`$"; $sub = $Matches[2]
        $drive = 'VmmVerify' + (Get-Random -Maximum 99999)
        $max = [double](Get-VmmSetting 'Handoff.ShareHashMaxMB' -Default 256)
        try {
            $dp = @{ Name = $drive; PSProvider = 'FileSystem'; Root = $uncRoot; ErrorAction = 'Stop' }
            $cred = Get-VmmSessionCredential -Purpose Windows
            if ($cred) { $dp.Credential = $cred }
            New-PSDrive @dp | Out-Null
            $rep = foreach ($n in $names) {
                $p = "$($drive):\$sub\$n"
                if (Test-Path -LiteralPath $p -PathType Leaf) {
                    $len = (Get-Item -LiteralPath $p).Length
                    $sha = if ($len / 1MB -le $max) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } else { '' }
                    [pscustomobject]@{ DestName = $n; Size = [long]$len; Sha256 = $sha }
                } else { [pscustomobject]@{ DestName = $n; Size = [long]-1; Sha256 = '' } }
            }
            $r = & $judge 'admin share' @($rep)
            if ($r.Verified) { return $r }
        } catch { Write-VmmLog "[$name] verify over the admin share failed: $(($_.Exception.Message -split "`n")[0])" -Level Muted }
        finally { Remove-PSDrive -Name $drive -Force -ErrorAction SilentlyContinue }
    } else { Write-VmmLog "[$name] verify: admin share (TCP 445) closed" -Level Trace }

    # 4. WMI over DCOM: file sizes only
    if ((Get-Command New-CimSession -ErrorAction SilentlyContinue) -and (Test-VmmTcpPort -ComputerName $addr -Port 135)) {
        $s = $null
        try {
            $sp = @{ ComputerName = $addr; SessionOption = (New-CimSessionOption -Protocol Dcom); ErrorAction = 'Stop' }
            $cred = Get-VmmSessionCredential -Purpose Windows
            if ($cred) { $sp.Credential = $cred }
            $s = New-CimSession @sp
            $rep = foreach ($n in $names) {
                $wql = (Join-Path $Target $n) -replace '\\', '\\' -replace "'", "\'"
                $f = Get-CimInstance -CimSession $s -ClassName CIM_DataFile -Filter "Name='$wql'" -ErrorAction SilentlyContinue | Select-Object -First 1
                [pscustomobject]@{ DestName = $n; Size = $(if ($f) { [long]$f.FileSize } else { [long]-1 }); Sha256 = '' }
            }
            $r = & $judge 'WMI (DCOM, size only)' @($rep)
            if ($r.Verified) { return $r }
        } catch { Write-VmmLog "[$name] verify over WMI failed: $(($_.Exception.Message -split "`n")[0])" -Level Muted }
        finally { if ($s) { Remove-CimSession -CimSession $s -ErrorAction SilentlyContinue } }
    }
    $script:VmmHandoffBest
}
