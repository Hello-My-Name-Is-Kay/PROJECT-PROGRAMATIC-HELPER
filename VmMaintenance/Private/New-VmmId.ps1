function New-VmmId {
    # Short random id for user workflow items: <prefix>-<10 hex>. Never derived from host or user names.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('a', 'wf', 'kb')][string]$Prefix)
    "$Prefix-" + [guid]::NewGuid().ToString('N').Substring(0, 10)
}
