function Get-VmmAccessRequirement {
    # Maps an error to the access you would ask your manager for. $null = not an access problem.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [string]$Target)
    $map = @(
        @{ P = 'AuthorizationFailed|does not have authorization'; Need = "Azure RBAC on the VM's resource group: Virtual Machine Contributor (start/stop/run command) and Disk Snapshot Contributor (snapshots)"; Kind = 'Azure role' }
        @{ P = 'ScopeLocked'; Need = 'Removal (or temporary exception) of the resource lock on the resource group, by its owner'; Kind = 'Azure lock' }
        @{ P = 'AADSTS|interaction_required|Conditional Access'; Need = 'Entra ID sign-in allowed for Azure PowerShell from this laptop (Conditional Access / MFA policy)'; Kind = 'Sign-in policy' }
        @{ P = 'SubscriptionNotFound|No subscription found|valid tenant or a valid subscription'; Need = 'Reader (or higher) on the subscription that holds the VM'; Kind = 'Azure subscription access' }
        @{ P = 'Access is denied|0x80070005|UnauthorizedAccess'; Need = "Membership of the local Administrators group on $Target (or an admin account to use for this session)"; Kind = 'Host admin' }
        @{ P = 'Login failed for user|Cannot open database'; Need = 'SQL login with db_datareader on the Lansweeper database'; Kind = 'SQL access' }
        @{ P = 'RPC server is unavailable|0x800706BA|TCP 135'; Need = "Firewall rule 'Windows Management Instrumentation (DCOM-In)' enabled on $Target from this laptop's network"; Kind = 'Firewall' }
        @{ P = 'network path was not found|network name|BadNetPath|0x80070035'; Need = "SMB (TCP 445) from this laptop to $Target and the C`$ admin share enabled"; Kind = 'Firewall / admin share' }
        @{ P = 'staging share|SourceShare'; Need = 'Read access to the staging network share'; Kind = 'Share access' }
    )
    foreach ($m in $map) {
        if ($Message -match $m.P) { return [pscustomobject]@{ Kind = $m.Kind; Needed = $m.Need } }
    }
    $null
}
