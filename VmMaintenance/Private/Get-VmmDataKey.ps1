function Get-VmmDataKey {
    # 64 random bytes = 32-byte AES-256 key + 32-byte HMAC-SHA256 key. Created once, stored only as a
    # DPAPI blob. Returns @{ Enc; Mac }; callers clear both arrays with [Array]::Clear when done.
    [CmdletBinding()]
    param()
    $file = Join-Path (Get-VmmPath -Name Data) 'store.key'
    if (-not (Test-Path -LiteralPath $file)) {
        $raw = New-Object byte[] 64
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($raw) } finally { $rng.Dispose() }
        [System.IO.File]::WriteAllBytes($file, (Protect-VmmDpapi -Bytes $raw))
        Write-VmmLog "New data key created (DPAPI, this Windows user only): $file" -Level Muted
    } else {
        $raw = Unprotect-VmmDpapi -Bytes ([System.IO.File]::ReadAllBytes($file)) -Source $file
    }
    $enc = New-Object byte[] 32
    $mac = New-Object byte[] 32
    [Array]::Copy($raw, 0, $enc, 0, 32)
    [Array]::Copy($raw, 32, $mac, 0, 32)
    [Array]::Clear($raw, 0, $raw.Length)
    @{ Enc = $enc; Mac = $mac }
}
