function Test-VmmTcpPort {
    # TCP connect test with a hard timeout. Returns $true/$false, never throws.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ComputerName, [Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 1500)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $c.EndConnect($ar); return $true
    } catch { return $false }
    finally { $c.Close() }
}
