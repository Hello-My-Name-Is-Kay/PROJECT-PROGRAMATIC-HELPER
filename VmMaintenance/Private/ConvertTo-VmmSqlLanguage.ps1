function ConvertTo-VmmSqlLanguage {
    # LCID (1036) or culture name (fr-FR) -> the language tag in Microsoft's SQL Server update file
    # names (FRA). Unknown or empty -> ENU (English media installs on any locale).
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Value)
    if (-not $Value) { return 'ENU' }
    $name = $Value
    if ($Value -match '^\d+$') { try { $name = [Globalization.CultureInfo]::GetCultureInfo([int]$Value).Name } catch { return 'ENU' } }
    $map = [ordered]@{ 'zh-CN' = 'CHS'; 'zh-TW' = 'CHT'; 'pt-BR' = 'PTB'; 'en' = 'ENU'; 'fr' = 'FRA'; 'es' = 'ESN'; 'de' = 'DEU'; 'it' = 'ITA'; 'ja' = 'JPN'; 'ko' = 'KOR'; 'ru' = 'RUS' }
    foreach ($k in $map.Keys) { if ($name -like "$k*") { return $map[$k] } }
    'ENU'
}
