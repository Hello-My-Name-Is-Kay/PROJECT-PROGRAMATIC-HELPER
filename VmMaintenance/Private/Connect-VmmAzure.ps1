function Connect-VmmAzure {
    # Signs in only when there is no session, or the session is for another tenant.
    # Avoids the interactive "Select a tenant and subscription" picker of newer Az.Accounts by
    # (1) passing -Tenant and -Subscription explicitly and (2) turning the picker off for this
    # process only (Azure.DisableLoginPicker, default $true). Azure.UseDeviceAuthentication = $true
    # uses a device code (open https://microsoft.com/devicelogin in Firefox) instead of a browser pop-up.
    [CmdletBinding()]
    param([string]$TenantId, [string]$Subscription, [switch]$Force)

    $script:VmmTenantId = $TenantId
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    $needLogin = $Force -or (-not $ctx) -or (-not $ctx.Account) -or ($TenantId -and $ctx.Tenant.Id -ne $TenantId)

    if ($needLogin) {
        if ([bool](Get-VmmSetting 'Azure.DisableLoginPicker' -Default $true) -and (Get-Command Update-AzConfig -ErrorAction SilentlyContinue)) {
            try { Update-AzConfig -LoginExperienceV2 Off -Scope Process -ErrorAction Stop | Out-Null } catch { }   # older Az has no such setting
        }
        $p = @{ ErrorAction = 'Stop' }
        if ($TenantId)     { $p.Tenant       = $TenantId }
        if ($Subscription) { $p.Subscription = $Subscription }
        if ([bool](Get-VmmSetting 'Azure.UseDeviceAuthentication' -Default $false)) {
            $p.UseDeviceAuthentication = $true
            Write-VmmLog 'Device code sign-in: open https://microsoft.com/devicelogin in your browser and enter the code shown below.' -Level Info
        } else {
            Write-VmmLog 'Signing in to Azure (browser window)...' -Level Info
        }
        Suspend-VmmConsoleInput
        try { Connect-AzAccount @p | Out-Null }
        catch {
            throw (New-VmmErrorRecord -Activity 'Azure sign-in failed.' -Target "tenant $TenantId" -Exception $_.Exception `
                -Cause 'Wrong tenant id, sign-in window closed, MFA not completed, or no access to that tenant/subscription.' `
                -Fix 'Check Azure.TenantId / Azure.Subscription (Settings, or vmm azure -Save). No browser? Set Azure.UseDeviceAuthentication = $true.' `
                -Category AuthenticationError -ErrorId 'VmmAzLogin')
        } finally { Resume-VmmConsoleInput }
    }
    if ($Subscription) { Set-VmmSubscription -Subscription $Subscription }

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or -not $ctx.Subscription) {
        throw (New-VmmErrorRecord -Activity 'Signed in, but no subscription is selected.' -Target "tenant $TenantId" `
            -Cause 'The tenant/subscription picker was skipped or left empty, and Azure.Subscription is not set.' `
            -Fix 'Choose one: vmm azure -Save   (or Settings > Azure), or set Azure.Subscription in your config.' `
            -Category InvalidOperation -ErrorId 'VmmAzNoSubscription')
    }
}
