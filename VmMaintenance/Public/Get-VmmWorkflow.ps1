function Get-VmmWorkflow {
    <#
    .SYNOPSIS
        Lists workflows (with their steps), the action library (-Actions) or the known fixes (-Knowledge).
    .DESCRIPTION
        Built-in items (Full maintenance = the DEFAULT unless you pick another, Read-only snapshot, the
        maintenance steps, the read-only checks) live in code; your own workflows, actions and known fixes are in
        the encrypted workflows.vmm in the data folder. Create, edit and delete them in the console: main menu K.
    .EXAMPLE
        Get-VmmWorkflow
    .EXAMPLE
        Get-VmmWorkflow -Name 'Read-only snapshot' | Select-Object -ExpandProperty Steps
    .EXAMPLE
        Get-VmmWorkflow -Knowledge -Find 'access denied'
    #>
    [CmdletBinding()]
    param([string]$Name = '*', [switch]$Actions, [switch]$Knowledge, [string]$Find)
    $cat = Get-VmmWorkflowCatalog
    if ($Actions) {
        return @($cat.Actions | Where-Object { $_.Name -like $Name -or $_.Id -like $Name } | Sort-Object Category, Group, Name |
            Select-Object Id, Name, Category, Group, Mode, @{ n = 'BuiltIn'; e = { [bool]$_.BuiltinItem } }, RunOnHost, Title)
    }
    if ($Knowledge) {
        $kb = if ($Find) { @(Find-VmmKnowledge -Catalog $cat -Text $Find | ForEach-Object { $_.Entry }) } else { @($cat.Kb) }
        return @($kb | ForEach-Object {
            $k = $_; $a = $cat.Actions | Where-Object { $_.Id -eq $k.ActionId } | Select-Object -First 1
            [pscustomobject]@{ Id = $k.Id; Action = $(if ($k.ActionId -eq '*') { '(any step)' } elseif ($a) { $a.Name } else { $k.ActionId }); Symptom = $k.Symptom
                               Cause = $k.Cause; Fix = (@($k.Fix) -join ' / '); Helped = $k.Helped; NotHelped = $k.NotHelped }
        })
    }
    @($cat.Workflows | Where-Object { $_.Name -like $Name -or $_.Id -like $Name } | ForEach-Object {
        $wf = $_
        $st = @($wf.Steps | ForEach-Object { $id = $_; $a = $cat.Actions | Where-Object { $_.Id -eq $id } | Select-Object -First 1; if ($a) { "$($a.Name) [$($a.Category)]" } else { "($id missing)" } })
        [pscustomobject]@{ Id = $wf.Id; Name = $wf.Name; Default = ($wf.Id -eq $cat.Default); BuiltIn = [bool]$wf.BuiltinItem; StepCount = $st.Count
                           Changes = [bool](@($wf.Steps | ForEach-Object { $id = $_; $cat.Actions | Where-Object { $_.Id -eq $id -and $_.Category -eq 'Change' } }).Count)
                           Description = $wf.Description; Steps = $st }
    })
}
