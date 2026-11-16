<#
.SYNOPSIS
    Pre-commit / pre-release check: fails if the repository contains anything that belongs only on
    your own disk - GUIDs, IPv4 addresses, e-mail addresses, tokens and keys, passwords in connection
    strings, Azure resource IDs, or any value/name from your local config and server lists.
.DESCRIPTION
    Scans every file under the repository root except gitignored local files and binaries.
    Reads your local config (same search order as the module) and every server list it points to,
    and reports each file:line where one of those values appears. Exit code 1 when anything is found.

    -History also scans every line ever added in the git history (all branches and tags) and every
    commit message, with the same patterns and local values. Run it before a release: a value that
    was committed once and removed later is still readable in the history.

    Known test fixtures (fake passwords used to prove the log masking) are allow-listed below.
.EXAMPLE
    .\Tools\Test-Sanitized.ps1
.EXAMPLE
    .\Tools\Test-Sanitized.ps1 -History
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$History
)

$repo = Split-Path -Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'VmMaintenance\VmMaintenance.psd1') -Force -ErrorAction Stop

# --- Values that must never appear in the repository
$needles = New-Object System.Collections.Generic.List[string]
$cfg = $null
try { $cfg = if ($ConfigPath) { Import-VmmConfig -Path $ConfigPath -PassThru } else { Import-VmmConfig -PassThru } }
catch { Write-Host "No local config loaded - only generic patterns are checked. ($($_.Exception.Message.Split([Environment]::NewLine)[0]))" -ForegroundColor Yellow }

function Add-Needle($v) {
    if ($null -eq $v) { return }
    if ($v -is [System.Collections.IDictionary]) { foreach ($k in $v.Keys) { Add-Needle $v[$k] }; return }   # values only; keys are schema names
    if ($v -is [array]) { foreach ($i in $v) { Add-Needle $i }; return }
    $s = "$v".Trim()
    # Skip short/generic values (tag names, numbers, SKU names, default paths)
    if ($s.Length -lt 6 -or $s -match '^\d+$' -or $s -match '^<.+>$' -or $s -match '%APPDATA%|^C:\\Temp') { return }
    if ($s -in 'lansweeperdb', 'Standard_LRS', 'MicrosoftWindowsServer', 'WindowsServerUpgrade', 'server2019Upgrade', 'Upgrade2019', 'RetentionDays', 'Project') { return }
    if (-not $needles.Contains($s)) { $needles.Add($s) }
}

if ($cfg) {
    Add-Needle $cfg.Azure
    Add-Needle $cfg.Lansweeper.SqlInstance
    Add-Needle $cfg.Staging.SourceShare
    Add-Needle $cfg.Vpn.Profile
    Add-Needle $cfg.Vpn.ProbeHost
    Add-Needle $cfg.Snapshots.Tags
    foreach ($k in $cfg.Snapshots.Tags.Keys) { Add-Needle ([string]$k) }   # custom tag names can be org-specific
    Add-Needle $cfg.Snapshots.CleanupTagValue
    foreach ($p in $cfg.ServerLists.Values) {
        $f = [Environment]::ExpandEnvironmentVariables("$p")
        if (Test-Path -LiteralPath $f) {
            Get-Content -LiteralPath $f | ForEach-Object { ($_ -split '#')[0].Trim() } | Where-Object { $_ } | ForEach-Object { Add-Needle $_; Add-Needle (($_ -split '\.')[0]) }
        }
    }
}

# --- Generic patterns. Allow = values that are known placeholders or test fixtures, never real data.
$patterns = @(
    @{ Name = 'GUID';     Rx = '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'; Allow = '^00000000-0000-0000-0000-000000000000$' }
    @{ Name = 'IPv4';     Rx = '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b'; Allow = '^(127\.0\.0\.1|0\.0\.0\.0)$' }
    @{ Name = 'E-mail';   Rx = '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b'; Allow = '@(example\.(com|org|net)|users\.noreply\.github\.com)$|^noreply@anthropic\.com$' }
    @{ Name = 'Token';    Rx = '\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|xox[abpr]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}|hf_[A-Za-z0-9]{30,}|gsk_[A-Za-z0-9]{30,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,})'; Allow = $null }
    @{ Name = 'Key';      Rx = '-----BEGIN [A-Z ]*PRIVATE KEY-----|\bAccountKey=[A-Za-z0-9+/=]{20,}|\bSharedAccessSignature=|\bsig=[A-Za-z0-9%+/=]{30,}'; Allow = $null }
    @{ Name = 'Password'; Rx = '(?i)\b(?:password|pwd)\s*=\s*(?![\$<*''"(@{\\]|\s)[^;\s''"]{3,}'; Allow = '(?i)=\s*(Hunter2|abc123)$' }
    @{ Name = 'AzureId';  Rx = '(?i)/subscriptions/(?![<$(*{])[^/\s''"]{6,}'; Allow = $null }
)

function Test-VmmLeakLine([string]$Line) {
    $found = @()
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($Line, $p.Rx)) {
            if ($p.Allow -and $m.Value -match $p.Allow) { continue }
            $found += "[$($p.Name)] $($m.Value)"
        }
    }
    foreach ($s in $needles) {
        if ($Line.IndexOf($s, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $found += "[local value] $s" }
    }
    $found
}

# --- Working tree
$sep   = [regex]::Escape([IO.Path]::DirectorySeparatorChar)
$skip  = "${sep}\.git${sep}|${sep}config${sep}lists${sep}|\.local\.|${sep}config${sep}config\.psd1$|\.(csv|log|zip|png|jpg|ico|xml)$"
$files = Get-ChildItem -LiteralPath $repo -Recurse -File -Force | Where-Object { $_.FullName -notmatch $skip }
$hits  = 0
foreach ($file in $files) {
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
        $n++
        if ($file.Name -eq 'VmMaintenance.psd1' -and $line -match '^\s*GUID\s*=') { continue }   # module identity, not a secret
        foreach ($h in (Test-VmmLeakLine $line)) { $hits++; Write-Host "$($file.FullName):$n  $h" -ForegroundColor Red }
    }
}

# --- Git history (every added line and every commit message, all refs)
$histLines = 0
if ($History) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { Write-Host 'git not found: history not checked.' -ForegroundColor Yellow; $hits++ }
    elseif ((& git -C $repo rev-parse --is-inside-work-tree 2>$null) -ne 'true') { Write-Host "Not a git repository: $repo - history not checked." -ForegroundColor Red; $hits++ }
    else {
        # A shallow clone has only part of the history: a "clean" result would not cover the rest
        if ((& git -C $repo rev-parse --is-shallow-repository 2>$null) -eq 'true') { Write-Host 'Shallow clone: only part of the history is here. Fetch it all (git fetch --unshallow, or CI fetch-depth: 0) and run again.' -ForegroundColor Red; $hits++ }
        $commit = ''; $path = ''
        $log = & git -C $repo log --all -p --no-color --no-ext-diff --format='commit %H' 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "git log failed (exit code $LASTEXITCODE): history not checked." -ForegroundColor Red; $hits++; $log = @() }
        foreach ($line in $log) {
            if ($line -like 'commit *' -and $line.Length -eq 47) { $commit = $line.Substring(7, 7); continue }
            if ($line -like '+++ b/*') { $path = $line.Substring(6); continue }
            if (-not $line.StartsWith('+') -or $line.StartsWith('+++')) { continue }
            if ($path -match '\.(png|jpg|ico|zip)$') { continue }
            $histLines++
            $text = $line.Substring(1)
            if ($path -eq 'VmMaintenance/VmMaintenance.psd1' -and $text -match '^\s*GUID\s*=') { continue }
            foreach ($h in (Test-VmmLeakLine $text)) { $hits++; Write-Host "history $commit ${path}:  $h" -ForegroundColor Red }
        }
        $msgs = & git -C $repo log --all --format='%h %an <%ae> %B' 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "git log failed (exit code $LASTEXITCODE): commit messages not checked." -ForegroundColor Red; $hits++; $msgs = @() }
        foreach ($line in $msgs) {
            $histLines++
            foreach ($h in (Test-VmmLeakLine $line)) { $hits++; Write-Host "commit message: $line  $h" -ForegroundColor Red }
        }
    }
}

if ($hits) {
    Write-Host "$hits problem(s): sensitive values found, or a check could not run (see above). Move values to your local config or server lists before committing." -ForegroundColor Red
    if ($History) { Write-Host 'A value found only in the history needs the history rewritten (ask before doing that): removing it from the files is not enough.' -ForegroundColor Red }
    exit 1
}
$histText = if ($History) { " and $histLines history line(s)" } else { '' }
Write-Host "Clean: $($files.Count) file(s)$histText checked against $($needles.Count) local value(s) and GUID/IPv4/e-mail/token/key/password/Azure-ID patterns." -ForegroundColor Green
