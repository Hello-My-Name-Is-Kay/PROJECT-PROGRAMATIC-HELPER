function ConvertTo-VmmAiSafeText {
    # [SEC] Prepares text for an AI model: masks secrets, IPs, UNC paths, e-mail addresses and
    # DOMAIN\user, and replaces every fleet host name with an alias (HOST01, HOST02...) unless
    # Ai.SendHostNames is on. Returns the safe text and the alias map (used to restore names in the answer).
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text, [hashtable]$Map)
    if (-not $Map) { $Map = @{} }
    $t = Protect-VmmLogText $Text
    $t = $t -replace '\b(?:\d{1,3}\.){3}\d{1,3}\b', '<ip>'
    $t = $t -replace '\\\\[^\\\s]+\\[^\s''"]*', '\\<share>\...'
    $t = $t -replace '\b[\w\.-]+@[\w\.-]+\.\w+\b', '<email>'
    $t = $t -replace '\b[A-Za-z0-9\-]{2,15}\\[A-Za-z0-9\.\-_]{2,64}\b', '<account>'
    if ($env:USERNAME) { $t = $t -replace [regex]::Escape($env:USERNAME), '<me>' }
    if (-not (Get-VmmSetting 'Ai.SendHostNames' -Default $false)) {
        $names = @()
        try { $names = @((Read-VmmStore).Hosts | ForEach-Object { $_.Name } | Sort-Object Length -Descending) } catch { }
        foreach ($n in $names) {
            if (-not $n) { continue }
            if (-not $Map.ContainsKey($n)) { $Map[$n] = 'HOST{0:D2}' -f ($Map.Count + 1) }
            $t = $t -replace ('(?i)\b' + [regex]::Escape($n) + '(\.[\w\.-]+)?\b'), $Map[$n]
        }
    }
    [pscustomobject]@{ Text = $t; Map = $Map }
}
