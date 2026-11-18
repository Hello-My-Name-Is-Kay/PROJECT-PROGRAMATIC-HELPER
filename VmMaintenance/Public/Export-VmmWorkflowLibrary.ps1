function Export-VmmWorkflowLibrary {
    <#
    .SYNOPSIS
        Writes your workflows, actions and known fixes to a shared JSON library (sanitized, not encrypted).
    .DESCRIPTION
        The library is how technicians share known fixes and workflows: put it on the network share
        (Workflow.LibraryPath) and every vmm imports it (Import-VmmWorkflowLibrary, I in the workflow manager).
        Your own copy stays encrypted in workflows.vmm; the library holds no host names, FQDNs, IPs, ids or
        secrets (they are replaced with <HOST>, <IP>, <ID>, ***). An existing library file is merged, not
        overwritten: entries other people added stay in it. Built-in items are not exported.
    .EXAMPLE
        Export-VmmWorkflowLibrary -Path '\\server\share\vmm\vmm-library.json'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)
    if (-not $Path) { $Path = Get-VmmSetting 'Workflow.LibraryPath' -Default '' }
    if (-not $Path) { $Path = Join-Path ([Environment]::GetFolderPath('Desktop')) 'vmm-library.json' }
    $Path = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    $ws = Read-VmmWorkflowStore
    $names = @(Get-VmmFleetName)
    $clean = { param($s) ConvertTo-VmmShareableText -Text $s -Names $names }
    $lib = [pscustomobject]@{ Format = 'VMMLIB1'; Exported = (Get-Date).ToUniversalTime().ToString('o'); Actions = @(); Workflows = @(); Kb = @() }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $lib = Read-VmmWorkflowLibraryFile -Path $Path; $lib.Exported = (Get-Date).ToUniversalTime().ToString('o') }
    $merge = { param($list, $item) $o = @($list | Where-Object { $_.Id -ne $item.Id }); $old = $list | Where-Object { $_.Id -eq $item.Id } | Select-Object -First 1
               if ($old -and "$($old.Updated)" -gt "$($item.Updated)") { $o += $old } else { $o += $item }; $o }
    foreach ($a in $ws.Actions) {
        $c = $a | Select-Object *
        foreach ($p in 'Name', 'Title', 'Expect', 'Group') { $c.$p = & $clean $c.$p }
        $c.Steps = @($c.Steps | ForEach-Object { & $clean $_ }); $c.Commands = @($c.Commands | ForEach-Object { & $clean $_ })
        $lib.Actions = & $merge $lib.Actions $c
    }
    foreach ($w in $ws.Workflows) { $c = $w | Select-Object *; $c.Name = & $clean $c.Name; $c.Description = & $clean $c.Description; $lib.Workflows = & $merge $lib.Workflows $c }
    foreach ($k in $ws.Kb) {
        $c = $k | Select-Object *
        foreach ($p in 'Symptom', 'Cause') { $c.$p = & $clean $c.$p }
        $c.Fix = @($c.Fix | ForEach-Object { & $clean $_ }); $c.Commands = @($c.Commands | ForEach-Object { & $clean $_ })
        $lib.Kb = & $merge $lib.Kb $c
    }
    $json = $lib | ConvertTo-Json -Depth 8
    $leak = @($names | Where-Object { $_.Length -ge 3 -and $json -match ('(?i)(?<![\w-])' + [regex]::Escape($_) + '(?![\w-])') })
    if ($leak) {
        throw (New-VmmErrorRecord -Activity 'Library not written: it still contains a host name from your fleet.' -Target $Path `
            -Fix 'Edit the known fix or action that names the host (workflow manager), then export again.' -Category SecurityError -ErrorId 'VmmLibraryLeak')
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Write the shared workflow library')) {
        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
        Write-VmmLog ("Library written: {0} ({1} workflow(s), {2} action(s), {3} known fix(es))" -f $Path, @($lib.Workflows).Count, @($lib.Actions).Count, @($lib.Kb).Count) -Level Success
    }
    [pscustomobject]@{ Path = $Path; Workflows = @($lib.Workflows).Count; Actions = @($lib.Actions).Count; Kb = @($lib.Kb).Count }
}
