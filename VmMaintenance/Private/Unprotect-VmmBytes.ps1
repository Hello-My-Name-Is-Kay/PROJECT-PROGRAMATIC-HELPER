function Unprotect-VmmBytes {
    # Verifies the HMAC (constant-time) before decrypting. Any tampering or corruption is refused.
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes, [string]$Source = 'fleet store')
    $bad = { param($why)
        New-VmmErrorRecord -Activity 'Encrypted file is damaged or was modified.' -Target $Source -Cause $why `
            -Fix 'Restore the file from a backup, or delete it to start an empty fleet store (host records are lost; re-import your list).' `
            -Category InvalidData -ErrorId 'VmmStoreIntegrity'
    }
    if ($Bytes.Length -lt 68 -or [Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ne 'VMM1') { throw (& $bad 'Unknown format or truncated file.') }

    $key = Get-VmmDataKey
    try {
        $bodyLen = $Bytes.Length - 32
        $h = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $key.Mac)
        try { $calc = $h.ComputeHash($Bytes, 0, $bodyLen) } finally { $h.Dispose() }
        $diff = 0
        for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($calc[$i] -bxor $Bytes[$bodyLen + $i]) }
        if ($diff -ne 0) { throw (& $bad 'Integrity check (HMAC) failed: content changed, or it was encrypted with another key.') }

        $iv = New-Object byte[] 16
        [Array]::Copy($Bytes, 4, $iv, 0, 16)
        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.KeySize = 256
            $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key     = $key.Enc
            $aes.IV      = $iv
            $tx = $aes.CreateDecryptor()
            try { $plain = $tx.TransformFinalBlock($Bytes, 20, $bodyLen - 20) } finally { $tx.Dispose() }
        } finally { $aes.Dispose() }
        return , $plain
    } finally {
        [Array]::Clear($key.Enc, 0, 32)
        [Array]::Clear($key.Mac, 0, 32)
    }
}
