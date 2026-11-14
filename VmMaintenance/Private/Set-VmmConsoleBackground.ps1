function Set-VmmConsoleBackground {
    # Deep iceberg background for the console UI: redefines the console's "black" (palette entry 0) to the
    # theme's Bg colour while vmm runs, so cleared areas, prompts and tables sit on the same deep blue as the
    # themed lines. -Restore puts the terminal's own colour back. Only with 24-bit colour (VT) and
    # UI.DeepBackground (default on); otherwise the background stays black.
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Restore)
    $th = Get-VmmTheme
    if (-not $th.TrueColor -or $th.Plain) { return }
    if (-not (Get-VmmSetting 'UI.DeepBackground' -Default $true)) { return }
    if (-not $PSCmdlet.ShouldProcess('console palette entry 0', $(if ($Restore) { 'restore' } else { 'set' }))) { return }
    $e = [char]27
    if ($Restore) { Write-Host "${e}]104;0${e}\" -NoNewline; return }
    $b = $th.Roles.Bg
    Write-Host ("${e}]4;0;rgb:{0:x2}/{1:x2}/{2:x2}${e}\" -f $b.R, $b.G, $b.B) -NoNewline
}
