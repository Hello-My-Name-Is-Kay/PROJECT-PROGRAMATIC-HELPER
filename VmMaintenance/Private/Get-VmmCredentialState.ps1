function Get-VmmCredentialState {
    # Header text: which session credentials are set. Shows nothing about the account itself.
    [CmdletBinding()]
    param()
    $w = if ((Get-VmmSetting 'Credentials.WindowsMode' -Default 'Prompt') -eq 'CurrentUser') { 'current user' }
         elseif ($script:VmmCredentials -and $script:VmmCredentials.ContainsKey('Windows')) { 'set' } else { 'not set' }
    $s = if ($script:VmmCredentials -and $script:VmmCredentials.ContainsKey('Sql')) { 'set' } else { 'not set' }
    "Windows cred: $w | SQL cred: $s"
}
