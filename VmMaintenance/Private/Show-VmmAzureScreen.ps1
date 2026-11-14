function Show-VmmAzureScreen {
    # Azure sign-in without the stuck tenant/subscription picker.
    [CmdletBinding()]
    param()
    $items = @(
        @{ K = 'L'; T = 'Sign in with configured tenant + subscription (picker turned off)' }
        @{ K = 'P'; T = 'Sign in and PICK tenant/subscription from a numbered list, save ids to config' }
        @{ K = 'D'; T = 'Sign in with DEVICE CODE (no browser pop-up; open microsoft.com/devicelogin in Firefox)' }
        @{ K = 'S'; T = 'Show current Azure context' }
        @{ K = 'X'; T = 'Sign out (Disconnect-AzAccount)' }
    )
    $sel = 0
    while ($true) {
        $r = Invoke-VmmListView -Title 'Azure' -Rows @($items | ForEach-Object { @{ Text = "[$($_.K)] $($_.T)" } }) -Selected $sel -Hotkeys @($items | ForEach-Object { $_.K }) -Help 'Letter or Enter | Esc back'
        $sel = $r.Index
        $k = if ($r.Action -eq 'Enter') { $items[$r.Index].K } else { $r.Action }
        switch ($k) {
            'Esc' { return }
            'L' { [void](Invoke-VmmTuiAction -Title 'Azure sign-in' -Action { Assert-VmmModule -Name Az.Accounts; Connect-VmmAzure -TenantId (Get-VmmSetting 'Azure.TenantId') -Subscription (Get-VmmSetting 'Azure.Subscription') -Force; Get-AzContext | Format-List Name, Subscription, Tenant }) }
            'P' { [void](Invoke-VmmTuiAction -Title 'Pick subscription' -Action { Select-VmmAzureContext -Save }) }
            'D' { [void](Invoke-VmmTuiAction -Title 'Device code sign-in' -Action { Select-VmmAzureContext -DeviceCode -Save }) }
            'S' { [void](Invoke-VmmTuiAction -Title 'Azure context' -Action { if (Get-Module -ListAvailable Az.Accounts) { Import-Module Az.Accounts; Get-AzContext | Format-List Name, Account, Subscription, Tenant } else { Write-VmmLog 'Az.Accounts not installed.' -Level Warn } }) }
            'X' { [void](Invoke-VmmTuiAction -Title 'Sign out' -Action { Disconnect-AzAccount | Out-Null; Write-VmmLog 'Signed out.' -Level Success }) }
        }
        $script:VmmProgCache = $null
    }
}
