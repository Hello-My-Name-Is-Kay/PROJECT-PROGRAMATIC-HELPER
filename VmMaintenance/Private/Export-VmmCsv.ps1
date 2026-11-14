function Export-VmmCsv {
    # Export-Csv with a specific error when the file is locked (open in Excel) or not writable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )
    try { $InputObject | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -ErrorAction Stop }
    catch {
        throw (New-VmmErrorRecord -Activity 'Could not write the results CSV.' -Target $Path -Exception $_.Exception `
            -Cause 'The file is open in Excel (locked), or the folder is read-only.' `
            -Fix 'Close the file and re-run, or pass a different -OutCsv path.' -Category WriteError)
    }
    Write-VmmLog "Results saved to $Path" -Level Success
}
