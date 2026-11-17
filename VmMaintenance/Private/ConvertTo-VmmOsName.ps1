function ConvertTo-VmmOsName {
    # Win32_OperatingSystem.Caption without trademark signs and double spaces. Server 2008 (not R2) and Vista report
    # "Microsoft(R) Windows Server(R) 2008 ..." with the (R)/(TM) characters, which '*Server 2008*' never matches.
    # Same rule as ConvertTo-OsName in the Extractor (Resources\VmmHostAgent.ps1).
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Caption)
    $t = "$Caption" -replace '[\u00AE\u2122]', '' -replace '\((R|TM)\)', ''
    ($t -replace '\s+', ' ').Trim()
}
