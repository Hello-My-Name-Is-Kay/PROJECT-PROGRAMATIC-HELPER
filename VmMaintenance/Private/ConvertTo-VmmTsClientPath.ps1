function ConvertTo-VmmTsClientPath {
    # A laptop path as the host sees it inside an RDP session with that drive shared:
    # C:\Users\me\outbox\a.iso -> \\tsclient\C\Users\me\outbox\a.iso. UNC or relative paths -> $null.
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path)
    if ($Path -match '^([A-Za-z]):\\(.*)$') { return ('\\tsclient\{0}\{1}' -f $Matches[1].ToUpper(), $Matches[2]) }
    $null
}
