function Set-VmmSubscription {
    # Switches subscription only when needed (a batch can span subscriptions). Accepts id or name.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Subscription)

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($ctx -and $ctx.Subscription -and
        ($ctx.Subscription.Id -eq $Subscription -or $ctx.Subscription.Name -eq $Subscription)) { return }

    $p = @{ Subscription = $Subscription; ErrorAction = 'Stop' }
    if ($script:VmmTenantId) { $p.Tenant = $script:VmmTenantId }
    try { Set-AzContext @p | Out-Null }
    catch {
        throw (New-VmmErrorRecord -Activity 'Could not switch Azure subscription.' -Target $Subscription -Exception $_.Exception `
            -Cause 'The subscription id/name is wrong, disabled, or your account has no role on it.' `
            -Fix 'List what you can see with: Get-AzSubscription | Format-Table Name, Id, State' `
            -Category ObjectNotFound -ErrorId 'VmmAzSubscription')
    }
}
