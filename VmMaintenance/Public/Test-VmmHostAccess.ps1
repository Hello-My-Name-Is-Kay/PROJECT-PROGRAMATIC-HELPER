function Test-VmmHostAccess {
    <#
    .SYNOPSIS
        Which hosts can this terminal read by itself, and over which route? Fast, read-only.
    .DESCRIPTION
        Per host: DNS, ping, TCP ports, then one query over each open route in order (Fleet.Routes: DCOM,
        WinRM, WinRM-SSL). No facts are read and the last check is kept. Hosts with HandsOn = YES are the
        only ones that need the Extractor in an RDP/RDM session.
    .EXAMPLE
        vmm access
    .EXAMPLE
        Test-VmmHostAccess -Name srv01, srv02
    #>
    [CmdletBinding()]
    param([string[]]$Name, [switch]$PassThru, [switch]$Quiet)
    $p = @{ AccessOnly = $true; PassThru = $true; Quiet = [bool]$Quiet }
    if ($Name) { $p.Name = $Name }
    $r = @(Invoke-VmmFleetCheck @p)
    if ($PassThru) { $r | Select-Object Name, Route, Ports, Reachable, Tried, Error }
}
