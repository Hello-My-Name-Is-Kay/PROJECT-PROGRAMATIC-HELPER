function Resolve-VmmConfigPath {
    # First existing config file from Get-VmmConfigCandidate, or $null.
    [CmdletBinding()]
    param()
    foreach ($c in Get-VmmConfigCandidate) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    $null
}
