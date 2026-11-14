function Clear-VmmSessionCredentialStore {
    # Disposes every SecureString held for this session (zeroes the protected buffer).
    [CmdletBinding()]
    param()
    if ($script:VmmCredentials) {
        foreach ($k in @($script:VmmCredentials.Keys)) {
            try { $script:VmmCredentials[$k].Password.Dispose() } catch { }
            $script:VmmCredentials.Remove($k)
        }
    }
    $script:VmmCredentials = @{}
    [GC]::Collect()
}
