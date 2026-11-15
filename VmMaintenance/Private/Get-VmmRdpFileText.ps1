function Get-VmmRdpFileText {
    # Text of a one-off .rdp file for mstsc. No user name or password goes in it: mstsc asks.
    # -Drive: local drive letters to share with the host (shown there as \\tsclient\<letter>), only what
    # the handoff needs; none = no drive redirection. Clipboard redirection stays on so the host script and
    # its report can be pasted both ways.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Address, [string[]]$Drive = @())
    if ($Address -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-]*(:\d{1,5})?$') {
        throw (New-VmmErrorRecord -Activity "'$Address' is not a host name, FQDN or IP for RDP." -Category InvalidArgument -ErrorId 'VmmRdpAddress')
    }
    $letters = @($Drive | Where-Object { $_ } | ForEach-Object { "$_".Substring(0, 1).ToUpper() } | Where-Object { $_ -match '^[A-Z]$' } | Select-Object -Unique)
    $redirect = (@($letters | ForEach-Object { "${_}:\" }) -join ';')
    if ($redirect) { $redirect += ';' }
    @(
        "full address:s:$Address"
        'prompt for credentials:i:1'
        'promptcredentialonce:i:1'
        'authentication level:i:2'
        'screen mode id:i:1'
        'desktopwidth:i:1600'
        'desktopheight:i:900'
        'smart sizing:i:1'
        'redirectclipboard:i:1'
        "drivestoredirect:s:$redirect"
        'redirectprinters:i:0'
        'redirectcomports:i:0'
        'audiomode:i:2'
    ) -join "`r`n"
}
