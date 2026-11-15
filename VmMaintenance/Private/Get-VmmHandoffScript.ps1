function Get-VmmHandoffScript {
    # PowerShell (2.0+) to paste on the host inside the RDP/RDM session. It writes only in the target
    # folder (C:\Temp): creates it, copies each missing file from the first source the host can open (the
    # share, then the laptop over \\tsclient), reads size and SHA256 on the host, prints one VMMSTAGE1 line
    # and puts it on the clipboard so vmm can verify it. Nothing is installed or run.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][object[]]$Items)
    $q = { param($s) "'" + ("$s" -replace "'", "''") + "'" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# vmm staging handoff for $($HostName.ToUpper()): copies into $Target only, then checks size and SHA256. Installs nothing.")
    $lines.Add("`$T = $(& $q $Target); `$H = $(& $q $HostName.ToUpper())")
    $lines.Add('$F = @()')
    foreach ($i in $Items) {
        $src = (@($i.Sources) | ForEach-Object { & $q $_ }) -join ', '
        $lines.Add(('$F += ,@({0}, {1}, {2}, @({3}))' -f (& $q $i.DestName), [long]$i.Size, (& $q $i.Sha256), $src))
    }
    $body = @'
if (-not (Test-Path -LiteralPath $T)) { New-Item -ItemType Directory -Path $T -Force | Out-Null; Write-Host "Created $T" }
$R = 'VMMSTAGE1|' + $H; $bad = 0
foreach ($f in $F) {
  $d = Join-Path $T $f[0]
  $have = $false
  if (Test-Path -LiteralPath $d) { $have = ((Get-Item -LiteralPath $d).Length -eq $f[1]) }
  if (-not $have) {
    foreach ($s in $f[3]) {
      if (-not (Test-Path -LiteralPath $s)) { Write-Host "  cannot open from this host: $s"; continue }
      Write-Host "Copying $s -> $d ($([math]::Round($f[1] / 1MB)) MB) ..."
      try { Copy-Item -LiteralPath $s -Destination $d -Force -ErrorAction Stop; break } catch { Write-Host "  copy failed: $($_.Exception.Message)" }
    }
  }
  if (Test-Path -LiteralPath $d) {
    $len = (Get-Item -LiteralPath $d).Length
    Write-Host "Checking $($f[0]) (SHA256) ..."
    $st = [IO.File]::OpenRead($d)
    try { $sha = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($st) | ForEach-Object { $_.ToString('X2') }) } finally { $st.Close() }
    if ($len -ne $f[1] -or ($f[2] -and $sha -ne $f[2])) { $bad++; Write-Host "  WRONG: $d size $len (expected $($f[1])) SHA256 $sha" } else { Write-Host "  OK: $d" }
    $R += '|' + $f[0] + '*' + $len + '*' + $sha
  } else { $bad++; Write-Host "  MISSING: $d - copy it by hand (RDP clipboard / RDM file transfer), then paste this script again"; $R += '|' + $f[0] + '*-1*' }
}
Write-Host ''
Write-Host $R
try { $R | clip.exe; Write-Host 'Report copied to the clipboard: go back to vmm and press V.' } catch { Write-Host 'Copy the VMMSTAGE1 line above and paste it in vmm.' }
if ($bad) { Write-Host "$bad file(s) not ready." } else { Write-Host 'All files ready.' }
'@
    foreach ($l in ($body -split "`r?`n")) { $lines.Add($l) }
    $lines -join "`r`n"
}
