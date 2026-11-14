function Set-VmmSetting {
    <#
    .SYNOPSIS
        Changes one setting in your local config (dotted name), keeping a .bak of the previous file.
    .DESCRIPTION
        Refuses names that look like credentials: usernames and passwords are never stored.
        Note: comments in the config file are not kept when it is rewritten; config.example.psd1
        documents every key.
    .EXAMPLE
        Set-VmmSetting -Name Staging.SourceShare -Value '\\fileserver\upgrades'
    .EXAMPLE
        Set-VmmSetting -Name Target.MachinesPerDay -Value 12
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Value)
    # [SEC] judged on the last name part, so 'Credentials.WindowsMode' is allowed but '*.Password' is not
    if (($Name.Split('.')[-1]) -match '(?i)pass|pwd|secret|token|apikey|api_key|username|login|cred$') {
        throw (New-VmmErrorRecord -Activity "Refused: '$Name' looks like a credential." `
            -Cause 'This tool never stores usernames or passwords; it asks for them each session.' -Category SecurityError -ErrorId 'VmmNoSecrets')
    }
    if ($null -eq $script:VmmConfig) { Import-VmmConfig }
    $path = $script:VmmConfigPath
    $cfg  = Import-PowerShellDataFile -LiteralPath $path

    # Typed values from text input: numbers, booleans, comma lists
    if ($Value -is [string]) {
        $v = $Value.Trim()
        if ($v -match '^(?i)\$?(true|false)$') { $Value = $v -match '(?i)true' }
        elseif ($v -match '^-?\d+$') { $Value = [int]$v }
        elseif ($v -match '^@\((.*)\)$') { $Value = @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ }) }
        else { $Value = $v }
    }

    # Time zone: accept 'Lisbon', 'London', 'Europe/Lisbon'... and store the Windows id
    if ($Name -eq 'Schedule.TimeZoneId') {
        $z = Resolve-VmmTimeZone -Text "$Value"
        if (-not $z.Id) {
            $c = if ($z.Matches) { ' Candidates: ' + (($z.Matches | ForEach-Object Id) -join ', ') } else { '' }
            throw (New-VmmErrorRecord -Activity "Unknown time zone '$Value'." -Cause "Not a city, country or Windows time zone id this tool knows.$c" `
                -Fix "Use a city (Lisbon, London), a Windows id ('GMT Standard Time') or run: vmm setup -Page Rules" -Category InvalidArgument -ErrorId 'VmmTimeZone')
        }
        $Value = $z.Id
    }
    $node = $cfg; $parts = $Name.Split('.')
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if (-not $node.Contains($parts[$i]) -or $node[$parts[$i]] -isnot [System.Collections.IDictionary]) { $node[$parts[$i]] = @{} }
        $node = $node[$parts[$i]]
    }
    $node[$parts[-1]] = $Value

    if ($PSCmdlet.ShouldProcess($path, "Set $Name")) {
        Copy-Item -LiteralPath $path -Destination "$path.bak" -Force
        $header = "# VmMaintenance local settings - written by Set-VmmSetting $(Get-Date -Format 'yyyy-MM-dd HH:mm').`r`n# Comments for every key: config\config.example.psd1 in the repository. Never commit this file.`r`n"
        Set-Content -LiteralPath $path -Value ($header + (ConvertTo-VmmPsd1 -InputObject $cfg)) -Encoding UTF8
        try { Import-VmmConfig -Path $path | Out-Null }
        catch {
            Copy-Item -LiteralPath "$path.bak" -Destination $path -Force
            throw (New-VmmErrorRecord -Activity 'The new config did not load; the previous file was restored.' -Target $path -Exception $_.Exception -Category InvalidData)
        }
        $shown = if ($Name -match 'Tenant|Subscription') { '(set)' } else { "$Value" }
        Write-VmmLog "$Name = $shown" -Level Success
    }
}
