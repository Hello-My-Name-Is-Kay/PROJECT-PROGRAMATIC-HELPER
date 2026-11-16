function Get-VmmWorkflowDefinition {
    # The per-host workflow, in order. Class decides the time rule; Mode says who does the work:
    #   Auto   = the tool does it (CIM, Azure API, file copy)
    #   Guided = you do it in RDP/RDM with a step-by-step checklist, then confirm the result
    #   Hybrid = Auto on Azure VMs, Guided elsewhere
    # Snapshot = one of the four Azure snapshot points (every disk of the VM). SqlInvasive = the step stops or
    # changes SQL Server (ExpandDisk deallocates the VM; Upgrade = OS in-place upgrade or SQL SP/CU).
    # SnapStart is Class Staging (allowed in business hours) while Policy.SnapStartInBusinessHours is on: it does
    # not touch the guest and causes no downtime. Off = Change, like the other snapshot points.
    [CmdletBinding()]
    param()
    $startClass = if ([bool](Get-VmmSetting 'Policy.SnapStartInBusinessHours' -Default $true)) { 'Staging' } else { 'Change' }
    $n = 0
    foreach ($s in @(
        @{ Name = 'Precheck';    Class = 'ReadOnly';  Mode = 'Auto';   Changes = $false; Snapshot = $false; SqlInvasive = $false; Title = 'Pre-check: reachability, OS/SP, SQL, C: space, pending reboot' }
        @{ Name = 'SnapStart';   Class = $startClass; Mode = 'Auto';   Changes = $false; Snapshot = $true;  SqlInvasive = $false; Title = 'Snapshot point 1: all disks, unless every disk has a snapshot from the last hour (you may decline)' }
        @{ Name = 'Stage';       Class = 'Staging';   Mode = 'Auto';   Changes = $false; Snapshot = $false; SqlInvasive = $false; Title = 'Stage install files from the network share to C:\Temp (hash verified)' }
        @{ Name = 'SnapPreSql';  Class = 'Change';    Mode = 'Hybrid'; Changes = $false; Snapshot = $true;  SqlInvasive = $false; Title = 'Snapshot point 2: all disks before the first SQL-invasive step (other platforms: confirm a backup)' }
        @{ Name = 'ExpandDisk';  Class = 'Change';    Mode = 'Hybrid'; Changes = $true;  Snapshot = $false; SqlInvasive = $true;  Title = 'Grow OS disk + extend C: when free space is under Lansweeper.OkGB (VM deallocated: SQL stops)' }
        @{ Name = 'Upgrade';     Class = 'Change';    Mode = 'Guided'; Changes = $true;  Snapshot = $false; SqlInvasive = $true;  Title = 'Run the upgrade/update from C:\Temp (OS in-place upgrade or SQL SP/CU)' }
        @{ Name = 'SnapPostSql'; Class = 'Change';    Mode = 'Auto';   Changes = $false; Snapshot = $true;  SqlInvasive = $false; Title = 'Snapshot point 3: all disks after the last SQL-invasive step' }
        @{ Name = 'Verify';      Class = 'ReadOnly';  Mode = 'Auto';   Changes = $false; Snapshot = $false; SqlInvasive = $false; Title = 'Post-check: host back, OS/SQL as expected, services up' }
        @{ Name = 'ManualCheck'; Class = 'ReadOnly';  Mode = 'Guided'; Changes = $false; Snapshot = $false; SqlInvasive = $false; Title = 'Your own check of the host and its applications (confirm, or bypass with a reason)' }
        @{ Name = 'SnapFinal';   Class = 'Change';    Mode = 'Auto';   Changes = $false; Snapshot = $true;  SqlInvasive = $false; Title = 'Snapshot point 4: all disks, the last step, after your manual check' }
    )) {
        $n++
        [pscustomobject]@{ Order = $n; Name = $s.Name; Class = $s.Class; Mode = $s.Mode; Changes = $s.Changes; Snapshot = $s.Snapshot; SqlInvasive = $s.SqlInvasive; Title = $s.Title }
    }
}
