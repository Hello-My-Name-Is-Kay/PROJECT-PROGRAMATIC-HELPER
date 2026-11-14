function Initialize-VmmConsoleInput {
    # Compiles the C# console-input helper once and enables mouse events. Falls back to keyboard-only
    # ([Console]::ReadKey) when UI.Mouse is off, the host is not a real console (ISE, VS Code) or compile fails.
    [CmdletBinding()]
    param()
    $script:VmmMouse = $false
    if (-not [bool](Get-VmmSetting 'UI.Mouse' -Default $true)) { return }
    if ($script:VmmFlags -and $script:VmmFlags.NoMouse) { return }   # --no-mouse
    if ($Host.Name -ne 'ConsoleHost') { return }
    try {
        if (-not ('VmmConsoleInput' -as [type])) {
            $src = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'Resources\VmmConsoleInput.cs') -Raw
            Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
        }
        $script:VmmMouse = [VmmConsoleInput]::Enable()
    } catch {
        Write-VmmLog "Mouse support off (keyboard still works): $($_.Exception.Message)" -Level Muted
    }
}
