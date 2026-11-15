function Get-VmmRdgFileText {
    # Text of a one-off RDCMan group file (.rdg) holding one server. No credentials in it: RDCMan asks.
    # Drive sharing in RDCMan is set on the server's Local resources tab (not written here).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Address, [string]$DisplayName)
    if (-not $DisplayName) { $DisplayName = $Address }
    $x = { param($s) [Security.SecurityElement]::Escape("$s") }
    @(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<RDCMan programVersion="2.93" schemaVersion="3">'
        '  <file>'
        '    <credentialsProfiles />'
        '    <properties>'
        '      <expanded>True</expanded>'
        '      <name>vmm handoff</name>'
        '    </properties>'
        '    <server>'
        '      <properties>'
        "        <displayName>$(& $x $DisplayName)</displayName>"
        "        <name>$(& $x $Address)</name>"
        '      </properties>'
        '    </server>'
        '  </file>'
        '  <connected />'
        '  <favorites />'
        '  <recentlyUsed />'
        '</RDCMan>'
    ) -join "`r`n"
}
