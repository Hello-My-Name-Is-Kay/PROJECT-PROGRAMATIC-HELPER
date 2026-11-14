function Exit-VmmInstanceLock {
    # Releases the single-instance lock taken by Enter-VmmInstanceLock (also runs when the module unloads).
    [CmdletBinding()]
    param()
    if (-not $script:VmmInstanceLock) { return }
    try { Remove-Item -LiteralPath ($script:VmmInstanceLock.Name + '.txt') -Force -ErrorAction SilentlyContinue } catch { }
    try { $script:VmmInstanceLock.Dispose() } catch { }
    $script:VmmInstanceLock = $null
}
