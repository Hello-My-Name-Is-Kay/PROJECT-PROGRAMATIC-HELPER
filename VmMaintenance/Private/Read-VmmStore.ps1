function Read-VmmStore {
    # Loads and decrypts the fleet store. Returns an empty store when none exists yet.
    [CmdletBinding()]
    param()
    $file = Join-Path (Get-VmmPath -Name Data) 'fleet.vmm'
    if (-not (Test-Path -LiteralPath $file)) {
        return [pscustomobject]@{ Version = 1; Updated = $null; Hosts = @(); Overrides = @() }
    }
    $plain = Unprotect-VmmBytes -Bytes ([System.IO.File]::ReadAllBytes($file)) -Source $file
    try {
        $json  = [Text.Encoding]::UTF8.GetString($plain)
        $store = $json | ConvertFrom-Json
    } catch {
        throw (New-VmmErrorRecord -Activity 'Fleet store decrypted but is not valid JSON.' -Target $file -Exception $_.Exception `
            -Fix 'Restore a backup (fleet.vmm.bak next to it) or delete the file and re-import your host list.' -Category InvalidData)
    } finally { [Array]::Clear($plain, 0, $plain.Length) }

    # Normalise collections (JSON drops empty/single arrays differently between 5.1 and 7)
    $store.Hosts = @($store.Hosts | Where-Object { $_ })
    if (-not $store.PSObject.Properties['Overrides']) { $store | Add-Member -NotePropertyName Overrides -NotePropertyValue @() }
    $store.Overrides = @($store.Overrides | Where-Object { $_ })
    foreach ($h in $store.Hosts) {
        $h.Blockers = @($h.Blockers | Where-Object { $_ })
        $h.History  = @($h.History  | Where-Object { $_ })
        if (-not $h.Steps) { $h.Steps = [pscustomobject]@{} }
        Update-VmmStepName -Record $h
    }
    $store
}
