function Unprotect-VmmAgentResult {
    # Decrypts a VMM2 line from the host agent: 'VMM2' | len(2) | RSA-OAEP(64-byte key) | IV(16) | AES-256-CBC | HMAC-SHA256.
    # [SEC] The MAC is checked (constant time) before decrypting; any failure gives one generic error.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Base64)
    $bad = { param($why) New-VmmErrorRecord -Activity 'Host agent result rejected.' -Cause $why `
        -Fix 'Export the result again on the host (agent menu 5) and paste the complete line. If the agent was exported from another laptop or before a key reset, export a new agent: vmm agent -HostName <host>.' `
        -Category SecurityError -ErrorId 'VmmAgentResult' }
    try { $all = [Convert]::FromBase64String($Base64) } catch { throw (& $bad 'Not valid base64 (line cut while copying?).') }
    if ($all.Length -lt 4 + 2 + 16 + 16 + 32 -or $all.Length -gt 4MB -or [Text.Encoding]::ASCII.GetString($all, 0, 4) -ne 'VMM2') { throw (& $bad 'Unknown format or wrong size.') }
    $wl = ($all[4] -shl 8) + $all[5]
    $bodyLen = $all.Length - 32
    $ctLen = $bodyLen - 6 - $wl - 16
    if ($wl -lt 64 -or $ctLen -lt 16 -or ($ctLen % 16) -ne 0) { throw (& $bad 'Corrupt header.') }

    $rsa = Get-VmmAgentKey
    $keys = $null
    try {
        $wrapped = New-Object byte[] $wl
        [Array]::Copy($all, 6, $wrapped, 0, $wl)
        try { $keys = $rsa.Decrypt($wrapped, $true) } catch { throw (& $bad 'Not encrypted for this laptop''s agent key.') }
        if ($keys.Length -ne 64) { throw (& $bad 'Wrong key length.') }
        $ek = New-Object byte[] 32; $mk = New-Object byte[] 32
        [Array]::Copy($keys, 0, $ek, 0, 32); [Array]::Copy($keys, 32, $mk, 0, 32)

        $h = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $mk)
        try { $calc = $h.ComputeHash($all, 0, $bodyLen) } finally { $h.Dispose() }
        $diff = 0
        for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($calc[$i] -bxor $all[$bodyLen + $i]) }
        if ($diff -ne 0) { throw (& $bad 'Integrity check failed (modified or truncated).') }

        $iv = New-Object byte[] 16
        [Array]::Copy($all, 6 + $wl, $iv, 0, 16)
        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.KeySize = 256; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = $ek; $aes.IV = $iv
            $tx = $aes.CreateDecryptor()
            try { $plain = $tx.TransformFinalBlock($all, 6 + $wl + 16, $ctLen) } finally { $tx.Dispose() }
        } finally { $aes.Dispose() }
        try { return [Text.Encoding]::UTF8.GetString($plain) } finally { [Array]::Clear($plain, 0, $plain.Length) }
    } finally {
        if ($keys) { [Array]::Clear($keys, 0, $keys.Length) }
        if ($ek) { [Array]::Clear($ek, 0, 32) }
        if ($mk) { [Array]::Clear($mk, 0, 32) }
        $rsa.Clear()
    }
}
