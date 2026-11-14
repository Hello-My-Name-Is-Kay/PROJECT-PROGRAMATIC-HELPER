function Get-VmmCachedSqlUpdate {
    # One KB in the download cache: <cache>\SQL\<KB>\. Downloads it once (dbatools Save-DbaKbUpdate,
    # x64, the install language for language-specific service packs), checks Microsoft's Authenticode
    # signature (anything else is deleted) and writes a .sha256 next to it. Later calls, for any host,
    # reuse the file. Returns the file(s) for -Lang.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Kb, [string]$Lang = 'ENU', [Parameter(Mandatory)][string]$CacheDir)
    $dir = Join-Path (Join-Path $CacheDir 'SQL') $Kb
    $langs = 'ENU|FRA|ESN|DEU|ITA|JPN|KOR|RUS|CHS|CHT|PTB'
    $pick = {
        # Language-neutral files (CUs) or the file for this language (SPs before SQL 2017)
        @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Extension -ne '.sha256' -and $_.Name -notmatch '\.part$' -and $_.Name -notmatch '(?i)x86|ia64' -and
            ($_.Name -notmatch "(?i)-($langs)\." -or $_.Name -match "(?i)-$Lang\.")
        })
    }
    # [SEC] Only files signed by Microsoft stay in the cache. Checked once per file (also for files put
    # there by hand); the .sha256 written afterwards marks it as checked and lets staging verify copies.
    $verify = {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne '.sha256' -and $_.Name -notmatch '\.part$' })) {
            if (Test-Path -LiteralPath "$($f.FullName).sha256") { continue }
            $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
            if ($sig.Status -ne 'Valid' -or "$($sig.SignerCertificate.Subject)" -notmatch 'O=Microsoft Corporation') {
                Remove-Item -LiteralPath $f.FullName -Force
                throw (New-VmmErrorRecord -Activity "$($f.Name) is not validly signed by Microsoft (status $($sig.Status)); deleted from the cache." -Target $dir `
                    -Cause 'Download damaged, a wrong file put there by hand, or something in between (proxy) changed it.' -Fix 'Run the fetch again; if it repeats, download by hand from the Microsoft Update Catalog and tell your security team.' -Category SecurityError -ErrorId 'VmmBadSignature')
            }
            Set-Content -LiteralPath "$($f.FullName).sha256" -Value ((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash + '  ' + $f.Name) -Encoding ASCII
        }
    }
    $have = & $pick
    if ($have) { & $verify; $have = & $pick }
    if ($have) { Write-VmmLog "$Kb ($Lang): already in the cache, not downloaded again" -Level Trace; return $have }
    if (-not $PSCmdlet.ShouldProcess($dir, "Download $Kb ($Lang)")) { return }
    if (-not (Get-Command Save-DbaKbUpdate -ErrorAction SilentlyContinue)) {
        throw (New-VmmErrorRecord -Activity 'dbatools is not installed (needed to find and download SQL Server updates).' `
            -Fix 'Install it once: Install-Module dbatools -Scope CurrentUser   (no admin needed; then run the fetch again)' -Category NotInstalled -ErrorId 'VmmNoDbatools')
    }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-VmmLog "$Kb ($Lang): downloading from Microsoft into the cache..." -Level Info
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $null = Save-DbaKbUpdate -Name $Kb -Path $dir -Architecture x64 -Language $Lang -EnableException }
    catch { Write-VmmLog "$Kb`: download with language $Lang failed ($($_.Exception.Message)); trying the language-neutral file" -Level Trace }
    if (-not (& $pick)) {
        try { $null = Save-DbaKbUpdate -Name $Kb -Path $dir -Architecture x64 -EnableException }
        catch {
            throw (New-VmmErrorRecord -Activity "Download of $Kb failed." -Target $dir -Exception $_.Exception `
                -Cause 'No internet access from this laptop (proxy/VPN split tunnel), the Microsoft Update Catalog is down, or the KB has no x64 file.' `
                -Fix "Open https://www.catalog.update.microsoft.com/Search.aspx?q=$Kb in a browser. If it works there, download the x64 file by hand into $dir and run the fetch again." -Category ConnectionError -ErrorId 'VmmDownload')
        }
    }
    & $verify
    $have = & $pick
    Write-VmmLog ("{0} ({1}): {2} file(s), {3:N0} MB in {4:N0} s, Microsoft signature valid" -f $Kb, $Lang, $have.Count, ((@($have) | Measure-Object Length -Sum).Sum / 1MB), $sw.Elapsed.TotalSeconds) -Level Success
    $have
}
