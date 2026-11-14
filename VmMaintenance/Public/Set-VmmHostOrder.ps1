function Set-VmmHostOrder {
    <#
    .SYNOPSIS
        Records an order to work on a host the policy would otherwise skip (client OS such as Windows 10/11).
    .DESCRIPTION
        Policy: client operating systems are not touched unless there are orders. This records who ordered it
        and why (shown in the daily report). -Clear removes the order again.
    .EXAMPLE
        Set-VmmHostOrder -HostName pc01 -Reason 'Ticket 12345, approved by <manager> on 2026-11-20'
    .EXAMPLE
        vmm order -HostName pc01 -Clear
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName, [string]$Reason, [switch]$Clear)
    $store = Read-VmmStore
    $rec = Get-VmmHostRecord -Store $store -Name $HostName
    if ($Clear) {
        $rec | Add-Member -NotePropertyName Order -NotePropertyValue $null -Force
        Set-VmmStepState -Record $rec -Step 'Order' -Status 'Cleared' -Note 'order removed'
        Save-VmmStore -Store $store
        Write-VmmLog "$($rec.Name): order cleared - policy applies again." -Level Success
        return
    }
    if (-not $Reason -or $Reason.Trim().Length -lt 10) {
        throw (New-VmmErrorRecord -Activity 'An order needs a reason of at least 10 characters.' -Fix "-Reason 'ticket/approval and who gave it'" -Category InvalidArgument -ErrorId 'VmmOrderReason')
    }
    $r = Protect-VmmLogText $Reason.Trim()
    $rec | Add-Member -NotePropertyName Order -NotePropertyValue ([pscustomobject]@{ At = (Get-Date).ToUniversalTime().ToString('o'); Reason = $r; Cleared = $false }) -Force
    Set-VmmStepState -Record $rec -Step 'Order' -Status 'Ordered' -Note $r
    Save-VmmStore -Store $store
    Write-VmmLog "$($rec.Name): order recorded - host is in scope despite the policy. Reason: $r" -Level Warn
}
