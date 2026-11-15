function Get-VmmRemoteClient {
    # Which remote desktop clients this laptop has, for the hands-on fallback:
    #   Rdp    = Windows Remote Desktop Connection (mstsc.exe), always on Windows
    #   Rdm    = Devolutions Remote Desktop Manager (Handoff.RdmPath, App Paths, Program Files, PATH)
    #   RdcMan = Sysinternals Remote Desktop Connection Manager (Handoff.RdcManPath, PATH, Program Files)
    # Returns one row per client: Name, Label, Path, Available, Why (why it was not found).
    [CmdletBinding()]
    param([ValidateSet('Rdp', 'Rdm', 'RdcMan')][string[]]$Name = @('Rdp', 'Rdm', 'RdcMan'))
    $pf   = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) | Where-Object { $_ } | Select-Object -Unique
    $find = {
        param([string]$Setting, [string[]]$AppPaths, [string[]]$Relative, [string[]]$Commands)
        $set = "$(Get-VmmSetting $Setting -Default '')"
        if ($set) {
            $set = [Environment]::ExpandEnvironmentVariables($set)
            if (Test-Path -LiteralPath $set -PathType Leaf) { return $set }
            return "!$Setting = $set does not exist"
        }
        foreach ($a in $AppPaths) {
            foreach ($hive in 'HKCU:', 'HKLM:') {
                $k = "$hive\Software\Microsoft\Windows\CurrentVersion\App Paths\$a"
                $v = try { (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).'(default)' } catch { $null }
                if ($v) { $v = $v.Trim('"'); if (Test-Path -LiteralPath $v -PathType Leaf) { return $v } }
            }
        }
        foreach ($root in $pf) {
            foreach ($r in $Relative) { $f = Join-Path $root $r; if (Test-Path -LiteralPath $f -PathType Leaf) { return $f } }
        }
        foreach ($c in $Commands) {
            $g = Get-Command $c -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($g) { return $g.Path }
        }
        $null
    }
    foreach ($n in $Name) {
        $path = $null; $why = ''
        switch ($n) {
            'Rdp' {
                $label = 'RDP (Remote Desktop Connection, mstsc)'
                $sys = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\mstsc.exe' } else { '' }
                if ($sys -and (Test-Path -LiteralPath $sys -PathType Leaf)) { $path = $sys }
                else { $g = Get-Command mstsc.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($g) { $path = $g.Path } }
                if (-not $path) { $why = 'mstsc.exe not found (not Windows, or Remote Desktop Connection removed)' }
            }
            'Rdm' {
                $label = 'RDM (Devolutions Remote Desktop Manager)'
                $path = & $find 'Handoff.RdmPath' @('RemoteDesktopManager.exe', 'RemoteDesktopManager64.exe', 'RemoteDesktopManagerFree.exe') `
                    @('Devolutions\Remote Desktop Manager\RemoteDesktopManager.exe', 'Devolutions\Remote Desktop Manager\RemoteDesktopManager64.exe',
                      'Devolutions\Remote Desktop Manager Free\RemoteDesktopManagerFree.exe') `
                    @('RemoteDesktopManager.exe', 'RemoteDesktopManager64.exe', 'RemoteDesktopManagerFree.exe')
                if (-not $path) { $why = 'Remote Desktop Manager not found: install it, or set Handoff.RdmPath to RemoteDesktopManager.exe' }
            }
            'RdcMan' {
                $label = 'RDCMan (Sysinternals Remote Desktop Connection Manager)'
                $path = & $find 'Handoff.RdcManPath' @('RDCMan.exe') `
                    @('Sysinternals\RDCMan.exe', 'RDCMan\RDCMan.exe', 'Microsoft\Remote Desktop Connection Manager\RDCMan.exe') @('RDCMan.exe')
                if (-not $path) { $why = 'RDCMan.exe not found: it is a single exe, set Handoff.RdcManPath to where you keep it' }
            }
        }
        if ("$path".StartsWith('!')) { $why = "$path".Substring(1); $path = $null }
        [pscustomobject]@{ Name = $n; Label = $label; Path = $path; Available = [bool]$path; Why = $why }
    }
}
