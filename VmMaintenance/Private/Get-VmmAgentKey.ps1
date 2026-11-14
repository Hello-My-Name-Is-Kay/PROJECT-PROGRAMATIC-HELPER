function Get-VmmAgentKey {
    # RSA-3072 key pair for host agent results. The private key never leaves this laptop: it is stored
    # as XML encrypted with DPAPI (this Windows user only) in <DataDir>\agent.key. Host agents carry only
    # the public key. Caller must call .Clear() on the returned object.
    [CmdletBinding()]
    param()
    $file = Join-Path (Get-VmmPath -Name Data) 'agent.key'
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider -ArgumentList 3072
    $rsa.PersistKeyInCsp = $false   # [SEC] no copy in the Windows key container
    if (Test-Path -LiteralPath $file) {
        $raw = Unprotect-VmmDpapi -Bytes ([System.IO.File]::ReadAllBytes($file)) -Source $file
        try { $rsa.FromXmlString([Text.Encoding]::UTF8.GetString($raw)) }
        catch {
            $rsa.Clear()
            throw (New-VmmErrorRecord -Activity 'Agent key file is damaged.' -Target $file -Exception $_.Exception `
                -Fix 'Delete agent.key; a new key is created on the next export. Agents exported before must be exported again.' `
                -Category InvalidData -ErrorId 'VmmAgentKey')
        } finally { [Array]::Clear($raw, 0, $raw.Length) }
    } else {
        $xml = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
        try { [System.IO.File]::WriteAllBytes($file, (Protect-VmmDpapi -Bytes $xml)) } finally { [Array]::Clear($xml, 0, $xml.Length) }
        Write-VmmLog "New agent key pair created (private key DPAPI-protected): $file" -Level Muted
    }
    $rsa
}
