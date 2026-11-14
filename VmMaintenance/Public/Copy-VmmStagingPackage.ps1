function Copy-VmmStagingPackage {
    <#
    .SYNOPSIS
        Copies what a host needs from the media repository (OS image in its language, its own folder's
        files, extra packages) to C:\Temp on the host (creates C:\Temp),
        then verifies size and SHA256 at the destination. Allowed during business hours.
    .DESCRIPTION
        Copies go share -> this laptop -> \\host\C$\Temp (admin share, needs local admin on the host).
        Files already present with the same size (and hash, when configured) are skipped.
    .EXAMPLE
        Copy-VmmStagingPackage -HostName srv01
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$HostName)
    $store = Read-VmmStore
    $rec = Get-VmmHostRecord -Store $store -Name $HostName
    $pk = @(Test-VmmStagingSource -Record $rec -PassThru -Quiet)
    $gates = @($pk | Where-Object { $_.Gate })
    if ($gates) {
        throw (New-VmmErrorRecord -Activity 'Staging gate closed: required files are missing or wrong on the share.' -Target $rec.Name `
            -Cause (($gates | ForEach-Object { $_.Gate }) -join ' | ') -Fix 'Put the files on the share as listed, then run the Stage step again.' `
            -Category ObjectNotFound -ErrorId 'VmmStagingGate')
    }
    $target = Get-VmmSetting 'Staging.TargetFolder' -Default 'C:\Temp'
    if ($target -notmatch '^([A-Za-z]):\\(.*)$') { throw (New-VmmErrorRecord -Activity "Staging.TargetFolder '$target' is not a local path like C:\Temp." -Category InvalidArgument) }
    $hostAddr = if ($rec.PSObject.Properties['Fqdn'] -and $rec.Fqdn) { $rec.Fqdn } else { $rec.Name }
    $uncRoot = "\\$hostAddr\$($Matches[1])`$"
    $sub = $Matches[2]
    Assert-VmmVpn -Activity 'staging copy'
    $cred = Get-VmmSessionCredential -Purpose Windows
    $drive = 'VmmStage' + (Get-Random -Maximum 99999)
    $dp = @{ Name = $drive; PSProvider = 'FileSystem'; Root = $uncRoot; ErrorAction = 'Stop' }
    if ($cred) { $dp.Credential = $cred }

    try { New-PSDrive @dp | Out-Null }
    catch {
        throw (New-VmmErrorRecord -Activity "Could not open the admin share $uncRoot." -Target $rec.Name -Exception $_.Exception `
            -Cause 'No local admin rights on the host, SMB (TCP 445) blocked, or admin shares disabled.' `
            -Fix 'Check with: Test-NetConnection <host> -Port 445. If access is denied, raise a blocker report (B) and move on.' `
            -Category PermissionDenied -ErrorId 'VmmAdminShare')
    }
    $copied = @()
    try {
        $destDir = "$($drive):\$sub"
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null; Write-VmmLog "$($rec.Name): created $target" -Level Muted }
        foreach ($p in $pk) {
            $dest = Join-Path $destDir $(if ($p.DestName) { $p.DestName } else { [IO.Path]::GetFileName($p.File) })
            $srcLen = (Get-Item -LiteralPath $p.File).Length
            $needCopy = $true
            if (Test-Path -LiteralPath $dest) { if ((Get-Item -LiteralPath $dest).Length -eq $srcLen) { $needCopy = $false } }
            if ($needCopy -and $PSCmdlet.ShouldProcess("$($rec.Name):$target", "Copy $($p.Name) ($($p.SizeMB) MB)")) {
                Write-VmmLog "$($rec.Name): copying $($p.Name) ($($p.SizeMB) MB)..." -Level Info
                Copy-Item -LiteralPath $p.File -Destination $dest -Force -ErrorAction Stop
            }
            if ($p.Sha256 -and (Test-Path -LiteralPath $dest)) {
                $h = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
                if ($h -ne $p.Sha256) { throw "Hash mismatch after copy on $($rec.Name): $dest (expected $($p.Sha256), got $h). Network copy corrupted - run Stage again." }
            }
            if ($p.Note) { Write-VmmLog "$($rec.Name): $($p.Name) - $($p.Note)" -Level Warn }
            $copied += $p.Name
        }
    } finally { Remove-PSDrive -Name $drive -Force -ErrorAction SilentlyContinue }
    Write-VmmLog "$($rec.Name): staged $($copied.Count) package(s) in $target" -Level Success
    $copied
}
