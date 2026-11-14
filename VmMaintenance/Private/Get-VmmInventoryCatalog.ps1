function Get-VmmInventoryCatalog {
    # Inventory columns from Resources\InventoryFields.psd1 (order = CSV column order), cached per session.
    # Each field: Key, Header, Source (Auto | Derived | Manual), Required, Help, Services (agents only).
    [CmdletBinding()]
    param([switch]$Refresh)
    if ($script:VmmInventoryCatalog -and -not $Refresh) { return $script:VmmInventoryCatalog }
    $path = Join-Path $script:ModuleRoot 'Resources\InventoryFields.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw (New-VmmErrorRecord -Activity 'Inventory field list missing.' -Target $path -Fix 'Reinstall (Install.ps1) or restore Resources\InventoryFields.psd1 from the repository.' -Category ObjectNotFound -ErrorId 'VmmInventoryCatalog')
    }
    try { $data = Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop }
    catch { throw (New-VmmErrorRecord -Activity 'Inventory field list does not load.' -Target $path -Exception $_.Exception -Fix 'Fix the syntax error shown, or restore the file from the repository.' -Category InvalidData -ErrorId 'VmmInventoryCatalog') }
    $script:VmmInventoryCatalog = @(foreach ($f in $data.Fields) {
        [pscustomobject]@{
            Key = "$($f.Key)"; Header = "$($f.Header)"; Source = $(if ($f.Source -in 'Auto', 'Derived', 'Manual') { $f.Source } else { 'Manual' })
            Required = $(if ($f.ContainsKey('Required')) { [bool]$f.Required } else { $true }); Help = "$($f.Help)"; Services = @($f.Services | Where-Object { $_ })
        }
    })
    $script:VmmInventoryCatalog
}
