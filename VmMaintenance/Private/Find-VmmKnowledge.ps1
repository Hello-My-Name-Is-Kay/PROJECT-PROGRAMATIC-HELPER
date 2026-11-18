function Find-VmmKnowledge {
    # Known fixes for a failed step, best first: entries for this action (or for every action, ActionId *) whose
    # symptom shares words with what happened (common words such as 'the', 'not', 'error' do not count). Score = shared words (3+ letters) x 2, +3 for this exact action,
    # + Helped - NotHelped. With no text, every entry for the action comes back (most helpful first).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog, [string]$ActionId, [string]$Text = '')
    $stop = 'the', 'and', 'not', 'for', 'this', 'that', 'with', 'you', 'are', 'was', 'has', 'have', 'from', 'does', 'did', 'can', 'cannot', 'any', 'all', 'but', 'its', 'out', 'into', 'when', 'then', 'there', 'will', 'error', 'failed'
    $words = { param($s) @(([regex]::Matches("$s".ToLower(), '[a-z0-9]{3,}') | ForEach-Object { $_.Value } | Where-Object { $stop -notcontains $_ }) | Select-Object -Unique) }
    $tw = & $words $Text
    $out = foreach ($k in $Catalog.Kb) {
        $mine = $ActionId -and $k.ActionId -eq $ActionId
        if (-not $mine -and $k.ActionId -ne '*' -and $ActionId) { continue }
        $kw = & $words ("$($k.Symptom) $($k.Cause)")
        $shared = @($tw | Where-Object { $kw -contains $_ }).Count
        if ($tw.Count -and -not $shared -and -not $mine) { continue }   # generic fix that does not match the error
        $score = 2 * $shared + $(if ($mine) { 3 } else { 0 }) + [int]$k.Helped - [int]$k.NotHelped
        [pscustomobject]@{ Entry = $k; Score = $score; Shared = $shared }
    }
    @($out | Sort-Object @{ e = { $_.Score }; Descending = $true }, @{ e = { $_.Entry.Symptom } })
}
