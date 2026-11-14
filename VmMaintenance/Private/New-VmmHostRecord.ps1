function New-VmmHostRecord {
    # One machine in the fleet store. Only machine facts are kept - never usernames or passwords.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Source = 'manual')
    [pscustomobject]@{
        Name     = $Name.ToUpper()
        AddedAt  = (Get-Date).ToUniversalTime().ToString('o')
        Source   = $Source
        Platform = $null
        IPv4     = $null
        Fqdn     = $null          # from an import file; the fleet check connects by it when set
        Azure    = $null          # SubscriptionId, ResourceGroup, VMName, PowerState
        Check    = $null          # last fleet check result
        Baseline = $null          # OS/build/SQL captured at the first successful Precheck
        Health   = 'Unknown'
        Steps    = [pscustomobject]@{}
        Blockers = @()
        History  = @()
        Hold     = $false         # true = left out of the work queue
    }
}
