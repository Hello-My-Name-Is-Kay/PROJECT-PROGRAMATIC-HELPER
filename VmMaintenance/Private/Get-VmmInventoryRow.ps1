function Get-VmmInventoryRow {
    # One host's inventory, one object per column (catalogue order):
    #   Key, Header, Value, Origin (check | host agent | collector | workflow | default | manual | ''), Source, Missing, Help
    # Precedence: Auto = read value, else what you typed. Derived = what you typed (override), else the workflow.
    # Manual = what you typed, else Inventory.Defaults.<Key>. Missing = Required and still empty.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, $Catalog)
    if (-not $Catalog) { $Catalog = Get-VmmInventoryCatalog }
    $prop = { param($o, $k) if ($o) { $p = $o.PSObject.Properties[$k]; if ($p) { $p.Value } } }
    $autoStore = & $prop $Record 'InventoryAuto'
    $manStore  = & $prop $Record 'Inventory'
    $defaults  = Get-VmmSetting 'Inventory.Defaults' -Default @{}
    $c = $Record.Check
    $pol = Get-VmmHostPolicy -Record $Record
    $defs = @(Get-VmmWorkflowDefinition)
    $state = { param($n) $s = & $prop $Record.Steps $n; if ($s) { "$($s.Status)" } else { '' } }
    $ver = "$(Get-VmmSetting 'Staging.OsMediaVersion' -Default '2019')"

    foreach ($f in $Catalog) {
        $val = ''; $origin = ''
        $man = & $prop $manStore $f.Key
        $manVal = if ($man) { "$(& $prop $man 'Value')" } else { '' }
        switch ($f.Source) {
            'Auto' {
                $a = & $prop $autoStore $f.Key
                $read = switch ($f.Key) {
                    'Hostname'   { $Record.Name }
                    'OSVersion'  { if ($c -and $c.OS) { "$($c.OS)$(if ($c.Build) { " (build $($c.Build))" })" } }
                    'SqlPresent' { if ($c -and $c.Sql) { if ($c.Sql -eq 'none') { 'No' } else { "Yes: $($c.Sql)" } } }
                    'IPAddress'  { if ($a) { $a.Value } elseif ($Record.IPv4) { $Record.IPv4 } }
                    default      { if ($a) { $a.Value } }
                }
                if ("$read") { $val = "$read"; $origin = if ($a -and $f.Key -notin 'Hostname', 'OSVersion', 'SqlPresent') { "$($a.Via)" } else { 'check' } }
                elseif ($manVal) { $val = $manVal; $origin = 'manual' }
            }
            'Derived' {
                if ($manVal) { $val = $manVal; $origin = 'manual' }
                else {
                    $origin = 'workflow'
                    $val = switch ($f.Key) {
                        'ActionsToExecute' {
                            if (-not $pol.Workable) { "None: $($pol.Why)" }
                            else {
                                $todo = @(foreach ($d in $defs) { if ((& $state $d.Name) -notin 'Success', 'NotNeeded') { if ($d.Name -eq 'Upgrade') { "Upgrade to Windows Server $ver" } else { $d.Name } } })
                                if ($todo) { $todo -join ', ' } else { 'None: all steps done' }
                            }
                        }
                        'ActionsStatus' {
                            $open = @($Record.Blockers | Where-Object { $_ -and -not $_.Resolved })
                            $done = @($defs | Where-Object { (& $state $_.Name) -eq 'Success' })
                            if ($Record.Hold) { 'On hold' }
                            elseif (-not $pol.Workable) { "Not in scope ($($pol.Scope))" }
                            elseif ($open) { "Blocked ($($open[-1].Step))" }
                            elseif ((& $state 'Verify') -eq 'Success') { 'Done' }
                            elseif ($done) { "In progress (last: $($done[-1].Name))" }
                            else { 'Not started' }
                        }
                        'ExecutionDate' {
                            $u = & $prop $Record.Steps 'Upgrade'
                            if ($u -and $u.Status -eq 'Success' -and $u.At) { try { ([datetime]$u.At).ToString('yyyy-MM-dd') } catch { '' } }
                        }
                        default { '' }
                    }
                    if (-not "$val") { $origin = '' }
                }
            }
            default {
                if ($manVal) { $val = $manVal; $origin = 'manual' }
                elseif ($defaults -is [System.Collections.IDictionary] -and "$($defaults[$f.Key])") { $val = "$($defaults[$f.Key])"; $origin = 'default' }
            }
        }
        [pscustomobject]@{ Key = $f.Key; Header = $f.Header; Value = "$val"; Origin = $origin; Source = $f.Source
                           Missing = ($f.Required -and -not "$val"); Help = $f.Help }
    }
}
