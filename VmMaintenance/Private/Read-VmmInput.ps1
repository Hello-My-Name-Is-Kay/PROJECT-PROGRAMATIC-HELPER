function Read-VmmInput {
    # One input event for the TUI: Key (VK code + char), Click/DoubleClick (row in the window), Wheel,
    # or Tick when nothing happened within -TimeoutMs (used to refresh the clock).
    [CmdletBinding()]
    param([int]$TimeoutMs = 1000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($script:VmmMouse) {
            $e = [VmmConsoleInput]::Poll()
            if ($e) {
                $p = $e.Split('|')
                switch ($p[0]) {
                    'K' { return [pscustomobject]@{ Type = 'Key'; VK = [int]$p[1]; Char = [char][int]$p[2] } }
                    'M' { return [pscustomobject]@{ Type = 'Click'; X = [int]$p[1]; Y = [int]$p[2] - [Console]::WindowTop } }
                    'D' { return [pscustomobject]@{ Type = 'DoubleClick'; X = [int]$p[1]; Y = [int]$p[2] - [Console]::WindowTop } }
                    'W' { return [pscustomobject]@{ Type = 'Wheel'; Delta = [int]$p[1] } }
                }
                continue
            }
        } elseif ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            return [pscustomobject]@{ Type = 'Key'; VK = [int]$k.Key; Char = $k.KeyChar }
        }
        Start-Sleep -Milliseconds 40
    }
    [pscustomobject]@{ Type = 'Tick' }
}
