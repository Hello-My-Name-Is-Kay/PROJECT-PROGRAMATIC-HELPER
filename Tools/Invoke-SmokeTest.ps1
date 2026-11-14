<#
.SYNOPSIS
    Offline smoke test for VmMaintenance. Touches no host, no Azure, no SQL, no network.
.DESCRIPTION
    1. Parses every .ps1/.psm1/.psd1 in the repository and reports syntax errors with file:line.
    2. Checks every source file is ASCII-only (PS 5.1 reads BOM-less files as ANSI).
    3. Imports the module from the repository and checks the exported function list.
    4. Compiles the mouse/keyboard helper (Resources\VmmConsoleInput.cs).
    5. Runs the pure functions with known inputs (disk tiers, platform, time window rules,
       placeholders, PSD1 round trip, error hints, log masking).
    6. Encrypt/decrypt round trip and tamper detection in a throw-away data folder
       (creates a temporary DPAPI key; the folder is deleted at the end).
    Exit code 0 = all passed, 1 = at least one failure.
.EXAMPLE
    .\Tools\Invoke-SmokeTest.ps1
.EXAMPLE
    pwsh -NoProfile -File .\Tools\Invoke-SmokeTest.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Path $PSScriptRoot -Parent
$script:pass = 0
$script:fail = 0

function Test-Step {
    param([string]$Name, [scriptblock]$Body)
    try {
        $r = & $Body
        if ($r -eq $false) { throw 'returned false' }
        $script:pass++
        Write-Host ('  [ OK ] ' + $Name) -ForegroundColor Green
    } catch {
        $script:fail++
        $lines = @($_.Exception.Message -split '\r?\n' | Where-Object { $_ })
        Write-Host ('  [FAIL] ' + $Name + ' - ' + $lines[0]) -ForegroundColor Red
        foreach ($l in ($lines | Select-Object -Skip 1)) { Write-Host ('         ' + $l.Trim()) -ForegroundColor DarkRed }
    }
}

function Assert-Equal($Actual, $Expected, [string]$What) {
    if ("$Actual" -ne "$Expected") { throw "$What : expected '$Expected', got '$Actual'" }
}

Write-Host ''
Write-Host ("VmMaintenance smoke test - PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition) -ForegroundColor Cyan

# ---------------------------------------------------------------- 1. Syntax
Write-Host '1. Syntax' -ForegroundColor Cyan
# -Include is ignored together with -LiteralPath, so filter on Extension
$sources = Get-ChildItem -LiteralPath $repo -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' -and $_.FullName -notmatch '\\\.git\\|\.local\.' }
foreach ($f in $sources) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count) {
        foreach ($e in $errs) {
            $script:fail++
            Write-Host ("  [FAIL] {0}:{1} {2}" -f $f.FullName.Substring($repo.Length + 1), $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
        }
    } else { $script:pass++ }
}
Write-Host ("  parsed {0} files" -f $sources.Count) -ForegroundColor DarkGray

# ---------------------------------------------------------------- 2. ASCII
Write-Host '2. ASCII-only sources' -ForegroundColor Cyan
$text = Get-ChildItem -LiteralPath $repo -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.cs', '.sql' -and $_.FullName -notmatch '\\\.git\\|\.local\.' }
$nonAscii = @()
foreach ($f in $text) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii += $f.FullName.Substring($repo.Length + 1); break } }
}
Test-Step ("{0} files, none with non-ASCII bytes" -f $text.Count) {
    if ($nonAscii.Count) { throw ('non-ASCII in: ' + ($nonAscii -join ', ')) }
}

# ---------------------------------------------------------------- 3. Import
Write-Host '3. Module import' -ForegroundColor Cyan
$m = $null
Test-Step 'Import-Module from repository' {
    $script:m = Import-Module (Join-Path $repo 'VmMaintenance\VmMaintenance.psd1') -Force -PassThru
    $script:m -ne $null
}
$m = $script:m
if (-not $m) {
    Write-Host 'Module did not load - remaining checks skipped.' -ForegroundColor Red
    exit 1
}
Test-Step 'Exported functions = files in Public\' {
    $files = (Get-ChildItem (Join-Path $repo 'VmMaintenance\Public') -Filter *.ps1).BaseName | Sort-Object
    $exp   = $m.ExportedFunctions.Keys | Sort-Object
    $diff  = Compare-Object $files $exp
    if ($diff) { throw ('mismatch: ' + (($diff | ForEach-Object { $_.InputObject + $_.SideIndicator }) -join ', ')) }
}
Test-Step 'No Private function is exported' {
    $priv = (Get-ChildItem (Join-Path $repo 'VmMaintenance\Private') -Filter *.ps1).BaseName
    $leak = $priv | Where-Object { $m.ExportedFunctions.ContainsKey($_) }
    if ($leak) { throw ('exported: ' + ($leak -join ', ')) }
}

# ---------------------------------------------------------------- 4. C# helper
Write-Host '4. Console input helper' -ForegroundColor Cyan
Test-Step 'VmmConsoleInput.cs compiles (Add-Type)' {
    if ('VmmConsoleInput' -as [type]) { return $true }
    $cs = [System.IO.File]::ReadAllText((Join-Path $repo 'VmMaintenance\Resources\VmmConsoleInput.cs'))
    Add-Type -TypeDefinition $cs -Language CSharp
    [bool]('VmmConsoleInput' -as [type])
}

# ---------------------------------------------------------------- 5. Pure functions
Write-Host '5. Pure functions' -ForegroundColor Cyan
$tiers = @(4, 8, 16, 32, 64, 128, 256, 512, 1024)
Test-Step 'Get-VmmNextDiskTier 127 -> 256 (ceiling 128, next tier up)' {
    Assert-Equal (& $m { param($t) Get-VmmNextDiskTier -SizeGB 127 -TierSizes $t } $tiers) 256 'tier'
}
Test-Step 'Get-VmmNextDiskTier 1024 -> none (already at the top)' {
    $r = & $m { param($t) Get-VmmNextDiskTier -SizeGB 1024 -TierSizes $t } $tiers
    $null -eq $r
}
Test-Step 'Get-VmmVmPlatform VMware by manufacturer' {
    Assert-Equal (& $m { Get-VmmVmPlatform -Manufacturer 'VMware, Inc.' -Model 'VMware7,1' -Mac '' }) 'VMware' 'platform'
}
Test-Step 'Get-VmmVmPlatform Azure by MAC prefix 00-0D-3A' {
    Assert-Equal (& $m { Get-VmmVmPlatform -Manufacturer 'Microsoft Corporation' -Model 'Virtual Machine' -Mac '00-0D-3A-00-00-01' }) 'Azure' 'platform'
}
Test-Step 'Get-VmmVmPlatform Hyper-V by MAC prefix 00-15-5D' {
    Assert-Equal (& $m { Get-VmmVmPlatform -Manufacturer 'Microsoft Corporation' -Model 'Virtual Machine' -Mac '00:15:5D:00:00:01' }) 'Hyper-V' 'platform'
}

$days  = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
$start = [timespan]'08:00'
$end   = [timespan]'17:00'
$rule  = { param($when, $d, $s, $e, $h, $off) Test-VmmChangeAllowed -ZoneTime $when -BusinessDays $d -Start $s -End $e -Holidays $h -OffHoursWeekdays $off }
# 2026-11-16 is a Monday, 2026-11-21 a Saturday
Test-Step 'Time rule: Monday 10:00 = checks/staging only' {
    (& $m $rule ([datetime]'2026-11-16T10:00:00') $days $start $end @() $true) -eq $false
}
Test-Step 'Time rule: Monday 17:00 = changes allowed (end is exclusive)' {
    (& $m $rule ([datetime]'2026-11-16T17:00:00') $days $start $end @() $true) -eq $true
}
Test-Step 'Time rule: Monday 07:59 with OffHoursWeekdays off = blocked' {
    (& $m $rule ([datetime]'2026-11-16T07:59:00') $days $start $end @() $false) -eq $false
}
Test-Step 'Time rule: Saturday 10:00 = changes allowed' {
    (& $m $rule ([datetime]'2026-11-21T10:00:00') $days $start $end @() $true) -eq $true
}
Test-Step 'Time rule: holiday Monday 10:00 = changes allowed' {
    (& $m $rule ([datetime]'2026-11-16T10:00:00') $days $start $end @('2026-11-16') $true) -eq $true
}
Test-Step 'Lisbon time zone id resolves (GMT Standard Time)' {
    [void][System.TimeZoneInfo]::FindSystemTimeZoneById('GMT Standard Time'); $true
}

Test-Step 'Policy: Windows 10 is skipped, 2008 (not R2) and physical warn, 2019 is at target' {
    $r = & $m {
        $mk = { param($os, $plat) $h = New-VmmHostRecord -Name 'x'; $h.Platform = $plat; $h.Check = [pscustomobject]@{ OS = $os }; Get-VmmHostPolicy -Record $h }
        @((& $mk 'Microsoft Windows 10 Pro' 'VMware').Scope, (& $mk 'Microsoft Windows Server 2019 Standard' 'Azure').Scope,
          @((& $mk 'Microsoft Windows Server 2008 Enterprise' 'Physical').Warnings).Count, @((& $mk 'Microsoft Windows Server 2008 R2 Enterprise' 'VMware').Warnings).Count)
    }
    Assert-Equal ($r -join ',') 'ClientOs,AtTarget,2,0' 'policy'
}
Test-Step 'Find-VmmPlaceholder finds nested <placeholder>' {
    Assert-Equal (& $m { Find-VmmPlaceholder -Value @{ A = @{ B = @('x', '<your-share>') } } }) '<your-share>' 'placeholder'
}
Test-Step 'Find-VmmPlaceholder ignores real values' {
    $null -eq (& $m { Find-VmmPlaceholder -Value @{ A = 'value'; B = 3; C = @() } })
}
Test-Step 'ConvertTo-VmmPsd1 round trip (nested, quotes, bool, numbers, arrays)' {
    $src = @{ Name = "O'Brien"; On = $true; Off = $false; N = 16; D = 1.5; List = @('a', 'b'); Sub = @{ 'Key With Space' = 'v'; Empty = @{} } }
    $psd = & $m { param($o) ConvertTo-VmmPsd1 -InputObject $o } $src
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('vmm-smoke-' + [guid]::NewGuid().ToString('N') + '.psd1')
    try {
        [IO.File]::WriteAllText($tmp, $psd, [Text.Encoding]::ASCII)
        $back = Import-PowerShellDataFile -LiteralPath $tmp
        Assert-Equal $back.Name "O'Brien" 'Name'
        Assert-Equal $back.On $true 'On'
        Assert-Equal $back.Off $false 'Off'
        Assert-Equal $back.N 16 'N'
        Assert-Equal $back.D 1.5 'D'
        Assert-Equal ($back.List -join ',') 'a,b' 'List'
        Assert-Equal $back.Sub['Key With Space'] 'v' 'Sub'
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}
Test-Step 'Get-VmmErrorHint maps AuthorizationFailed' {
    $h = & $m { Get-VmmErrorHint -Message 'The client does not have authorization to perform action' }
    $h -and $h.Fix -match 'Contributor'
}
Test-Step 'Get-VmmErrorHint returns nothing for unknown text' {
    $null -eq (& $m { Get-VmmErrorHint -Message 'zzz no rule matches this zzz' })
}
Test-Step 'Protect-VmmLogText masks password=, Bearer and SAS sig=' {
    $out = & $m { Protect-VmmLogText 'password=Hunter2;x Bearer abc.def-ghi sig=ABCDEFGHIJKLMNOPQRSTUV' }
    if ($out -match 'Hunter2|abc\.def|ABCDEFGHIJ') { throw "leaked: $out" }
    $true
}

# ---------------------------------------------------------------- 6. Encryption
Write-Host '6. Encryption (temporary data folder)' -ForegroundColor Cyan
$isWin = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
if (-not $isWin) {
    Write-Host '  [SKIP] DPAPI exists on Windows only' -ForegroundColor Yellow
} else {
    $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('vmm-smoke-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'data'))
    [void](New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'reports'))
    $saved = & $m { $script:VmmConfig }
    try {
        & $m { param($r) $script:VmmConfig = @{ Paths = @{ DataDir = (Join-Path $r 'data'); ReportDir = (Join-Path $r 'reports') } } } $tmpRoot

        Test-Step 'Protect/Unprotect bytes round trip (AES-256-CBC + HMAC-SHA256)' {
            $plain = [Text.Encoding]::UTF8.GetBytes('{"hosts":["example-host-01"]}')
            $enc = & $m { param($b) Protect-VmmBytes -Bytes $b } $plain
            if ([Text.Encoding]::ASCII.GetString($enc, 0, 4) -ne 'VMM1') { throw 'missing VMM1 header' }
            $dec = & $m { param($b) Unprotect-VmmBytes -Bytes $b } $enc
            Assert-Equal ([Text.Encoding]::UTF8.GetString($dec)) '{"hosts":["example-host-01"]}' 'plaintext'
        }
        Test-Step 'Ciphertext differs on each call (random IV)' {
            $p = [byte[]](1..40)
            $a = & $m { param($b) Protect-VmmBytes -Bytes $b } $p
            $b2 = & $m { param($b) Protect-VmmBytes -Bytes $b } $p
            ([Convert]::ToBase64String($a)) -ne ([Convert]::ToBase64String($b2))
        }
        Test-Step 'Tampered file is rejected (VmmStoreIntegrity)' {
            $enc = & $m { param($b) Protect-VmmBytes -Bytes $b } ([byte[]](1..40))
            $enc[30] = $enc[30] -bxor 0xFF
            try { [void](& $m { param($b) Unprotect-VmmBytes -Bytes $b } $enc); throw 'tampered data was accepted' }
            catch { if ($_.FullyQualifiedErrorId -notmatch 'VmmStoreIntegrity' -and $_.Exception.Message -notmatch 'damaged|modified') { throw } }
            $true
        }
        Test-Step 'Key file is a DPAPI blob, not the raw 64-byte key' {
            $k = [IO.File]::ReadAllBytes((Join-Path $tmpRoot 'data\store.key'))
            $k.Length -gt 64
        }
        Test-Step 'Fleet store save/read round trip' {
            & $m {
                $s = Read-VmmStore
                $s.Hosts = @($s.Hosts) + (New-VmmHostRecord -Name 'smoke-host')
                Save-VmmStore -Store $s
                $t = Read-VmmStore
                @($t.Hosts | Where-Object { $_.Name -eq 'SMOKE-HOST' }).Count -eq 1
            }
        }
        Test-Step 'Host agent: VMM2 result encrypted on the host decrypts on the laptop' {
            # Load only Protect-Result from the agent script (AST), feed it this laptop's public key
            $agentPath = Join-Path $repo 'VmMaintenance\Resources\VmmHostAgent.ps1'
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($agentPath, [ref]$null, [ref]$null)
            $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Protect-Result' }, $true) | Select-Object -First 1
            if (-not $fn) { throw 'Protect-Result not found in the agent' }
            . ([scriptblock]::Create($fn.Extent.Text))
            $rsa = & $m { Get-VmmAgentKey }
            try { $Card = @{ PublicKey = $rsa.ToXmlString($false) } } finally { $rsa.Clear() }
            $script:agentLine = Protect-Result "Name=SMOKE-HOST`nOS=Test"
            if ($script:agentLine -notmatch '^VMM2\|(.+)$') { throw 'no VMM2 line' }
            $plain = & $m { param($b) Unprotect-VmmAgentResult -Base64 $b } $Matches[1]
            Assert-Equal $plain "Name=SMOKE-HOST`nOS=Test" 'agent plaintext'
        }
        Test-Step 'Host agent: modified VMM2 line is rejected' {
            $bytes = [Convert]::FromBase64String(($script:agentLine -split '\|', 2)[1]); $bytes[$bytes.Length - 40] = $bytes[$bytes.Length - 40] -bxor 1
            try { [void](& $m { param($b) Unprotect-VmmAgentResult -Base64 $b } ([Convert]::ToBase64String($bytes))); throw 'accepted' }
            catch { if ($_.Exception.Message -eq 'accepted') { throw 'tampered agent result was accepted' } }
            $true
        }
        Test-Step 'Extractor result file on the laptop Desktop/Downloads is imported and removed' {
            $agentPath = Join-Path $repo 'VmMaintenance\Resources\VmmHostAgent.ps1'
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($agentPath, [ref]$null, [ref]$null)
            $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Protect-Result' }, $true) | Select-Object -First 1
            . ([scriptblock]::Create($fn.Extent.Text))
            $rsa = & $m { Get-VmmAgentKey }
            try { $Card = @{ PublicKey = $rsa.ToXmlString($false) } } finally { $rsa.Clear() }
            $inbox = Join-Path $tmpRoot 'inbox'; New-Item -ItemType Directory -Path $inbox -Force | Out-Null
            $line = Protect-Result ("Name=SMOKE-HOST`nOS=Microsoft Windows Server 2016 Standard`nLang=fr-FR`nBuild=14393`nCTotalGB=127`nCFreeGB=40.5`nSql=none`nInv.Domain=corp.example`nInv.TlsLegacyDisabled=Yes`nInv.Bogus=x`nEvent=2026-11-14T10:00:00Z|Export|Success|result exported")
            $f = Join-Path $inbox 'VMM_SMOKE-HOST_20261114_1000.vmm'
            [IO.File]::WriteAllText($f, $line, [Text.Encoding]::ASCII)
            $r = & $m { param($p) Import-VmmResultInbox -Path $p -Quiet -PassThru } $inbox
            Assert-Equal @($r.Imported).Count 1 'imported files'
            if (Test-Path -LiteralPath $f) { throw 'imported file was not removed' }
            $h = & $m { (Read-VmmStore).Hosts | Where-Object { $_.Name -eq 'SMOKE-HOST' } }
            Assert-Equal $h.Check.Lang 'fr-FR' 'language'
            Assert-Equal $h.InventoryAuto.Domain.Value 'corp.example' 'inventory domain'
            if ($h.InventoryAuto.PSObject.Properties['Bogus']) { throw 'unknown inventory key accepted' }
            Assert-Equal $h.Steps.Precheck.Status 'Success' 'precheck from extraction'
        }
        Test-Step 'Fleet store file contains no plaintext host name' {
            $f = Get-ChildItem -LiteralPath (Join-Path $tmpRoot 'data') -Filter '*.vmm' | Select-Object -First 1
            if (-not $f) { throw 'no .vmm file written' }
            $raw = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($f.FullName))
            $raw -notmatch '(?i)smoke-host'
        }
    } finally {
        & $m { param($c) $script:VmmConfig = $c } $saved
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- Result
Write-Host ''
if ($script:fail -eq 0) {
    Write-Host ("PASSED - {0} checks" -f $script:pass) -ForegroundColor Green
    exit 0
}
Write-Host ("FAILED - {0} failed, {1} passed" -f $script:fail, $script:pass) -ForegroundColor Red
exit 1
