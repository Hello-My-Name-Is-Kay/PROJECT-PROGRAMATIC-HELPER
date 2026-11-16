function Enter-VmmInstanceLock {
    # One vmm at a time per data folder. The lock is an exclusive open handle on <data>\vmm.lock (no other
    # process can open the file while it is held); the system drops it when the process ends, so a crash
    # never leaves a stale lock. vmm.lock.txt beside it says who holds it: process id, start time, command
    # name (no host, no user).
    # Returns $true when this call took the lock, $false when this process already had it.
    # Throws VmmInstanceLocked when another process holds it, VmmInstanceLockFile when the file cannot be
    # opened for another reason (folder missing or not writable): that is not "vmm is already running".
    [CmdletBinding()]
    param([string]$Owner = 'vmm')
    if ($script:VmmInstanceLock) { return $false }
    $dir = Get-VmmPath -Name Data
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir 'vmm.lock'
    try {
        $fs = New-Object System.IO.FileStream($file, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        $x = $_.Exception
        while ($x.InnerException) { $x = $x.InnerException }
        # Held by another process: sharing/lock violation on Windows (32, 33); EAGAIN/EWOULDBLOCK elsewhere (tests)
        $win = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
        $codes = if ($win) { 32, 33 } else { 11, 35 }
        if (-not (($x -is [IO.IOException]) -and (($x.HResult -band 0xFFFF) -in $codes))) {
            throw (New-VmmErrorRecord -Activity 'Could not open the single-instance lock file.' -Target $file -Exception $x `
                -Fix 'Check that the vmm data folder exists and your account can write to it: vmm maint -Action Diagnose' `
                -Category OpenError -ErrorId 'VmmInstanceLockFile')
        }
        $who = ''
        try { $who = ([IO.File]::ReadAllText("$file.txt")).Trim() } catch { }
        $desc = 'another vmm process'
        if ($who -match '^(\d+)\|([^|]*)\|(.*)$') { $desc = "process $($Matches[1]) ('$($Matches[3])', started $($Matches[2]))" }
        throw (New-VmmErrorRecord -Activity "vmm is already running: $desc." -Target $file `
            -Cause 'Two vmm windows working on the same fleet store would overwrite each other.' `
            -Fix 'Finish or close the other vmm window, then run this again. Reading is still possible here: vmm log, vmm status, vmm plan.' `
            -Category ResourceBusy -ErrorId 'VmmInstanceLocked')
    }
    try { [IO.File]::WriteAllText("$file.txt", ('{0}|{1}|{2}' -f $PID, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), ($Owner -replace '[^\w\- ]', ''))) } catch { }
    $script:VmmInstanceLock = $fs
    $true
}
