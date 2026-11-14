function ConvertTo-VmmColorRole {
    # Maps what the screens already say (a log level, a status word, an old console colour name) to a theme role.
    # Colour is for statuses: anything that is not a status comes back as Text or Muted.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Name)
    switch -Regex ("$Name") {
        '^(Ok|OK|Success|Green|TargetMet)$'                      { return 'Ok' }
        '^(Warn|WARN|Warning|Yellow|DarkYellow|AtRisk)$'         { return 'Warn' }
        '^(Fail|FAIL|Error|Red|DarkRed|Critical|Unreachable)$'   { return 'Fail' }
        '^(Muted|DarkGray|Trace|Output|DarkCyan)$'               { return 'Muted' }
        '^(Accent|Title|Header)$'                                       { return 'Accent' }
        '^(Strong|White)$'                                       { return 'Strong' }
        default                                                  { return 'Text' }   # Info, Plain, Gray, Cyan...
    }
}
