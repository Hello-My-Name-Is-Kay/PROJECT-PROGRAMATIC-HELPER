function Get-VmmErrorHint {
    # Maps known Azure / SQL / WMI / file error text to a likely cause and a concrete fix.
    # Returns $null when nothing matches. Most specific patterns first.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    $rules = @(
        # --- Azure
        @{ P = 'ScopeLocked'
           C = 'A resource lock (CanNotDelete or ReadOnly) sits on the resource, its resource group or the subscription.'
           F = 'List locks with Get-AzResourceLock -ResourceGroupName <rg>, then remove the lock or ask its owner.' }
        @{ P = 'AuthorizationFailed|does not have authorization|LinkedAuthorizationFailed'
           C = 'Your account lacks the Azure role needed for this action on this scope.'
           F = 'Ask for Virtual Machine Contributor (start/stop/run command) and Disk Snapshot Contributor or Contributor on the resource group. Check with Get-AzRoleAssignment -SignInName <you> -ResourceGroupName <rg>.' }
        @{ P = 'Run Connect-AzAccount|Connect-AzAccount to login|AADSTS\d+|token.*expired|interaction_required|No subscription found in the context'
           C = 'Azure sign-in is missing or expired, or MFA / Conditional Access wants a fresh interactive sign-in.'
           F = 'Run Connect-AzAccount -TenantId <tenant>, then re-run.' }
        @{ P = 'SubscriptionNotFound|Please provide a valid tenant or a valid subscription'
           C = 'The subscription id or name is wrong, disabled, or not visible to your account.'
           F = 'Get-AzSubscription | Format-Table Name, Id, State  - then fix Azure.Subscription in your config.' }
        @{ P = 'ResourceGroupNotFound'
           C = 'The resource group name is wrong, or it lives in another subscription.'
           F = 'Check Azure.ResourceGroup in your config and the active subscription (Get-AzContext).' }
        @{ P = 'QuotaExceeded|exceeding approved'
           C = 'The subscription quota for this SKU is used up in this region.'
           F = 'Request a quota increase (portal: Subscriptions > Usage + quotas) or use another SKU.' }
        @{ P = 'resiz|shrink|DiskSizeGB'
           C = 'Azure resizes an OS disk only while the VM is deallocated, and never to a smaller size.'
           F = 'Check the VM is deallocated (Get-AzVM -Status) and the new size is larger than the current one.' }
        @{ P = 'VMAgentStatusCommunicationError|VM agent|Run command extension|RunCommand'
           C = 'The VM agent is not reporting Ready, so Run Command cannot execute inside the VM.'
           F = 'Check the WindowsAzureGuestAgent service inside the VM, or extend C: by hand in Disk Management.' }
        @{ P = 'ResourceNotFound|NotFound|was not found|could not be found'
           C = 'The name is wrong, the resource was deleted, or it is in another resource group / subscription.'
           F = 'Check the spelling and that the right subscription is active (Get-AzContext).' }
        @{ P = 'Conflict|OperationNotAllowed|another operation|in progress|Retryable'
           C = 'Another operation is running on the VM or disk (backup, extension, start/stop by someone else).'
           F = 'Wait a few minutes and re-run. The Activity log of the resource shows what is running.' }
        # --- SQL Server
        @{ P = 'Login failed for user'
           C = 'Wrong SQL login or password, the login is disabled, or the server accepts Windows authentication only.'
           F = 'Test the same login in SSMS with SQL Server Authentication. If SSMS fails too, ask the DBA to enable the login or mixed mode.' }
        @{ P = 'Cannot open database'
           C = 'The database name is wrong, or the login has no user in that database.'
           F = 'Check Lansweeper.Database in your config; ask the DBA for db_datareader on it.' }
        @{ P = 'certificate chain|SSL Provider|not trusted'
           C = 'The SQL Server TLS certificate is not trusted by this machine.'
           F = 'Ask the DBA for a trusted certificate, or set Lansweeper.TrustServerCertificate = $true in your config.' }
        @{ P = 'network-related or instance-specific|was not found or was not accessible|error: 26|error: 40|Named Pipes Provider|TCP Provider'
           C = 'SQL instance unreachable: wrong host\instance name, SQL Browser stopped (named instances), or a firewall blocks TCP 1433 / UDP 1434.'
           F = 'Test-NetConnection <sqlhost> -Port 1433, then check Lansweeper.SqlInstance in your config.' }
        @{ P = 'Invalid object name|Invalid column name'
           C = 'The database is not a Lansweeper database, or its schema differs (Lansweeper version).'
           F = 'Check Lansweeper.Database points at the Lansweeper database (usually lansweeperdb).' }
        # --- WMI / DCOM / DNS
        @{ P = 'RPC server is unavailable|0x800706BA'
           C = 'Host is down, the name is wrong, or a firewall blocks DCOM/RPC (TCP 135 plus dynamic ports).'
           F = 'Test-Connection <host>; enable the firewall rule "Windows Management Instrumentation (DCOM-In)" on the target.' }
        @{ P = 'Access is denied|0x80070005|UnauthorizedAccess'
           C = 'Your account is not a local administrator on the target, or UAC remote restrictions apply.'
           F = 'Run as an account in the target''s local Administrators group, or pass -Credential.' }
        @{ P = 'No such host is known|DNS name does not exist|could not be resolved|0x80072EE7'
           C = 'The name does not resolve in DNS from this machine.'
           F = 'Check the name, try the FQDN, or run from a machine on the right domain / VPN.' }
        # --- Files
        @{ P = 'being used by another process'
           C = 'The file is open in another program (usually Excel).'
           F = 'Close the file and re-run, or write to a different path.' }
        @{ P = 'Could not find a part of the path|Cannot find path|DirectoryNotFound'
           C = 'The folder or file path does not exist.'
           F = 'Fix the path in your config (Paths.WorkDir / ServerLists.*) or the parameter you passed.' }
    )

    foreach ($r in $rules) {
        if ($Message -match $r.P) { return [pscustomobject]@{ Cause = $r.C; Fix = $r.F } }
    }
    $null
}
