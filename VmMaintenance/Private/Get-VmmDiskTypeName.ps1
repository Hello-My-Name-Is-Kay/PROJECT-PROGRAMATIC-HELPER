function Get-VmmDiskTypeName {
    # Friendly names for Azure disk SKUs.
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Sku)
    switch ($Sku) {
        'Premium_LRS'     { 'Premium SSD (LRS)'; break }
        'Premium_ZRS'     { 'Premium SSD (ZRS)'; break }
        'PremiumV2_LRS'   { 'Premium SSD v2'; break }
        'StandardSSD_LRS' { 'Standard SSD (LRS)'; break }
        'StandardSSD_ZRS' { 'Standard SSD (ZRS)'; break }
        'Standard_LRS'    { 'Standard HDD'; break }
        'UltraSSD_LRS'    { 'Ultra Disk'; break }
        ''                { 'Unknown'; break }
        default           { $Sku }
    }
}
