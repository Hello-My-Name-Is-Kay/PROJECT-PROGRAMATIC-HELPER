function Export-VmmWorkflowRunbook {
    <#
    .SYNOPSIS
        Builds the host runbook for one ticket: a .ps1 and a .cmd to copy into the RDP session, that guide the
        person on the host through the ticket's workflow step by step.
    .DESCRIPTION
        For hosts you reach only by RDP/RDM with copy and paste. The runbook (Windows PowerShell 2.0+) shows each
        step with its instructions and commands, runs read-only commands on request (actions marked RunOnHost),
        shows the commands of other steps only after the gate (time window or OVERRIDE, rollback point
        SNAPSHOT TAKEN / BACKUP CONFIRMED, YES), and on a failure shows the known fixes and records the new one.
        It writes one text file on the host desktop, VMMW_<HOST>_<time>.txt (also on the clipboard): copy it back
        and import it (I on the ticket, or Import-VmmRunbookResult). The .cmd starts the .ps1 with
        -ExecutionPolicy Bypass for that one run. Files go to the outbox (Handoff.OutboxFolder) and both are put
        on the clipboard as files when the console can (paste them on the RDP desktop).
    .EXAMPLE
        Export-VmmWorkflowRunbook -HostName srv01
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostName, [string]$OutFolder, [switch]$NoClipboard)
    $store = Read-VmmStore
    $rec = Get-VmmHostRecord -Store $store -Name $HostName
    $cat = Get-VmmWorkflowCatalog
    $res = Resolve-VmmHostWorkflow -Record $rec -Catalog $cat
    if ($res.Policy.Scope -eq 'ClientOs') { throw (New-VmmErrorRecord -Activity "No runbook for $($rec.Name)." -Cause $res.Policy.Why -Fix 'Client OSes are not touched without orders (vmm order).' -Category PermissionDenied -ErrorId 'VmmPolicyClientOs') }
    if (-not $res.Total) { throw (New-VmmErrorRecord -Activity "The workflow of $($rec.Name) has no steps." -Fix 'Pick a workflow (W on the ticket) or add steps (A).' -Category InvalidData -ErrorId 'VmmWorkflowEmpty') }
    $text = Get-VmmRunbookScript -Record $rec -Catalog $cat -Resolved $res
    $dir = if ($OutFolder) { $OutFolder } else { Get-VmmPath -Name Outbox }
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $base = 'VmmRunbook_{0}_{1}' -f $rec.Name, (Get-Date -Format 'yyyyMMdd-HHmm')
    $ps1 = Join-Path $dir "$base.ps1"; $cmd = Join-Path $dir "$base.cmd"
    $enc = New-Object Text.UTF8Encoding $true   # BOM: PowerShell 2.0-5.1 read the file as UTF-8
    [IO.File]::WriteAllText($ps1, $text, $enc)
    [IO.File]::WriteAllText($cmd, ("@echo off`r`nrem vmm runbook launcher: runs the .ps1 next to it once, without changing the execution policy`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$base.ps1`"`r`npause`r`n"), (New-Object Text.ASCIIEncoding))
    $copied = $false
    if (-not $NoClipboard -and (Get-Command Set-Clipboard -ErrorAction SilentlyContinue).Parameters.ContainsKey('Path')) { try { Set-Clipboard -Path $ps1, $cmd; $copied = $true } catch { } }
    Write-VmmLog "Runbook for $($rec.Name) ($($res.Workflow.Name), $($res.Total) steps, $($res.Total - $res.Done) to do):" -Level Success
    Write-VmmLog "  $ps1" -Level Plain
    Write-VmmLog "  $cmd" -Level Plain
    Write-VmmLog $(if ($copied) { '1. Both files are on the clipboard: paste them on the RDP desktop (Ctrl+V).' } else { '1. Copy both files to the RDP desktop (drag, or copy/paste in Explorer).' }) -Level Info
    Write-VmmLog '2. On the host: double-click the .cmd and follow the steps.' -Level Info
    Write-VmmLog '3. It saves VMMW_<HOST>_<time>.txt on the host desktop and puts it on the clipboard: back here press I on the ticket.' -Level Info
    [pscustomobject]@{ HostName = $rec.Name; Script = $ps1; Launcher = $cmd; Steps = $res.Total; ToDo = $res.Total - $res.Done }
}
