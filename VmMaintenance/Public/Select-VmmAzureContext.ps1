function Select-VmmAzureContext {
    <#
    .SYNOPSIS
        Signs in to Azure and lets you pick tenant + subscription from a numbered list (no Az picker),
        then optionally saves the choice (ids only) to your local config.
    .DESCRIPTION
        Fix for Connect-AzAccount stopping at "Select a tenant and subscription:". Also shows the
        persistent alternative: Update-AzConfig -DefaultSubscriptionForLogin <id>.
    .EXAMPLE
        Select-VmmAzureContext -Save
    #>
    [CmdletBinding()]
    param([switch]$Save, [switch]$DeviceCode)
    Assert-VmmModule -Name 'Az.Accounts'
    if ($DeviceCode) { $script:VmmForceDeviceCode = $true }
    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        if (Get-Command Update-AzConfig -ErrorAction SilentlyContinue) { try { Update-AzConfig -LoginExperienceV2 Off -Scope Process | Out-Null } catch { } }
        $p = @{ ErrorAction = 'Stop' }
        if ($DeviceCode -or [bool](Get-VmmSetting 'Azure.UseDeviceAuthentication' -Default $false)) { $p.UseDeviceAuthentication = $true }
        $t = Get-VmmSetting 'Azure.TenantId'
        if ($t) { $p.Tenant = $t }
        Suspend-VmmConsoleInput
        try { Connect-AzAccount @p | Out-Null } finally { Resume-VmmConsoleInput }
    }
    try { $subs = @(Get-AzSubscription -ErrorAction Stop | Where-Object State -eq 'Enabled' | Sort-Object Name) }
    catch { throw (New-VmmErrorRecord -Activity 'Could not list subscriptions.' -Exception $_.Exception -Category ReadError) }
    if (-not $subs) {
        throw (New-VmmErrorRecord -Activity 'Your account sees no enabled subscription.' -Cause 'No role assigned on any subscription in this tenant.' `
            -Fix 'Raise a blocker report asking for Reader (or higher) on the subscription holding the VMs.' -Category PermissionDenied)
    }
    for ($i = 0; $i -lt $subs.Count; $i++) { Write-VmmLog ('[{0}] {1}  ({2})' -f ($i + 1), $subs[$i].Name, $subs[$i].Id) }
    do { $n = Read-VmmPrompt "Subscription number (1-$($subs.Count))" } until ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $subs.Count)
    $sel = $subs[[int]$n - 1]
    Set-AzContext -Subscription $sel.Id -Tenant $sel.TenantId -ErrorAction Stop | Out-Null
    Write-VmmLog "Azure context: $($sel.Name)" -Level Success
    if ($Save) {
        Set-VmmSetting -Name 'Azure.TenantId' -Value $sel.TenantId
        Set-VmmSetting -Name 'Azure.Subscription' -Value $sel.Id
        Write-VmmLog 'Saved to your local config (ids only - no credentials).' -Level Muted
    }
    Write-VmmLog "To make this the default for every Connect-AzAccount: Update-AzConfig -DefaultSubscriptionForLogin $($sel.Id)" -Level Muted
}
