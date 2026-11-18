function Add-VmmKnowledgeEntry {
    # Records a known fix (what happened, why, the fix steps) so the next technician sees it when the same step
    # fails. Text is made shareable first (host names, IPs, ids, secrets removed). Same action + same symptom =
    # the existing entry is updated instead of a second one. Returns the entry.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$WorkflowStore,
        [Parameter(Mandatory)][string]$ActionId,
        [Parameter(Mandatory)][string]$Symptom,
        [string]$Cause = '',
        [string[]]$Fix = @(),
        [string[]]$Commands = @(),
        [string[]]$Names = @()
    )
    $clean = { param($s) ConvertTo-VmmShareableText -Text "$s".Trim() -Names $Names }
    $sym = & $clean $Symptom
    if (-not $sym) { throw (New-VmmErrorRecord -Activity 'A known fix needs a symptom (what happened).' -Fix 'Type or paste the error text.' -Category InvalidArgument -ErrorId 'VmmKbEmpty') }
    $at = (Get-Date).ToUniversalTime().ToString('o')
    $fx = @($Fix | ForEach-Object { & $clean $_ } | Where-Object { $_ })
    $cm = @($Commands | ForEach-Object { & $clean $_ } | Where-Object { $_ })
    $e = $WorkflowStore.Kb | Where-Object { $_.ActionId -eq $ActionId -and $_.Symptom -eq $sym } | Select-Object -First 1
    if ($e) {
        if ($Cause) { $e.Cause = & $clean $Cause }
        if ($fx) { $e.Fix = $fx }
        if ($cm) { $e.Commands = $cm }
        $e.Updated = $at
        return $e
    }
    $e = [pscustomobject]@{ Id = (New-VmmId -Prefix kb); ActionId = $ActionId; Symptom = $sym; Cause = (& $clean $Cause); Fix = $fx; Commands = $cm
                            Helped = 0; NotHelped = 0; Created = $at; Updated = $at }
    $WorkflowStore.Kb = @($WorkflowStore.Kb) + $e
    $e
}
