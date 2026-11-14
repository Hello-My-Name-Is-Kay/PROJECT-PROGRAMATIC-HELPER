function Remove-VmmOldLog {
    # Deletes day logs (vmm_*.log) older than Log.KeepDays (default 30; 0 = all but today). Returns the files removed.
    [CmdletBinding()]
    param([int]$KeepDays = -1)
    if ($KeepDays -lt 0) { $KeepDays = [int](Get-VmmSetting 'Log.KeepDays' -Default 30) }
    $dir = Get-VmmPath -Name Logs
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $limit = (Get-Date).Date.AddDays(-[math]::Max(0, $KeepDays))
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'vmm_*.log' -File -ErrorAction SilentlyContinue)) {
        if ($f.LastWriteTime -lt $limit) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; $f.Name }
    }
}
