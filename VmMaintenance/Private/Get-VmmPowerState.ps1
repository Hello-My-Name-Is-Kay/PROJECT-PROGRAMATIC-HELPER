function Get-VmmPowerState {
    # Live power state: running, deallocated, stopped, starting, stopping, deallocating.
    [CmdletBinding()]
    param(
        [string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$VMName
    )
    if ($SubscriptionId) { Set-VmmSubscription -Subscription $SubscriptionId }
    $s = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Status -ErrorAction Stop
    ($s.Statuses | Where-Object Code -like 'PowerState/*' | Select-Object -First 1).Code -replace '^PowerState/', ''
}
