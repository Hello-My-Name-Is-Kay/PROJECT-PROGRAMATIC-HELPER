function New-VmmHelpTextIssue {
    <#
    .SYNOPSIS
        Asks for a change to a help text (inventory column help windows, or any other help screen) by
        opening a GitHub issue on the vmm repository, with the current text and your proposal.
    .DESCRIPTION
        Uses the same path as vmm issue: GitHub CLI sign-in, masking of secrets/IPs/host names, preview and
        confirmation before anything is sent. Inventory help lives in Resources\InventoryFields.psd1, so the
        change is one edit in the repository and reaches every user with vmm update.
    .EXAMPLE
        New-VmmHelpTextIssue -Field 'Server Owner'
    .EXAMPLE
        vmm helptext -Screen 'Staging gate' -Proposed 'Explain where the ISO folder is'
    #>
    [CmdletBinding()]
    param([string]$Field, [string]$Screen, [string]$Proposed)
    if (-not $Field -and -not $Screen) { $Field = Read-VmmPrompt 'Inventory column (header) or leave empty for another screen' }
    $current = ''; $name = $Screen; $where = 'the help screen named in the title'
    if ($Field) {
        $f = @(Get-VmmInventoryCatalog | Where-Object { $_.Key -ieq $Field.Trim() -or $_.Header -ieq $Field.Trim() }) | Select-Object -First 1
        if (-not $f) { throw (New-VmmErrorRecord -Activity "Unknown inventory column '$Field'." -Cause ('Columns: ' + ((Get-VmmInventoryCatalog | ForEach-Object Header) -join ', ')) -Category InvalidArgument -ErrorId 'VmmInventoryField') }
        $name = "inventory column '$($f.Header)'"; $current = $f.Help; $where = "VmMaintenance/Resources/InventoryFields.psd1, Key = $($f.Key)"
        Write-VmmLog "Current help for $($f.Header):" -Level Info; Write-VmmLog "  $current" -Level Muted
    }
    if (-not $name) { $name = Read-VmmPrompt 'Which screen or help window' }
    if (-not $name) { return }
    if (-not $Proposed) { $Proposed = Read-VmmPrompt 'Your proposed text (or what is unclear)' }
    if (-not $Proposed) { Write-VmmLog 'Nothing proposed; no issue opened.' -Level Muted; return }
    $body = "Help text change request`n`nWhere: $where`n`nCurrent text:`n> $(if ($current) { $current } else { '(see the screen)' })`n`nProposed text / what is unclear:`n> $Proposed"
    New-VmmGitHubIssue -Title "Help text: $name" -Body $body
}
