<#
.SYNOPSIS
    Pre-commit check: fails if the repository contains anything that belongs only in your local
    config - GUIDs, IPv4 addresses, or any value/name from your local config and server lists.
.DESCRIPTION
    Scans every text file under the repository root except gitignored local files. Reads your local
    config (same search order as the module) and every server list it points to, and reports each
    file:line where one of those values appears. Exit code 1 when anything is found.
.EXAMPLE
    .\Tools\Test-Sanitized.ps1
#>
[CmdletBinding()]
param([string]$ConfigPath)

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

$patterns = @(
    @{ Name = 'GUID'; Rx = '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b' }
    @{ Name = 'IPv4'; Rx = '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b' }
)

$skip  = '\\\.git\\|\\config\\lists\\|\.local\.|\\config\\config\.psd1$|\.(csv|log|zip)$'
$files = Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object { $_.FullName -notmatch $skip }
$hits  = 0
foreach ($file in $files) {
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
        $n++
        if ($file.Name -eq 'VmMaintenance.psd1' -and $line -match '^\s*GUID\s*=') { continue }   # module identity, not a secret
        foreach ($p in $patterns) {
            if ($line -match $p.Rx) { $hits++; Write-Host "$($file.FullName):$n  [$($p.Name)] $($Matches[0])" -ForegroundColor Red }
        }
        foreach ($s in $needles) {
            if ($line.IndexOf($s, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $hits++; Write-Host "$($file.FullName):$n  [local value] $s" -ForegroundColor Red
            }
        }
    }
}

if ($hits) {
    Write-Host "$hits sensitive value(s) found. Move them to your local config or server lists before committing." -ForegroundColor Red
    exit 1
}
Write-Host "Clean: $($files.Count) file(s) checked against $($needles.Count) local value(s) and GUID/IPv4 patterns." -ForegroundColor Green
