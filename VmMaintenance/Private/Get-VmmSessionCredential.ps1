function Get-VmmSessionCredential {
    # Asks once per session and keeps the credential ONLY in memory (PSCredential = SecureString,
    # DPAPI-encrypted in memory on Windows). Never written, logged or exported.
    # Purpose 'Windows' = admin on target hosts (CIM, C$ share); 'Sql' = Lansweeper SQL login.
    # Credentials.WindowsMode = 'CurrentUser' skips the Windows prompt and uses your logged-on identity.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Windows', 'Sql')][string]$Purpose,
        [switch]$Force
    )
    if (-not $script:VmmCredentials) { $script:VmmCredentials = @{} }
    if ($Purpose -eq 'Windows' -and -not $Force -and (Get-VmmSetting 'Credentials.WindowsMode' -Default 'Prompt') -eq 'CurrentUser') {
        return $null   # $null = use the current Windows identity
    }
    if (-not $Force -and $script:VmmCredentials.ContainsKey($Purpose)) { return $script:VmmCredentials[$Purpose] }

    $msg = if ($Purpose -eq 'Windows') { 'Account with local admin rights on the target hosts (this session only, never saved)' }
           else { 'SQL login for the Lansweeper database (this session only, never saved)' }
    Suspend-VmmConsoleInput
    try { $cred = Get-Credential -Message $msg }
    finally { Resume-VmmConsoleInput }
    if (-not $cred) {
        throw (New-VmmErrorRecord -Activity "No $Purpose credential entered." -Cause 'The credential prompt was cancelled.' `
            -Fix 'Run the step again and enter the account, or switch Credentials.WindowsMode to CurrentUser in Settings.' `
            -Category AuthenticationError -ErrorId 'VmmCredCancelled')
    }
    $cred.Password.MakeReadOnly()
    $script:VmmCredentials[$Purpose] = $cred
    $cred
}
