function Select-VmmFromList {
    # Picker dialogue: a list screen of -Items (each shown by -Label), Enter picks, Esc = $null.
    # -Groups (scriptblock) puts a section title above each group.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title, [AllowEmptyCollection()][object[]]$Items = @(), [Parameter(Mandatory)][scriptblock]$Label,
          [scriptblock]$Group, [string]$Help = 'Enter pick | Esc cancel', [string]$Status = '')
    if (-not $Items.Count) { return $null }
    $rows = @(); $map = @()
    $last = $null
    foreach ($it in $Items) {
        if ($Group) { $g = "$(& $Group $it)"; if ($g -ne $last) { $rows += @{ Text = $g.ToUpper(); Header = $true }; $map += $null; $last = $g } }
        $rows += @{ Text = "$(& $Label $it)" }; $map += , $it
    }
    $r = Invoke-VmmListView -Title $Title -Rows $rows -Help $Help -Status $Status
    if ($r.Action -ne 'Enter') { return $null }
    $map[$r.Index]
}
