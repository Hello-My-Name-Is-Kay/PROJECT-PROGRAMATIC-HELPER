function Read-VmmServerList {
    # Clean name list from -Name, else -Path, else the file in config ServerLists.<ListKey>.
    # Trims, drops blanks and '#' comments (also inline), strips domain suffixes unless -KeepDomain,
    # rejects names with characters that could break a query, de-duplicates (case-insensitive).
    [CmdletBinding()]
    param(
        [string[]]$Name,
        [string]$Path,
        [Parameter(Mandatory)][string]$ListKey,
        [ValidateSet('Upper', 'Lower', 'Keep')][string]$Case = 'Upper',
        [switch]$KeepDomain
    )
    $source = 'the -ComputerName/-VMName parameter'
    if (-not $Name) {
        if (-not $Path) { $Path = Get-VmmSetting "ServerLists.$ListKey" -Required }
        $Path = [Environment]::ExpandEnvironmentVariables($Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw (New-VmmErrorRecord -Activity 'Server list file not found.' -Target $Path `
                -Cause "The path in ServerLists.$ListKey (or -ServerList) is wrong, or the file was never created." `
                -Fix 'Create the file with one name per line (# for comments), or pass names directly on the command line.' `
                -Category ObjectNotFound -ErrorId 'VmmListNotFound')
        }
        $Name   = @(Get-Content -LiteralPath $Path)
        $source = $Path
    }

    $valid = '^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$'
    $clean = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $Name) {
        $n = ("$raw" -split '#')[0].Trim()
        if (-not $n) { continue }
        if (-not $KeepDomain) { $n = ($n -split '\.')[0] }
        if ($n -notmatch $valid) {
            Write-VmmLog "Skipped '$n' from $source - only letters, digits, '-', '_' and '.' are allowed." -Level Warn
            continue
        }
        switch ($Case) {
            'Upper' { $n = $n.ToUpper() }
            'Lower' { $n = $n.ToLower() }
        }
        if (-not ($clean -contains $n)) { $clean.Add($n) }
    }

    if ($clean.Count -eq 0) {
        throw (New-VmmErrorRecord -Activity 'No server names to process.' -Target $source `
            -Cause 'The list is empty, or every line is blank, a comment or invalid.' `
            -Fix 'Add one name per line, or pass names on the command line.' `
            -Category InvalidData -ErrorId 'VmmListEmpty')
    }
    Write-VmmLog "$($clean.Count) name(s) from $source" -Level Muted
    $clean.ToArray()
}
