function Get-VmmWorkflowDefinition {
    # The per-host workflow, in order. Class decides the time rule; Mode says who does the work:
    #   Auto   = the tool does it (CIM, Azure API, file copy)
    #   Guided = you do it in RDP/RDM with a step-by-step checklist, then confirm the result
    #   Hybrid = Auto on Azure VMs, Guided elsewhere
    [CmdletBinding()]
    param()
    @(
        [pscustomobject]@{ Order = 1; Name = 'Precheck';    Class = 'ReadOnly'; Mode = 'Auto';   Changes = $false; Title = 'Pre-check: reachability, OS/SP, SQL, C: space, pending reboot' }
        [pscustomobject]@{ Order = 2; Name = 'Stage';       Class = 'Staging';  Mode = 'Auto';   Changes = $false; Title = 'Stage install files from the network share to C:\Temp (hash verified)' }
        [pscustomobject]@{ Order = 3; Name = 'PreSnapshot'; Class = 'Change';   Mode = 'Hybrid'; Changes = $false; Title = 'Rollback snapshot of all disks (Azure) / confirm backup (other platforms)' }
        [pscustomobject]@{ Order = 4; Name = 'ExpandDisk';  Class = 'Change';   Mode = 'Hybrid'; Changes = $true;  Title = 'Grow OS disk + extend C: when free space is under Lansweeper.OkGB' }
        [pscustomobject]@{ Order = 5; Name = 'Upgrade';     Class = 'Change';   Mode = 'Guided'; Changes = $true;  Title = 'Run the upgrade/update from C:\Temp' }
        [pscustomobject]@{ Order = 6; Name = 'Verify';      Class = 'ReadOnly'; Mode = 'Auto';   Changes = $false; Title = 'Post-check: host back, OS/SQL as expected, services up' }
    )
}
