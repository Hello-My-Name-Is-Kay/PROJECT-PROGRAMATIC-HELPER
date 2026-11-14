function Out-VmmHost {
    # Out-Host that also logs: what a command shows as a table or list is printed AND written to the day log
    # (level Output, masked), so the log holds what the screen held. Use it instead of "| Out-Host".
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject)
    begin { $items = New-Object System.Collections.Generic.List[object] }
    process { $items.Add($InputObject) }
    end {
        if (-not $items.Count) { return }
        $width = 200
        try { if ([Console]::WindowWidth -gt 40) { $width = [Console]::WindowWidth - 1 } } catch { }
        $lines = @($items | Out-String -Width $width -Stream)
        $logged = 0
        foreach ($l in $lines) {
            Write-Host $l
            if ($l.Trim() -and $logged -lt 400) { Add-VmmLogEntry -Text (Protect-VmmLogText $l.TrimEnd()) -Level Output; $logged++ }
        }
        if ($logged -ge 400) { Add-VmmLogEntry -Text '(output cut at 400 lines in the log)' -Level Output }
    }
}
