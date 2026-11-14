function Get-VmmUpgradeImage {
    # Latest version of the upgrade-media marketplace image in a region. -Cache avoids repeat lookups.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Offer,
        [Parameter(Mandatory)][string]$Sku,
        [hashtable]$Cache = @{}
    )
    if ($Cache.ContainsKey($Location)) { return $Cache[$Location] }
    try {
        $ver = (Get-AzVMImage -PublisherName $Publisher -Location $Location -Offer $Offer -Skus $Sku -ErrorAction Stop |
                Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1).Version
        if (-not $ver) { throw "No image versions returned for $Publisher/$Offer/$Sku in $Location." }
        $img = Get-AzVMImage -PublisherName $Publisher -Location $Location -Offer $Offer -Skus $Sku -Version $ver -ErrorAction Stop
    } catch {
        throw (New-VmmErrorRecord -Activity 'Upgrade media image not found.' -Target "$Publisher/$Offer/$Sku in $Location" -Exception $_.Exception `
            -Cause 'The SKU name is wrong, or the image is not offered in this region.' `
            -Fix "List valid SKUs: Get-AzVMImageSku -Location $Location -PublisherName $Publisher -Offer $Offer  - then set UpgradeMedia.Sku." `
            -Category ObjectNotFound -ErrorId 'VmmImageNotFound')
    }
    $Cache[$Location] = $img
    $img
}
