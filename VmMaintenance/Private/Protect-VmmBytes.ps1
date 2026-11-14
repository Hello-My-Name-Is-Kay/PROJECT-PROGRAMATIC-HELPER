function Protect-VmmBytes {
    # Authenticated encryption: AES-256-CBC + HMAC-SHA256, encrypt-then-MAC.
    # Layout: 'VMM1' | IV(16) | ciphertext | HMAC(32) over everything before it.
    # (AES-GCM is not available in .NET Framework, which Windows PowerShell 5.1 runs on.)
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $key = Get-VmmDataKey
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key     = $key.Enc
        $aes.GenerateIV()
        $tx = $aes.CreateEncryptor()
        try { $ct = $tx.TransformFinalBlock($Bytes, 0, $Bytes.Length) } finally { $tx.Dispose() }

        $body = New-Object byte[] (20 + $ct.Length)
        [Array]::Copy([Text.Encoding]::ASCII.GetBytes('VMM1'), 0, $body, 0, 4)
        [Array]::Copy($aes.IV, 0, $body, 4, 16)
        [Array]::Copy($ct, 0, $body, 20, $ct.Length)

        $h = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $key.Mac)
        try { $tag = $h.ComputeHash($body) } finally { $h.Dispose() }

        $out = New-Object byte[] ($body.Length + 32)
        [Array]::Copy($body, 0, $out, 0, $body.Length)
        [Array]::Copy($tag, 0, $out, $body.Length, 32)
        return , $out
    } finally {
        $aes.Dispose()
        [Array]::Clear($key.Enc, 0, 32)
        [Array]::Clear($key.Mac, 0, 32)
    }
}
