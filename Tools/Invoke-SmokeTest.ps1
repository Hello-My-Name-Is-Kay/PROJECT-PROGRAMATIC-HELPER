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
    7. One vmm at a time and the CLI log.
    8. RDP / RDM handoff: .rdp/.rdg text, clients, VMMSTAGE1 report, the host script run on a temp folder.
    9. Exits and failures: exit codes (also from new PowerShell processes), staging copy through a drive,
       Ctrl+C on a step and on disk expansion, failed and blocked steps, AI masking, lock and log write failures.
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

function New-SmokeConfigFile {
    # Throw-away config for a new PowerShell process: data, logs and reports under $Root, plaintext day log
    param([string]$Root)
    foreach ($d in 'data', 'reports', 'work') { [void](New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force) }
    $q = { param($p) "'" + ("$p" -replace "'", "''") + "'" }
    $file = Join-Path $Root 'smoke-config.psd1'
    Set-Content -LiteralPath $file -Encoding ASCII -Value @(
        '@{'
        "    Paths = @{ DataDir = $(& $q (Join-Path $Root 'data')); ReportDir = $(& $q (Join-Path $Root 'reports')); WorkDir = $(& $q (Join-Path $Root 'work')) }"
        '    Log   = @{ ToFile = $true; Encrypt = $false }'
        '}'
    )
    $file
}

function Invoke-SmokeChild {
    # Runs a script in a new PowerShell process (same edition and version) and returns its exit code and output
    param([string]$File, [string[]]$ArgumentList = @())
    $ErrorActionPreference = 'Continue'   # a line on stderr is output here, not a failure of the smoke test
    $out = & ((Get-Process -Id $PID).Path) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $File @ArgumentList 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Invoke-SmokeStopped {
    # Runs $Setup, then $Run, inside the module in a runspace of its own. $Setup puts a stand-in in place that sets
    # $script:TestSync.Entered and waits; the run is stopped there the way Ctrl+C stops it (catch blocks are
    # skipped, finally blocks run). Returns the run state, what $Inspect reports afterwards, and the shared table.
    param([scriptblock]$Setup, [scriptblock]$Run, [scriptblock]$Inspect = { }, [string]$Root)
    [void](New-Item -ItemType Directory -Path $Root -Force)
    $sync = [hashtable]::Synchronized(@{ Entered = $false })
    $ps = [powershell]::Create()
    try {
        # Script blocks travel as text: each runspace runs only its own script blocks
        $null = $ps.AddScript({
            param($Mod, $Root, $Sync, $SetupText, $RunText)
            $mm = Import-Module $Mod -Force -PassThru
            & $mm ([scriptblock]::Create($SetupText)) $Root $Sync
            & $mm ([scriptblock]::Create($RunText)) $Root
        }).AddArgument((Join-Path $repo 'VmMaintenance\VmMaintenance.psd1')).AddArgument($Root).AddArgument($sync).AddArgument("$Setup").AddArgument("$Run")
        $h = $ps.BeginInvoke()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $sync.Entered -and -not $h.IsCompleted -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 50 }
        if (-not $sync.Entered) {
            $why = try { $null = $ps.EndInvoke($h); 'it ended first' } catch { $_.Exception.Message }
            throw "the run never reached the point where the test stops it: $why"
        }
        $ps.Stop()
        $state = "$($ps.InvocationStateInfo.State)"
        $ps.Commands.Clear()
        $null = $ps.AddScript({ param($t, $Root) & (Get-Module VmMaintenance) ([scriptblock]::Create($t)) $Root }).AddArgument("$Inspect").AddArgument($Root)
        [pscustomobject]@{ State = $state; Result = @($ps.Invoke()); Sync = $sync }
    } finally { $ps.Dispose() }
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
        Test-Step 'Extractor build: snapshot only, steps code cut out, parses' {
            $f = & $m { Export-VmmHostAgent -Generic -NoClipboard -PassThru }
            $text = [IO.File]::ReadAllText($f.FullName)
            $err = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$err)
            if (@($err).Count) { throw "built extractor does not parse: $($err[0].Message)" }
            foreach ($w in '# VMM-STEPS-BEGIN', 'diskpart', 'Start-Process', 'function Invoke-Upgrade', 'function Write-Event', 'icacls') { if ($text.Contains($w)) { throw "snapshot extractor contains '$w'" } }
            if ($text -notmatch "(?m)^\`$CardText = '([A-Za-z0-9+/=]+)'") { throw 'no plan card in the built extractor' }
            $card = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
            if ($card -notmatch '(?m)^Mode=Snapshot$') { throw 'card is not Mode=Snapshot' }
            if ($card -match '(?m)^(Host|Share|UpgradeCommand)=') { throw 'snapshot card carries host, share or upgrade command' }
            $true
        }
        Test-Step 'Extractor per host: snapshot by default, steps only with Extractor.AllowSteps' {
            $f = & $m { Export-VmmHostAgent -HostName 'smoke-host' -NoClipboard -PassThru }
            $text = [IO.File]::ReadAllText($f.FullName)
            if ($text.Contains('function Invoke-Upgrade')) { throw 'per-host extractor has steps although AllowSteps is off' }
            $f2 = & $m { $script:VmmConfig.Extractor = @{ AllowSteps = $true }; try { Export-VmmHostAgent -HostName 'smoke-host' -NoClipboard -PassThru } finally { $script:VmmConfig.Extractor = @{ AllowSteps = $false } } }
            $text2 = [IO.File]::ReadAllText($f2.FullName)
            if (-not $text2.Contains('function Invoke-Upgrade')) { throw 'steps extractor has no steps code' }
            $err = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($text2, [ref]$null, [ref]$err)
            if (@($err).Count) { throw "steps extractor does not parse: $($err[0].Message)" }
            if ($text2 -notmatch "(?m)^\`$CardText = '([A-Za-z0-9+/=]+)'") { throw 'no plan card' }
            if ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) -notmatch '(?m)^Mode=Steps$') { throw 'card is not Mode=Steps' }
            $true
        }
        Test-Step 'Extractor result with failed reads: imported, gaps listed, route = Hands-on' {
            $agentPath = Join-Path $repo 'VmMaintenance\Resources\VmmHostAgent.ps1'
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($agentPath, [ref]$null, [ref]$null)
            $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Protect-Result' }, $true) | Select-Object -First 1
            . ([scriptblock]::Create($fn.Extent.Text))
            $rsa = & $m { Get-VmmAgentKey }
            try { $Card = @{ PublicKey = $rsa.ToXmlString($false) } } finally { $rsa.Clear() }
            $line = Protect-Result ("Name=SMOKE-HOST`nOS=Microsoft Windows Server 2016 Standard`nLang=fr-FR`nBuild=14393`nCTotalGB=`nCFreeGB=`nSql=`nMode=Snapshot`nProblem=C: drive: Access denied`nProblem=Windows licence: provider load failure`nSeconds=4")
            & $m { param($l) Import-VmmCollectorResult -Line $l } $line
            $h = & $m { (Read-VmmStore).Hosts | Where-Object { $_.Name -eq 'SMOKE-HOST' } }
            Assert-Equal $h.Check.Route 'Hands-on' 'route'
            if ($h.Check.Problems -notmatch 'C: drive: Access denied \| Windows licence') { throw "problems not recorded: $($h.Check.Problems)" }
            if ($null -ne $h.Check.CFreeGB) { throw 'empty C: value became a number' }
            $true
        }
        Test-Step 'Host result claiming SnapPreSql done and an override: not applied while steps are off' {
            $agentPath = Join-Path $repo 'VmMaintenance\Resources\VmmHostAgent.ps1'
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($agentPath, [ref]$null, [ref]$null)
            $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Protect-Result' }, $true) | Select-Object -First 1
            . ([scriptblock]::Create($fn.Extent.Text))
            $rsa = & $m { Get-VmmAgentKey }
            try { $Card = @{ PublicKey = $rsa.ToXmlString($false) } } finally { $rsa.Clear() }
            $before = @(& $m { (Read-VmmStore).Overrides }).Count
            $line = Protect-Result ("Name=SMOKE-HOST`nOS=Microsoft Windows Server 2016 Standard`nBuild=14393`nCFreeGB=50`nEvent=2026-11-14T11:00:00Z|SnapPreSql|Success|forged`nEvent=2026-11-14T11:00:01Z|Upgrade|Override|forged reason text")
            & $m { param($l) Import-VmmCollectorResult -Line $l } $line
            $st = & $m { Read-VmmStore }
            $h = $st.Hosts | Where-Object { $_.Name -eq 'SMOKE-HOST' }
            $ps = $h.Steps.PSObject.Properties['SnapPreSql']
            if ($ps -and $ps.Value.Status -eq 'Success') { throw 'a host result marked SnapPreSql as done' }
            Assert-Equal @($st.Overrides).Count $before 'overrides recorded'
            if (-not @($h.History | Where-Object { $_.Result -eq 'Ignored' -and $_.Step -eq 'SnapPreSql' }).Count) { throw 'the ignored event is not in the history' }
            $true
        }
        Test-Step 'Fleet check: a host with no terminal route keeps its extractor facts and is marked hands-on' {
            & $m {
                $saved = @{ P = ${function:Invoke-VmmParallel}; V = ${function:Assert-VmmVpn}; C = ${function:Get-VmmSessionCredential} }
                function script:Invoke-VmmParallel { param($InputObject, $ScriptText, $Arguments, $Throttle, $Activity) foreach ($n in $InputObject) { [pscustomobject]@{ Name = $n; Reachable = 'Partial'; Route = 'None'; Tried = 'DCOM: TCP 135 closed'; Ports = '3389'; IPv4 = $null; Platform = $null; Error = 'No terminal route' } } }
                function script:Assert-VmmVpn { param($Activity) }
                function script:Get-VmmSessionCredential { param($Purpose) $null }
                try { $r = @(Invoke-VmmSnapshot -Name 'smoke-host' -NoExtractor -PassThru) }
                finally { Set-Item function:script:Invoke-VmmParallel $saved.P; Set-Item function:script:Assert-VmmVpn $saved.V; Set-Item function:script:Get-VmmSessionCredential $saved.C }
                $h = (Read-VmmStore).Hosts | Where-Object { $_.Name -eq 'SMOKE-HOST' }
                if ($h.Access.Route -ne 'None') { throw "access route is '$($h.Access.Route)'" }
                if ($h.Check.Route -ne 'Hands-on' -or $h.Check.OS -notmatch '2016') { throw 'the failed terminal read erased the extractor facts' }
                $a = Get-VmmHostAccess -Record $h
                if ($a.Terminal -ne $false) { throw 'terminal should be false' }
                $true
            }
        }
        Test-Step 'Log: line encrypted on disk, readable with vmm log' {
            & $m { Write-VmmLog 'smoke log line for LOGHOST-77' -Level Info -FileOnly }
            $f = Get-ChildItem -LiteralPath (Join-Path $tmpRoot 'logs') -Filter 'vmm_*.log' | Select-Object -First 1
            if (-not $f) { throw 'no day log written' }
            $raw = [IO.File]::ReadAllText($f.FullName)
            if ($raw -match 'LOGHOST-77') { throw 'host name in plaintext in the log file' }
            if ($raw -notmatch '(?m)^E1:') { throw 'log line not encrypted' }
            $e = @(& $m { Get-VmmLog -PassThru -Find 'LOGHOST-77' -Tail 10 })
            Assert-Equal $e.Count 1 'lines found'
            Assert-Equal $e[0].Level 'Info' 'level'
        }
        Test-Step 'Parallel run: results plus live progress lines in the log' {
            $r = @(& $m { Invoke-VmmParallel -InputObject @('A1', 'A2', 'A3') -Throttle 2 -Activity 'Smoke' -ScriptText 'param($Name, $A) $A.Trace.Enqueue("${Name}: step one"); Start-Sleep -Milliseconds 300; [pscustomobject]@{ Name = $Name }' })
            Assert-Equal (@($r.Name | Sort-Object) -join ',') 'A1,A2,A3' 'results'
            $buf = @(& $m { $script:VmmLogBuffer | ForEach-Object Text })
            if (-not ($buf -match '^A2: step one$')) { throw 'step line missing' }
            if (-not ($buf -match '^A3: finished in')) { throw 'finished line missing' }
            if (-not ($buf -match '^Smoke: all 3 finished')) { throw 'summary line missing' }
            $true
        }
        Test-Step 'Maintenance: backup, list, restore, diagnose' {
            $b = & $m { Invoke-VmmMaintenance -Action Backup -Quiet -PassThru -Confirm:$false }
            if (-not (Test-Path -LiteralPath $b)) { throw 'no backup file' }
            $l = @(& $m { Invoke-VmmMaintenance -Action ListBackups -PassThru })
            if ($l[0].Hosts -lt 1) { throw "backup host count: $($l[0].Hosts)" }
            & $m { param($f) Invoke-VmmMaintenance -Action Restore -BackupFile $f -Confirm:$false } ([IO.Path]::GetFileName($b))
            if (-not (Test-Path -LiteralPath (Join-Path $tmpRoot 'data\fleet.vmm.before-restore'))) { throw 'no before-restore copy' }
            $d = @(& $m { Invoke-VmmMaintenance -Action Diagnose -PassThru -Quiet })
            $bad = @($d | Where-Object { $_.Check -in 'Data key', 'Fleet store' -and $_.Status -ne 'OK' })
            if ($bad) { throw ($bad | ForEach-Object { "$($_.Check): $($_.Detail)" }) -join '; ' }
            $true
        }
        Test-Step 'Fleet store file contains no plaintext host name' {
            $f = Get-ChildItem -LiteralPath (Join-Path $tmpRoot 'data') -Filter '*.vmm' | Select-Object -First 1
            if (-not $f) { throw 'no .vmm file written' }
            $raw = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($f.FullName))
            $raw -notmatch '(?i)smoke-host'
        }
    } finally {
        & $m { param($c) Exit-VmmInstanceLock; $script:VmmConfig = $c } $saved
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- 7. One vmm at a time, CLI log
Write-Host '7. One vmm at a time and the CLI log (temporary data folder)' -ForegroundColor Cyan
$tmpLock = Join-Path ([IO.Path]::GetTempPath()) ('vmm-smoke-lock-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $tmpLock 'data'))
$savedLock = & $m { $script:VmmConfig }
try {
    & $m { param($r) Exit-VmmInstanceLock; $script:VmmConfig = @{ Log = @{ ToFile = $false }; Paths = @{ DataDir = (Join-Path $r 'data'); ReportDir = (Join-Path $r 'reports') } } } $tmpLock
    Test-Step 'Lock: taken once, owner note written, released' {
        $a = & $m { Enter-VmmInstanceLock -Owner 'vmm ui' }; $b = & $m { Enter-VmmInstanceLock }
        $note = [IO.File]::ReadAllText((Join-Path $tmpLock 'data\vmm.lock.txt'))
        & $m { Exit-VmmInstanceLock }
        if (-not $a -or $b) { throw "enter returned $a, $b" }
        if ($note -notmatch ('^' + $PID + '\|.+\|vmm ui$')) { throw "owner note: $note" }
        if (Test-Path -LiteralPath (Join-Path $tmpLock 'data\vmm.lock.txt')) { throw 'owner note left behind' }
        $true
    }
    Test-Step 'Lock: a second vmm stops (VmmInstanceLocked), read-only commands still run' {
        $fs = New-Object System.IO.FileStream((Join-Path $tmpLock 'data\vmm.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            [IO.File]::WriteAllText((Join-Path $tmpLock 'data\vmm.lock.txt'), '4242|2026-11-14 19:00:00|vmm ui')
            $id = ''; $msg = ''
            try { Invoke-VmmCli -Command remove -Arguments @('-Name', 'x') | Out-Null } catch { $id = "$($_.FullyQualifiedErrorId)"; $msg = $_.Exception.Message }
            if ($id -notlike 'VmmInstanceLocked*') { throw "error id '$id'" }
            if ($msg -notmatch 'process 4242') { throw "message does not name the holder: $msg" }
            $id = ''
            try { & $m { Save-VmmStore -Store ([pscustomobject]@{ Updated = $null; Hosts = @() }) } } catch { $id = "$($_.FullyQualifiedErrorId)" }
            if ($id -notlike 'VmmInstanceLocked*') { throw "Save-VmmStore: error id '$id'" }
            if (-not (Invoke-VmmCli -Command time).ZoneLabel) { throw 'vmm time did not run beside the lock' }
        } finally { $fs.Dispose() }
        $true
    }
    Test-Step 'CLI log: command line, output, result and failure are logged' {
        & $m { $script:VmmLogBuffer = $null }
        Invoke-VmmCli -Command time | Out-Null
        try { Invoke-VmmCli -Command guide -Arguments @('-HostName', 'x', '-Step', 'NoSuchStep') | Out-Null } catch { }
        $t = (@(& $m { $script:VmmLogBuffer | ForEach-Object { "$($_.Level)|$($_.Text)" } }) -join "`n")
        foreach ($want in 'Muted\|Command: vmm time', 'Output\|ZoneLabel', 'Muted\|vmm time done in', 'Error\|vmm guide -HostName -Step FAILED in') {
            if ($t -notmatch $want) { throw "log has no line matching '$want'" }
        }
        $true
    }
    Test-Step 'Out-VmmHost logs the table it prints, secrets masked' {
        & $m { $script:VmmLogBuffer = $null; [pscustomobject]@{ A = 1; B = 'password=Hunter2' } | Out-VmmHost 6>$null }
        $t = (@(& $m { $script:VmmLogBuffer | ForEach-Object { "$($_.Level)|$($_.Text)" } }) -join "`n")
        if ($t -notmatch 'Output\|1 password=\*\*\*') { throw "not logged: $t" }
        if ($t -match 'Hunter2') { throw 'secret in the log' }
        $true
    }
} finally {
    & $m { param($c) Exit-VmmInstanceLock; $script:VmmConfig = $c } $savedLock
    Remove-Item -LiteralPath $tmpLock -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '8. RDP / RDM handoff (temporary folders, no host, no client started)' -ForegroundColor Cyan
$tmpHand = Join-Path ([IO.Path]::GetTempPath()) ('vmm-smoke-hand-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $tmpHand 'src'))
$savedHand = & $m { $script:VmmConfig }
try {
    & $m { param($r) $script:VmmNonInteractive = $true; $script:VmmConfig = @{ Log = @{ ToFile = $false }; Paths = @{ DataDir = (Join-Path $r 'data'); ReportDir = (Join-Path $r 'reports') }
                                                     Handoff = @{ RdmPath = (Join-Path $r 'nope\RemoteDesktopManager.exe'); Client = 'Ask' } } } $tmpHand
    Test-Step '.rdp file: host, clipboard on, only the asked drive shared, no account in it' {
        $t = & $m { Get-VmmRdpFileText -Address 'srv01.corp.example' -Drive 'c' }
        foreach ($want in '(?m)^full address:s:srv01\.corp\.example\r?$', '(?m)^redirectclipboard:i:1\r?$', '(?m)^drivestoredirect:s:C:\\;\r?$', '(?m)^prompt for credentials:i:1\r?$') {
            if ($t -notmatch $want) { throw "no line matching $want" }
        }
        if ($t -match '(?im)^(username|password|domain)') { throw 'account data in the .rdp file' }
        if ((& $m { Get-VmmRdpFileText -Address 'srv01' }) -notmatch '(?m)^drivestoredirect:s:\r?$') { throw 'drives shared without -Drive' }
        $true
    }
    Test-Step '.rdp file: an address with spaces or switches is refused' {
        $id = ''
        try { & $m { Get-VmmRdpFileText -Address 'srv01 /admin' } | Out-Null } catch { $id = "$($_.FullyQualifiedErrorId)" }
        if ($id -notlike 'VmmRdpAddress*') { throw "error id '$id'" }
        $true
    }
    Test-Step '.rdg file is valid XML with the server name escaped' {
        $x = [xml](& $m { Get-VmmRdgFileText -Address 'srv01' -DisplayName 'A&B' })
        Assert-Equal $x.RDCMan.file.server.properties.name 'srv01' 'server'
        Assert-Equal $x.RDCMan.file.server.properties.displayName 'A&B' 'display name'
    }
    Test-Step '\\tsclient path for a local file, none for UNC' {
        Assert-Equal (& $m { ConvertTo-VmmTsClientPath 'c:\Users\me\outbox\a.iso' }) '\\tsclient\C\Users\me\outbox\a.iso' 'tsclient'
        $null -eq (& $m { ConvertTo-VmmTsClientPath '\\srv\share\a.iso' })
    }
    Test-Step 'Clients: three rows; a wrong Handoff.RdmPath is reported, not used' {
        $c = @(& $m { Get-VmmRemoteClient })
        Assert-Equal (($c | ForEach-Object Name) -join ',') 'Rdp,Rdm,RdcMan' 'clients'
        $rdm = $c | Where-Object Name -eq 'Rdm'
        if ($rdm.Available -or $rdm.Why -notmatch 'Handoff\.RdmPath') { throw "Rdm: $($rdm.Available) / $($rdm.Why)" }
        $true
    }
    Test-Step 'Client choice: None = connect yourself; Ask without a person does not prompt' {
        if ($null -ne (& $m { Select-VmmRemoteClient -Client None })) { throw 'None returned a client' }
        $r = & $m { Select-VmmRemoteClient -Client Ask }
        if ($r -and -not $r.Available) { throw 'picked a missing client' }
        $true
    }
    Test-Step 'Report: parse VMMSTAGE1, compare size and SHA256 per file' {
        $exp = @([pscustomobject]@{ DestName = 'a.iso'; Size = 10; Sha256 = 'AA' }, [pscustomobject]@{ DestName = 'b.exe'; Size = 5; Sha256 = '' },
                 [pscustomobject]@{ DestName = 'c.exe'; Size = 7; Sha256 = 'CC' }, [pscustomobject]@{ DestName = 'd.exe'; Size = 9; Sha256 = '' })
        $rep = @(& $m { ConvertFrom-VmmHandoffReport -Text "noise`nVMMSTAGE1|OTHER|a.iso*10*AA`nVMMSTAGE1|SMOKE-HOST|a.iso*10*aa|b.exe*5*11|c.exe*7*DD|d.exe*-1*" -HostName 'smoke-host' })
        Assert-Equal $rep.Count 4 'rows'
        $rows = @(& $m { param($e, $r) Compare-VmmHandoffFile -Expected $e -Reported $r -Method 'test' } $exp $rep)
        Assert-Equal (($rows | ForEach-Object Status) -join ',') 'OK,OK,HashMismatch,Missing' 'status'
        $rows = @(& $m { param($e) Compare-VmmHandoffFile -Expected $e -Reported @([pscustomobject]@{ DestName = 'a.iso'; Size = 10; Sha256 = '' }, [pscustomobject]@{ DestName = 'b.exe'; Size = 6; Sha256 = '' }) } $exp)
        Assert-Equal (($rows | ForEach-Object Status) -join ',') 'NotHashed,SizeMismatch,Missing,Missing' 'status (size only)'
    }
    Test-Step 'Host script: copies into the target only, checks SHA256, report verifies' {
        $src = Join-Path $tmpHand 'src\pkg.bin'
        [IO.File]::WriteAllBytes($src, [byte[]](1..200))
        $sha = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
        $items = @([pscustomobject]@{ DestName = 'pkg.bin'; Size = 200; Sha256 = $sha; Sources = @((Join-Path $tmpHand 'missing\pkg.bin'), $src) })
        $dest = Join-Path $tmpHand 'host-temp'
        $text = & $m { param($t, $i) Get-VmmHandoffScript -HostName 'smoke-host' -Target $t -Items $i } $dest $items
        $tok = $null; $err = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$err)
        if ($err.Count) { throw "script does not parse: $($err[0].Message)" }
        if ($text -match 'Remove-Item|Start-Process|Invoke-Expression|iex |Set-ItemProperty|New-Service') { throw 'script does more than copy and read' }
        $text = $text -replace '\$R \| clip\.exe', '$null = $R'   # keep the clipboard of whoever runs the test
        $out = (& ([scriptblock]::Create($text)) 6>&1 | ForEach-Object { "$_" }) -join "`n"
        if (-not (Test-Path -LiteralPath (Join-Path $dest 'pkg.bin'))) { throw 'file not copied' }
        $rec = [pscustomobject]@{ Name = 'SMOKE-HOST' }
        $ev = & $m { param($r, $i, $t, $o) Get-VmmHandoffEvidence -Record $r -Items $i -Target $t -Pasted $o -NoNetwork } $rec $items $dest $out
        if (-not $ev.Verified) { throw "not verified: $(($ev.Rows | ForEach-Object { "$($_.File)=$($_.Status)" }) -join ', ') / $out" }
        Assert-Equal $ev.Method 'host report (VMMSTAGE1)' 'method'
    }
    Test-Step 'Stage offers the handoff only when RDP can help, and records only verified files' {
        $t = [IO.File]::ReadAllText((Join-Path $repo 'VmMaintenance\Public\Invoke-VmmWorkflowStep.ps1'))
        foreach ($want in 'VmmStagingGate\|VmmShareUnreachable\|VmmVpnDown', 'Test-VmmInteractive', 'Start-VmmRemoteHandoff -HostName \$name -Reason \$why -NoMarkStep', 'if \(-not \$h\.Verified\) \{ throw \$copyErr \}') {
            if ($t -notmatch $want) { throw "Invoke-VmmWorkflowStep: no match for $want" }
        }
        $true
    }
} finally {
    & $m { param($c) $script:VmmNonInteractive = $null; $script:VmmConfig = $c } $savedHand
    Remove-Item -LiteralPath $tmpHand -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 9. Exits, Ctrl+C, failures
Write-Host '9. Exit codes, Ctrl+C and failures (temporary folders, new PowerShell processes, no host, no Azure)' -ForegroundColor Cyan
$tmpExit = Join-Path ([IO.Path]::GetTempPath()) ('vmm-smoke-exit-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path (Join-Path $tmpExit 'hostC'))
$savedExit = & $m { $script:VmmConfig }
try {
    & $m { param($r) Exit-VmmInstanceLock; $script:VmmConfig = @{ Log = @{ ToFile = $false }; Paths = @{ DataDir = (Join-Path $r 'data'); ReportDir = (Join-Path $r 'reports') } } } $tmpExit
    Test-Step 'Exit codes: one table for vmm and the entry scripts (1 error, 2 usage, 3 time window, 4 VPN, 5 security, 6 busy)' {
        $r = & $m { foreach ($id in 'VmmCliUnknown', 'VmmWindowBlocked', 'VmmVpnDown', 'VmmStoreIntegrity', 'VmmAgentResultRejected', 'VmmInstanceLocked', 'VmmStepFailed') { Get-VmmExitCode -ErrorRecord (New-VmmErrorRecord -Activity 'x' -ErrorId $id) } }
        Assert-Equal ($r -join ',') '2,3,4,5,5,6,1' 'exit codes'
    }
    Test-Step 'New PowerShell process: vmm unknown command exits 2; an entry script exits 3 when blocked, 0 when done; all in the day log' {
        $cfg = New-SmokeConfigFile -Root (Join-Path $tmpExit 'child')
        $r = Invoke-SmokeChild -File (Join-Path $repo 'Scripts\vmm.ps1') -ArgumentList '--config', $cfg, '--no-color', 'nosuchcommand'
        Assert-Equal $r.Code 2 'vmm nosuchcommand exit code'
        $entry = Join-Path $tmpExit 'child\Smoke-Entry.ps1'
        Set-Content -LiteralPath $entry -Encoding ASCII -Value @(
            'param([switch]$Block)'
            "`$ConfigPath = '$($cfg -replace "'", "''")'"
            ". '$((Join-Path $repo 'Scripts\_Bootstrap.ps1') -replace "'", "''")'"
            'function Test-SmokeEntry { param([switch]$Block) if ($Block) { throw (& (Get-Module VmMaintenance) { New-VmmErrorRecord -Activity ''Blocked by the smoke time window.'' -ErrorId ''VmmWindowBlocked'' }) } }'
            'Invoke-VmmEntryScript -Command ''Test-SmokeEntry'' -Parameters $PSBoundParameters -Name ''Smoke-Entry.ps1'''
        )
        Assert-Equal (Invoke-SmokeChild -File $entry -ArgumentList '-Block').Code 3 'blocked entry script exit code'
        Assert-Equal (Invoke-SmokeChild -File $entry).Code 0 'finished entry script exit code'
        $log = (@(Get-ChildItem -LiteralPath (Join-Path $tmpExit 'child\logs') -Filter 'vmm_*.log' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n")
        foreach ($want in '\|ERROR\|vmm nosuchcommand exit code 2', '\|ERROR\|Smoke-Entry\.ps1 FAILED, exit code 3 after', '\|MUTED\|Smoke-Entry\.ps1 done after') {
            if ($log -notmatch $want) { throw "day log has no line matching '$want'" }
        }
        $true
    }
    Test-Step 'Staging copy through a PowerShell drive (as Stage maps the admin share): complete, no .part, nothing written elsewhere' {
        $src = Join-Path $tmpExit 'src.bin'
        [IO.File]::WriteAllBytes($src, [byte[]](1..250))
        $cwd = [Environment]::CurrentDirectory
        $before = @(Get-ChildItem -LiteralPath $cwd -Force | ForEach-Object Name)
        & $m {
            param($s, $root)
            function Copy-SmokeThroughDrive { param($s, $root) New-PSDrive -Name VmmSmokeC -PSProvider FileSystem -Root $root | Out-Null; try { Copy-VmmFileWithProgress -Source $s -Destination 'VmmSmokeC:\copy.bin' } finally { Remove-PSDrive -Name VmmSmokeC -Force } }
            Copy-SmokeThroughDrive $s $root
        } $src (Join-Path $tmpExit 'hostC') 6>$null
        $dest = Join-Path $tmpExit 'hostC\copy.bin'
        if ((Get-FileHash -LiteralPath $dest).Hash -ne (Get-FileHash -LiteralPath $src).Hash) { throw 'copy differs from the source' }
        if (Test-Path -LiteralPath "$dest.part") { throw '.part file left behind' }
        $new = @(Get-ChildItem -LiteralPath $cwd -Force | ForEach-Object Name | Where-Object { $_ -notin $before })
        if ($new) { throw "written into the process folder instead: $($new -join ', ')" }
        $true
    }
    Test-Step 'Staging copy: a copy that fails at the end leaves no .part file' {
        $dest = Join-Path $tmpExit 'fail.bin'
        $msg = & $m {
            param($s, $d)
            function script:Move-Item { throw 'There is not enough space on the disk.' }
            try { Copy-VmmFileWithProgress -Source $s -Destination $d; 'no error' } catch { $_.Exception.Message } finally { Remove-Item -LiteralPath function:Move-Item }
        } (Join-Path $tmpExit 'src.bin') $dest
        if ($msg -notmatch 'not enough space') { throw "the failure was not raised: $msg" }
        if (Test-Path -LiteralPath "$dest.part") { throw '.part file left behind' }
        $true
    }
    Test-Step 'Ctrl+C on vmm step: INTERRUPTED in the log, step recorded as Failed, lock released, credentials cleared' {
        $r = Invoke-SmokeStopped -Root (Join-Path $tmpExit 'stop-step') -Setup {
            param($Root, $Sync)
            $script:VmmConfig = @{ Log = @{ ToFile = $false }; Paths = @{ DataDir = (Join-Path $Root 'data'); ReportDir = (Join-Path $Root 'reports') } }
            $script:TestSync = $Sync
            $rec = New-VmmHostRecord -Name 'smoke-stop'
            Set-VmmStepState -Record $rec -Step 'Precheck' -Status 'Success'
            Set-VmmStepState -Record $rec -Step 'SnapStart' -Status 'NotNeeded'
            $script:TestStore = [pscustomobject]@{ Updated = $null; Hosts = @($rec) }
            function script:Read-VmmStore { $script:TestStore }
            function script:Save-VmmStore { param($Store) }
            function script:Assert-VmmWindow { }
            function script:Get-VmmHostPolicy { param($Record) [pscustomobject]@{ Workable = $true; Warnings = @(); Scope = 'Server'; Os = 'test'; Why = '' } }
            function script:Copy-VmmStagingPackage { param($HostName) $script:TestSync.Entered = $true; Start-Sleep -Seconds 120 }
            $s = New-Object System.Security.SecureString; $s.AppendChar('x')
            $script:VmmCredentials = @{ Windows = New-Object System.Management.Automation.PSCredential -ArgumentList 'test', $s }
        } -Run {
            Invoke-VmmCli -Command step -Arguments @('-HostName', 'smoke-stop', '-Step', 'Stage')
        } -Inspect {
            [pscustomobject]@{ Log = (@($script:VmmLogBuffer | ForEach-Object { "$($_.Level)|$($_.Text)" }) -join "`n"); Step = $script:TestStore.Hosts[0].Steps.Stage
                               Lock = [bool]$script:VmmInstanceLock; Creds = @($script:VmmCredentials.Keys).Count }
        }
        Assert-Equal $r.State 'Stopped' 'run state'
        $o = $r.Result[0]
        foreach ($want in 'Error\|\[SMOKE-STOP\] Stage INTERRUPTED \(Ctrl\+C\)', 'Error\|vmm step -HostName -Step INTERRUPTED \(Ctrl\+C\)') { if ($o.Log -notmatch $want) { throw "log has no line matching '$want'" } }
        Assert-Equal $o.Step.Status 'Failed' 'step status'
        if ($o.Step.Note -notmatch 'INTERRUPTED') { throw "step note: $($o.Step.Note)" }
        Assert-Equal $o.Lock $false 'lock held'
        Assert-Equal $o.Creds 0 'credentials left in memory'
    }
    Test-Step 'Ctrl+C during disk expansion, after the VMs went down: the power-state recovery runs' {
        $r = Invoke-SmokeStopped -Root (Join-Path $tmpExit 'stop-expand') -Setup {
            param($Root, $Sync)
            $script:VmmConfig = @{ Log = @{ ToFile = $false } }
            $script:TestSync = $Sync
            function script:Read-VmmServerList { 'srv-smoke' }
            function script:Start-Transcript { }
            function script:Stop-Transcript { }
            function script:Assert-VmmModule { }
            function script:Connect-VmmAzure { }
            function script:Assert-VmmWindow { }
            function script:Set-VmmSubscription { }
            function script:New-VmmExpandPlan {
                [pscustomobject]@{ ComputerName = 'srv-smoke'; VMName = 'vm-smoke'; MatchedBy = 'VM name'; SubscriptionId = 'sub'; ResourceGroup = 'rg'; InitialState = 'running'; Sku = 'Premium_LRS'
                                   CurrentGB = 127; NewGB = 256; Action = 'Resize'; Status = 'Ready'; Notes = ''; Job = $null; Started = $false; Snapshot = $null; CBeforeGB = $null; CAfterGB = $null; FinalState = $null }
            }
            function script:Stop-AzVM { 'job' }
            function script:Wait-VmmJob { param($Item, $Label) if ($Label -eq 'Deallocate') { $script:TestSync.Entered = $true; Start-Sleep -Seconds 120 } }
            function script:Invoke-VmmPowerRecovery { param($Item) $script:TestSync.Recovered = (@($Item | ForEach-Object VMName) -join ',') }
        } -Run {
            param($Root)
            $name = 'srv-smoke'
            Expand-VmmOsDisk -ComputerName $name -Apply -Confirm:$false -TenantId 'test' -SnapshotTags @{ Purpose = 'test' } -LogDir (Join-Path $Root 'expand')
        }
        Assert-Equal $r.State 'Stopped' 'run state'
        Assert-Equal $r.Sync.Recovered 'vm-smoke' 'VMs given to the recovery'
        Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $tmpExit 'stop-expand\expand') -Filter 'Results_*.csv').Count 1 'results files'
    }
    Test-Step 'Failed step: recorded as Failed, raised as VmmStepFailed; missing access raised as VmmStepBlocked' {
        & $m {
            $saved = @{ R = ${function:Read-VmmStore}; S = ${function:Save-VmmStore}; W = ${function:Assert-VmmWindow}; C = ${function:Invoke-VmmFleetCheck}; B = ${function:New-VmmBlockerReport} }
            $script:SmokeStore = [pscustomobject]@{ Updated = $null; Hosts = @(New-VmmHostRecord -Name 'smoke-step') }
            function script:Read-VmmStore { $script:SmokeStore }
            function script:Save-VmmStore { param($Store) }
            function script:Assert-VmmWindow { }
            function script:Invoke-VmmFleetCheck { throw $script:SmokeFail }
            function script:New-VmmBlockerReport { 'Blockers\SMOKE-STEP_Precheck.txt' }
            try {
                $script:SmokeFail = 'WinRM timed out after 30 s'
                $id = ''; try { Invoke-VmmWorkflowStep -HostName 'smoke-step' -Step Precheck 6>$null | Out-Null } catch { $id = "$($_.FullyQualifiedErrorId)" }
                if ($id -notlike 'VmmStepFailed*') { throw "failed step: error id '$id'" }
                if ($script:SmokeStore.Hosts[0].Steps.Precheck.Status -ne 'Failed') { throw 'failed step not recorded as Failed' }
                $script:SmokeFail = 'Access is denied. (0x80070005)'
                $id = ''; try { Invoke-VmmWorkflowStep -HostName 'smoke-step' -Step Precheck -Contact Later 6>$null | Out-Null } catch { $id = "$($_.FullyQualifiedErrorId)" }
                if ($id -notlike 'VmmStepBlocked*') { throw "blocked step: error id '$id'" }
            } finally {
                Set-Item function:script:Read-VmmStore $saved.R; Set-Item function:script:Save-VmmStore $saved.S; Set-Item function:script:Assert-VmmWindow $saved.W
                Set-Item function:script:Invoke-VmmFleetCheck $saved.C; Set-Item function:script:New-VmmBlockerReport $saved.B
                Remove-Variable -Name SmokeStore, SmokeFail -Scope Script -ErrorAction SilentlyContinue
            }
            $true
        }
    }
    Test-Step 'AI / issue text: ids, Azure ids, domains, resource groups, host names masked; fails closed when the store cannot be read' {
        & $m {
            $saved = ${function:Read-VmmStore}
            try {
                function script:Read-VmmStore { [pscustomobject]@{ Hosts = @([pscustomobject]@{ Name = 'SMOKEAI1'; Fqdn = 'smokeai1.smoke-corp.example'; Azure = [pscustomobject]@{ ResourceGroup = 'rg-smoke-app'; VMName = 'vm-smoke-ai'; SubscriptionId = 'x' } }) } }
                $g = [guid]::NewGuid().ToString()
                $t = (ConvertTo-VmmAiSafeText -Text "id $g on smokeai1.smoke-corp.example, vm-smoke-ai in rg-smoke-app, /subscriptions/$g/resourceGroups/rg-smoke-app, smoke-corp.example").Text
                foreach ($leak in $g, 'smokeai1', 'smoke-corp', 'vm-smoke-ai', 'rg-smoke-app') { if ($t -match [regex]::Escape($leak)) { throw "'$leak' not masked: $t" } }
                function script:Read-VmmStore { throw 'store unreadable' }
                $id = ''; try { ConvertTo-VmmAiSafeText -Text 'smokeai1' | Out-Null } catch { $id = "$($_.FullyQualifiedErrorId)" }
                if ($id -notlike 'VmmAiUnsafe*') { throw "store failure: error id '$id' (the text would have left with host names in it)" }
            } finally { Set-Item function:script:Read-VmmStore $saved }
            $true
        }
    }
    Test-Step 'Lock file that cannot be opened: VmmInstanceLockFile, not "vmm is already running"' {
        $bad = Join-Path $tmpExit 'lockbad'
        [void](New-Item -ItemType Directory -Path (Join-Path $bad 'vmm.lock') -Force)   # a folder where the lock file belongs
        $id = & $m {
            param($d)
            $c = $script:VmmConfig
            $script:VmmConfig = @{ Log = @{ ToFile = $false }; Paths = @{ DataDir = $d; ReportDir = $d } }
            try { Enter-VmmInstanceLock | Out-Null; 'no error' } catch { "$($_.FullyQualifiedErrorId)" } finally { Exit-VmmInstanceLock; $script:VmmConfig = $c }
        } $bad
        if ($id -notlike 'VmmInstanceLockFile*') { throw "error id '$id'" }
        $true
    }
    Test-Step 'Log file that cannot be written: one warning, every line kept on screen; a nested line is written, not dropped' {
        $r = & $m {
            param($root)
            $c = $script:VmmConfig; $e = $script:VmmLogFileError
            [void](New-Item -ItemType Directory -Path (Join-Path $root 'logbad\data') -Force)
            Set-Content -LiteralPath (Join-Path $root 'logbad\logs') -Value 'a file where the logs folder belongs'
            try {
                $script:VmmConfig = @{ Log = @{ ToFile = $true; Encrypt = $false }; Paths = @{ DataDir = (Join-Path $root 'logbad\data'); ReportDir = (Join-Path $root 'logbad\reports') } }
                $script:VmmLogFileError = $null; $script:VmmLogBuffer = $null; $script:VmmLogPending = $null
                $w = @(Add-VmmLogEntry -Text 'smoke line one' 3>&1) + @(Add-VmmLogEntry -Text 'smoke line two' 3>&1)
                $warn = @($w | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count
                $buf = (@($script:VmmLogBuffer | ForEach-Object Text) -join "`n")
                $script:VmmConfig = @{ Log = @{ ToFile = $true; Encrypt = $false }; Paths = @{ DataDir = (Join-Path $root 'lognest\data'); ReportDir = (Join-Path $root 'lognest\reports') } }
                $script:VmmLogFileError = $null; $script:VmmLogPending = $null
                $script:VmmLogWriting = $true; Add-VmmLogEntry -Text 'smoke nested line'; $script:VmmLogWriting = $false
                Add-VmmLogEntry -Text 'smoke outer line'
                $file = (@(Get-ChildItem -LiteralPath (Join-Path $root 'lognest\logs') -Filter 'vmm_*.log' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n")
                [pscustomobject]@{ Warnings = $warn; Buffer = $buf; File = $file }
            } finally { $script:VmmConfig = $c; $script:VmmLogFileError = $e; $script:VmmLogWriting = $false; $script:VmmLogPending = $null }
        } $tmpExit
        Assert-Equal $r.Warnings 1 'warnings for a log file that cannot be written'
        foreach ($want in 'smoke line one', 'smoke line two', 'Log file not written') { if ($r.Buffer -notmatch $want) { throw "on-screen log has no '$want'" } }
        if ($r.File -notmatch '(?s)smoke nested line.*smoke outer line') { throw "nested line missing or out of order: $($r.File)" }
        $true
    }
} finally {
    & $m { param($c) Exit-VmmInstanceLock; $script:VmmConfig = $c } $savedExit
    Remove-Item -LiteralPath $tmpExit -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 10. Snapshot points
Write-Host '10. Four Azure snapshot points and the manual check (mocked Azure, temporary store in memory)' -ForegroundColor Cyan
$savedSnap = & $m {
    $s = @{ Cfg = $script:VmmConfig }
    foreach ($f in 'Read-VmmStore', 'Save-VmmStore', 'Assert-VmmWindow', 'Get-VmmHostPolicy', 'New-VmmSnapshot', 'Get-VmmRecentSnapshotSet', 'Assert-VmmModule', 'Connect-VmmAzure', 'Invoke-VmmFleetCheck') {
        $s[$f] = (Get-Item "function:$f").ScriptBlock
    }
    $script:SnapSavedRecent = $s['Get-VmmRecentSnapshotSet']
    $script:VmmConfig = @{ Log = @{ ToFile = $false } }
    function script:Read-VmmStore { $script:SnapStore }
    function script:Save-VmmStore { param($Store) }
    function script:Assert-VmmWindow { }
    function script:Assert-VmmModule { }
    function script:Connect-VmmAzure { }
    function script:Get-VmmHostPolicy { param($Record) [pscustomobject]@{ Workable = $true; Warnings = @(); Scope = 'Server'; Os = 'test'; Why = '' } }
    function script:New-VmmSnapshot {
        param($VMName, $Subscription, $Label, $ExtraTags, [switch]$PassThru, [switch]$Confirm)
        $script:SnapCalls += , ([pscustomobject]@{ VMName = $VMName; Label = $Label; Tags = $ExtraTags })
        foreach ($d in 'OsDisk', 'DataDisk_0') { [pscustomobject]@{ Snapshot = "$($VMName)_$($Label)_$($d)_snap" } }
    }
    function script:Get-VmmRecentSnapshotSet { param($VMName, $Subscription, $MaxAgeMinutes) $script:SnapRecent }
    function script:Invoke-VmmFleetCheck { [pscustomobject]@{ Reachable = 'Yes'; OS = 'Microsoft Windows Server 2019 Standard'; Build = '17763'; CFreeGB = 80; Sql = 'MSSQLSERVER'; PendingReboot = 'No' } }
    function script:New-SnapTestHost {
        # A fresh store with one Azure host (or not) whose steps up to -Upto are done
        param([string]$Upto, [switch]$NotAzure)
        $r = New-VmmHostRecord -Name 'snap-host'
        if (-not $NotAzure) { $r.Azure = [pscustomobject]@{ SubscriptionId = 'sub'; ResourceGroup = 'rg'; VMName = 'vm-snap'; PowerState = 'running' } } else { $r.Platform = 'VMware' }
        $r.Check = [pscustomobject]@{ CFreeGB = 80 }
        if ($Upto) { foreach ($d in Get-VmmWorkflowDefinition) { Set-VmmStepState -Record $r -Step $d.Name -Status 'Success'; if ($d.Name -eq $Upto) { break } } }
        $script:SnapStore = [pscustomobject]@{ Updated = $null; Hosts = @($r) }
        $script:SnapCalls = @(); $script:SnapRecent = $null
        $r
    }
    function script:Invoke-SnapTestStep {
        # Runs a step, returns the error id ('' when it worked)
        param([hashtable]$P)
        try { Invoke-VmmWorkflowStep -HostName 'snap-host' @P 6>$null | Out-Null; '' } catch { "$($_.FullyQualifiedErrorId)".Split(',')[0] }
    }
    $s
}
try {
    Test-Step 'Workflow: ten steps in order; SnapStart allowed in business hours unless Policy.SnapStartInBusinessHours is off' {
        $r = & $m {
            $a = (Get-VmmWorkflowDefinition | ForEach-Object Name) -join ','
            $c1 = (Get-VmmWorkflowDefinition | Where-Object Name -eq 'SnapStart').Class
            $script:VmmConfig = @{ Log = @{ ToFile = $false }; Policy = @{ SnapStartInBusinessHours = $false } }
            $c2 = (Get-VmmWorkflowDefinition | Where-Object Name -eq 'SnapStart').Class
            $script:VmmConfig = @{ Log = @{ ToFile = $false } }
            $sn = (Get-VmmWorkflowDefinition | Where-Object Snapshot | ForEach-Object Name) -join ','
            $sq = (Get-VmmWorkflowDefinition | Where-Object SqlInvasive | ForEach-Object Name) -join ','
            "$a|$c1|$c2|$sn|$sq"
        }
        Assert-Equal $r 'Precheck,SnapStart,Stage,SnapPreSql,ExpandDisk,Upgrade,SnapPostSql,Verify,ManualCheck,SnapFinal|Staging|Change|SnapStart,SnapPreSql,SnapPostSql,SnapFinal|ExpandDisk,Upgrade' 'definition'
    }
    Test-Step 'SnapStart: no full set from the last hour = every disk snapshotted, tagged SnapPoint and RetentionDays' {
        $o = & $m {
            [void](New-SnapTestHost -Upto 'Precheck')
            $script:SnapRecent = [pscustomobject]@{ Complete = $false; Disks = 2; Missing = @('vm-snap-data0'); Snapshots = @('x'); Newest = (Get-Date); MaxAgeMinutes = 60 }
            $id = Invoke-SnapTestStep @{ Step = 'SnapStart' }
            [pscustomobject]@{ Id = $id; Calls = $script:SnapCalls; St = $script:SnapStore.Hosts[0].Steps.SnapStart }
        }
        Assert-Equal $o.Id '' 'error'
        Assert-Equal @($o.Calls).Count 1 'snapshot sets taken'
        Assert-Equal $o.Calls[0].Label 'snap-Start' 'label'
        Assert-Equal $o.Calls[0].Tags.SnapPoint 'SnapStart' 'SnapPoint tag'
        Assert-Equal $o.Calls[0].Tags.RetentionDays '7' 'RetentionDays tag'
        Assert-Equal $o.St.Status 'Success' 'status'
        Assert-Equal $o.St.Snapshot 'vm-snap_snap-Start_OsDisk_snap, vm-snap_snap-Start_DataDisk_0_snap' 'recorded snapshots'
        if ($o.St.Note -notmatch 'no recent snapshot of: vm-snap-data0') { throw "note: $($o.St.Note)" }
    }
    Test-Step 'SnapStart: every disk has one from the last hour (portal counts) = NotNeeded, nothing taken; -Decline = Skipped' {
        $o = & $m {
            [void](New-SnapTestHost -Upto 'Precheck')
            $script:SnapRecent = [pscustomobject]@{ Complete = $true; Disks = 2; Missing = @(); Snapshots = @('portal-os', 'portal-data'); Newest = (Get-Date).ToUniversalTime(); MaxAgeMinutes = 60 }
            $a = Invoke-SnapTestStep @{ Step = 'SnapStart' }
            $st1 = $script:SnapStore.Hosts[0].Steps.SnapStart; $n1 = @($script:SnapCalls).Count
            [void](New-SnapTestHost -Upto 'Precheck')
            $b = Invoke-SnapTestStep @{ Step = 'SnapStart'; Decline = $true }
            $st2 = $script:SnapStore.Hosts[0].Steps.SnapStart; $n2 = @($script:SnapCalls).Count
            $c = Invoke-SnapTestStep @{ Step = 'Precheck'; Decline = $true }
            [pscustomobject]@{ A = $a; B = $b; C = $c; S1 = $st1; S2 = $st2; N = "$n1,$n2" }
        }
        Assert-Equal "$($o.A)|$($o.B)" '|' 'errors'
        Assert-Equal $o.S1.Status 'NotNeeded' 'recent set'
        if ($o.S1.Note -notmatch 'portal-os, portal-data') { throw "note: $($o.S1.Note)" }
        Assert-Equal $o.S2.Status 'Skipped' 'declined'
        Assert-Equal $o.N '0,0' 'snapshot sets taken'
        Assert-Equal $o.C 'VmmStepUsage' '-Decline on another step'
    }
    Test-Step 'Order: Stage needs SnapStart; SnapPreSql NotNeeded with a recent set, taken without one' {
        $o = & $m {
            [void](New-SnapTestHost -Upto 'Precheck')
            $a = Invoke-SnapTestStep @{ Step = 'Stage' }
            [void](New-SnapTestHost -Upto 'Stage')
            $script:SnapRecent = [pscustomobject]@{ Complete = $true; Disks = 2; Missing = @(); Snapshots = @('s1', 's2'); Newest = (Get-Date).ToUniversalTime(); MaxAgeMinutes = 60 }
            $b = Invoke-SnapTestStep @{ Step = 'SnapPreSql' }; $s1 = $script:SnapStore.Hosts[0].Steps.SnapPreSql.Status
            [void](New-SnapTestHost -Upto 'Stage')
            $c = Invoke-SnapTestStep @{ Step = 'SnapPreSql' }; $s2 = $script:SnapStore.Hosts[0].Steps.SnapPreSql.Status
            "$a|$b$s1|$c$s2|$(@($script:SnapCalls).Count)|$($script:SnapCalls[0].Label)"
        }
        Assert-Equal $o 'VmmStepOrder|NotNeeded|Success|1|snap-PreSql' 'results'
    }
    Test-Step 'Not Azure: SnapStart/SnapPostSql/SnapFinal remind (NotNeeded), SnapPreSql needs a confirmed backup' {
        $o = & $m {
            [void](New-SnapTestHost -Upto 'Precheck' -NotAzure)
            $a = Invoke-SnapTestStep @{ Step = 'SnapStart' }; $s1 = $script:SnapStore.Hosts[0].Steps.SnapStart
            [void](New-SnapTestHost -Upto 'Stage' -NotAzure)
            $b = Invoke-SnapTestStep @{ Step = 'SnapPreSql' }
            $c = Invoke-SnapTestStep @{ Step = 'SnapPreSql'; Confirmed = $true }; $s2 = $script:SnapStore.Hosts[0].Steps.SnapPreSql.Status
            [void](New-SnapTestHost -Upto 'ManualCheck' -NotAzure)
            $d = Invoke-SnapTestStep @{ Step = 'SnapFinal' }; $s3 = $script:SnapStore.Hosts[0].Steps.SnapFinal.Status
            [pscustomobject]@{ R = "$a|$b|$c$s2|$d$s3|$(@($script:SnapCalls).Count)"; Note = $s1.Note; S = $s1.Status }
        }
        Assert-Equal $o.R '|VmmGuided|Success|NotNeeded|0' 'results'
        Assert-Equal $o.S 'NotNeeded' 'SnapStart status'
        if ($o.Note -notmatch 'Not an Azure VM \(VMware\)') { throw "note: $($o.Note)" }
    }
    Test-Step 'No per-step checkpoints: ExpandDisk and Upgrade take no snapshot; SnapPostSql always does' {
        $o = & $m {
            [void](New-SnapTestHost -Upto 'SnapPreSql')
            $a = Invoke-SnapTestStep @{ Step = 'ExpandDisk' }    # 80 GB free = NotNeeded
            $b = Invoke-SnapTestStep @{ Step = 'Upgrade'; Confirmed = $true }
            $n = @($script:SnapCalls).Count
            $script:SnapRecent = [pscustomobject]@{ Complete = $true; Disks = 2; Missing = @(); Snapshots = @('s1'); Newest = (Get-Date).ToUniversalTime(); MaxAgeMinutes = 60 }
            $c = Invoke-SnapTestStep @{ Step = 'SnapPostSql' }
            "$a|$b|$n|$c|$(@($script:SnapCalls).Count)|$($script:SnapCalls[0].Label)|$($script:SnapStore.Hosts[0].Steps.ExpandDisk.Status)"
        }
        Assert-Equal $o '||0||1|snap-PostSql|NotNeeded' 'results'
    }
    Test-Step 'Launched upgrade: SnapPostSql waits, Upgrade -Confirmed finishes it (no relaunch)' {
        $o = & $m {
            $r = New-SnapTestHost -Upto 'SnapPreSql'
            Set-VmmStepState -Record $r -Step 'ExpandDisk' -Status 'NotNeeded'
            Set-VmmStepState -Record $r -Step 'Upgrade' -Status 'Launched'
            $msg = ''; try { Invoke-VmmWorkflowStep -HostName 'snap-host' -Step SnapPostSql 6>$null | Out-Null } catch { $msg = $_.Exception.Message }
            $script:VmmConfig = @{ Log = @{ ToFile = $false }; Upgrade = @{ Mode = 'RunCommand'; CommandLine = 'x' } }
            function script:Invoke-AzVMRunCommand { throw 'relaunched' }
            $b = Invoke-SnapTestStep @{ Step = 'Upgrade'; Confirmed = $true }
            Remove-Item function:script:Invoke-AzVMRunCommand
            $script:VmmConfig = @{ Log = @{ ToFile = $false } }
            [pscustomobject]@{ Msg = $msg; B = $b; St = $script:SnapStore.Hosts[0].Steps.Upgrade }
        }
        if ($o.Msg -notmatch "Upgrade' is Launched" -or $o.Msg -notmatch '-Step Upgrade -Confirmed') { throw "message: $($o.Msg)" }
        Assert-Equal $o.B '' 'confirm error'
        Assert-Equal $o.St.Status 'Success' 'Upgrade status'
        if ($o.St.Note -notmatch 'finished, confirmed') { throw "note: $($o.St.Note)" }
    }
    Test-Step 'ManualCheck: confirm or bypass with a reason; SnapFinal only after it, and it is the last step' {
        $o = & $m {
            [void](New-SnapTestHost -Upto 'Verify')
            $a = Invoke-SnapTestStep @{ Step = 'SnapFinal' }
            $b = Invoke-SnapTestStep @{ Step = 'ManualCheck' }
            $c = Invoke-SnapTestStep @{ Step = 'ManualCheck'; Bypass = $true; BypassReason = 'short' }
            $d = Invoke-SnapTestStep @{ Step = 'ManualCheck'; Bypass = $true; BypassReason = 'app owner checked it, ticket 4711' }
            $mc = $script:SnapStore.Hosts[0].Steps.ManualCheck
            $e = Invoke-SnapTestStep @{ Step = 'SnapFinal' }
            $next = Get-VmmNextStep -Record $script:SnapStore.Hosts[0]
            [pscustomobject]@{ R = "$a|$b|$c|$d|$e"; Mc = $mc; Final = $script:SnapStore.Hosts[0].Steps.SnapFinal.Status; Label = $script:SnapCalls[0].Label; Next = $next
                               Stage = (Get-VmmHostStage -Record $script:SnapStore.Hosts[0]) }
        }
        Assert-Equal $o.R 'VmmStepOrder|VmmGuided|VmmBypassReason||' 'results'
        Assert-Equal $o.Mc.Status 'Skipped' 'bypassed check'
        if ($o.Mc.Note -notmatch 'BYPASSED by operator: app owner checked it') { throw "note: $($o.Mc.Note)" }
        Assert-Equal $o.Final 'Success' 'SnapFinal'
        Assert-Equal $o.Label 'snap-Final' 'label'
        Assert-Equal $o.Next $null 'next step after SnapFinal'
        Assert-Equal $o.Stage 'Done' 'host stage'
    }
    Test-Step 'Store from before 2.17.0: PreSnapshot becomes SnapPreSql, passed points are Skipped, ManualCheck/SnapFinal stay to do' {
        $o = & $m {
            $r = New-VmmHostRecord -Name 'old-host'
            foreach ($s in 'Precheck', 'Stage', 'PreSnapshot', 'ExpandDisk', 'Upgrade', 'Verify') { Set-VmmStepState -Record $r -Step $s -Status 'Success' -Note "old $s" }
            Update-VmmStepName -Record $r
            $p = $r.Steps.PSObject.Properties
            [pscustomobject]@{ Old = [bool]$p['PreSnapshot']; Pre = $r.Steps.SnapPreSql.Note; Start = $r.Steps.SnapStart.Status; Post = $r.Steps.SnapPostSql.Status
                               Mc = [bool]$p['ManualCheck']; Next = (Get-VmmNextStep -Record $r).Name }
        }
        Assert-Equal "$($o.Old)|$($o.Pre)|$($o.Start)|$($o.Post)|$($o.Mc)|$($o.Next)" 'False|old PreSnapshot|Skipped|Skipped|False|ManualCheck' 'migrated record'
    }
    Test-Step 'Recent set check: every managed disk needs a snapshot from the last hour; older ones and other disks do not count' {
        $o = & $m {
            Set-Item function:script:Get-VmmRecentSnapshotSet $script:SnapSavedRecent
            function script:Set-VmmSubscription { param($Subscription) }
            $os = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/vm-os'
            $dd = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/vm-data0'
            $script:TestVm = [pscustomobject]@{ Name = 'vm-snap'; ResourceGroupName = 'rg'; StorageProfile = [pscustomobject]@{
                OsDisk = [pscustomobject]@{ ManagedDisk = [pscustomobject]@{ Id = $os } }; DataDisks = @([pscustomobject]@{ ManagedDisk = [pscustomobject]@{ Id = $dd } }) } }
            function script:Get-AzVM { $script:TestVm }
            $now = [datetime]'2026-11-16T12:00:00Z'
            $snap = { param($n, $src, $min) [pscustomobject]@{ Name = $n; TimeCreated = $now.ToUniversalTime().AddMinutes(-$min); CreationData = [pscustomobject]@{ SourceResourceId = $src } } }
            $script:TestSnaps = @((& $snap 'portal-os' $os 20), (& $snap 'old-data' $dd 90), (& $snap 'other' '/x/disks/other' 5))
            function script:Get-AzSnapshot { $script:TestSnaps }
            $a = Get-VmmRecentSnapshotSet -VMName 'vm-snap' -MaxAgeMinutes 60 -Now $now
            $script:TestSnaps += (& $snap 'portal-data' $dd 30)
            $b = Get-VmmRecentSnapshotSet -VMName 'vm-snap' -MaxAgeMinutes 60 -Now $now
            Remove-Item function:script:Get-AzVM, function:script:Get-AzSnapshot, function:script:Set-VmmSubscription
            "$($a.Complete) $($a.Missing -join ',') | $($b.Complete) $($b.Snapshots -join ',') $($b.Newest.ToString('HH:mm'))"
        }
        Assert-Equal $o 'False vm-data0 | True portal-os,portal-data 11:40' 'recent set'
    }
} finally {
    & $m { param($s)
        foreach ($k in @($s.Keys)) { if ($k -ne 'Cfg') { Set-Item "function:script:$k" $s[$k] } }
        Remove-Item function:script:New-SnapTestHost, function:script:Invoke-SnapTestStep -ErrorAction SilentlyContinue
        $script:VmmConfig = $s.Cfg
        Remove-Variable -Name SnapStore, SnapCalls, SnapRecent, SnapSavedRecent -Scope Script -ErrorAction SilentlyContinue
    } $savedSnap
}

# ---------------------------------------------------------------- Result
Write-Host ''
if ($script:fail -eq 0) {
    Write-Host ("PASSED - {0} checks" -f $script:pass) -ForegroundColor Green
    exit 0
}
Write-Host ("FAILED - {0} failed, {1} passed" -f $script:fail, $script:pass) -ForegroundColor Red
exit 1
