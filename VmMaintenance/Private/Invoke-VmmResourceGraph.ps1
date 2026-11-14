function Invoke-VmmResourceGraph {
    # Resource Graph query across the whole tenant. Returns rows (handles old and new Az.ResourceGraph).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$Activity = 'Resource Graph query'
    )
    try { $r = Search-AzGraph -Query $Query -First 1000 -UseTenantScope -ErrorAction Stop }
    catch {
        throw (New-VmmErrorRecord -Activity "$Activity failed." -Exception $_.Exception `
            -Cause 'Az.ResourceGraph is too old (no -UseTenantScope), the sign-in expired, or you have no Reader role in the tenant.' `
            -Fix 'Update-Module Az.ResourceGraph, then Connect-AzAccount -TenantId <tenant> and re-run.' `
            -Category ReadError -ErrorId 'VmmResourceGraph')
    }
    # Newer Az.ResourceGraph returns a response object with .Data; older returns rows directly
    if ($r -and $r.PSObject.Properties['Data']) { return @($r.Data) }
    @($r)
}
