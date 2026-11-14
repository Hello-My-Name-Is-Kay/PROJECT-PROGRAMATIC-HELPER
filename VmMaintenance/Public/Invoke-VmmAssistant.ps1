function Invoke-VmmAssistant {
    <#
    .SYNOPSIS
        Optional AI assistant (off by default): explain an error, suggest the next step, draft wording
        for a manager report. Advisory only - it cannot run commands or change files.
    .DESCRIPTION
        Providers (Ai.Provider): Local (Microsoft Foundry Local / Ollama on this laptop) or AzureOpenAI
        (your organisation's Azure OpenAI / Foundry deployment, signed in with your work account).
        Consumer Microsoft Copilot has no API this tool can call; see docs/AI.md.
        [SEC] Before anything is sent, secrets, IPs, shares, e-mails and accounts are masked and host
        names are replaced with aliases (HOST01...). With Ai.ConfirmEachSend on (default) you see the
        exact text and must confirm. Nothing is stored; the answer is shown with real names restored.
    .PARAMETER IncludeFleet
        Adds a sanitized fleet summary (counts per step/health, open blockers) as context.
    .EXAMPLE
        Invoke-VmmAssistant -Prompt 'Explain this error: WinRM cannot complete the operation...'
    .EXAMPLE
        vmm ai -Prompt 'What should I do first today?' -IncludeFleet
    #>
    [CmdletBinding()]
    param([string]$Prompt, [switch]$IncludeFleet, [switch]$Force)
    if (-not (Get-VmmSetting 'Features.Ai' -Default $false)) {
        throw (New-VmmErrorRecord -Activity 'The AI assistant is turned off.' -Fix 'Turn it on with vmm setup (AI page) or: vmm set -Name Features.Ai -Value true, then pick Ai.Provider. See docs/AI.md.' -Category NotEnabled -ErrorId 'VmmAiOff')
    }
    if (-not $Prompt) { $Prompt = Read-VmmPrompt 'Question for the assistant' }
    if (-not $Prompt) { return }

    $map = @{}
    $ctx = ''
    if ($IncludeFleet) {
        $store = Read-VmmStore
        $lines = foreach ($h in $store.Hosts) {
            $done = @($h.Steps.PSObject.Properties | Where-Object { $_.Value.Status -in 'Success', 'NotNeeded' } | ForEach-Object { $_.Name }) -join ','
            $blk = @($h.Blockers | Where-Object { -not $_.Resolved } | ForEach-Object { "$($_.Step): $($_.Summary)" }) -join '; '
            "$($h.Name) platform=$($h.Platform) health=$($h.Health) done=[$done] blockers=[$blk]"
        }
        $w = Get-VmmTimeWindow
        $ctx = "Time: $($w.ZoneTime.ToString('ddd HH:mm')) $($w.ZoneLabel), changes allowed now: $($w.ChangesAllowed).`n" + ($lines -join "`n")
    }
    $safeQ = ConvertTo-VmmAiSafeText -Text $Prompt -Map $map
    $safeC = ConvertTo-VmmAiSafeText -Text $ctx -Map $safeQ.Map

    $system = 'You assist a Windows server administrator doing in-place OS upgrades with a PowerShell tool (vmm). ' +
        'Steps per host: Precheck, Stage (copy to C:\Temp), PreSnapshot, ExpandDisk, Upgrade, Verify. Business hours (Mon-Fri 08:00-17:00 Lisbon) allow only checks and staging. ' +
        'Be concise and specific. You cannot run commands; say exactly what the admin should check or do. Never ask for passwords. Host names are aliases.'
    $msgs = @(@{ role = 'system'; content = $system })
    if ($safeC.Text) { $msgs += @{ role = 'user'; content = "Context:`n$($safeC.Text)" } }
    $msgs += @{ role = 'user'; content = $safeQ.Text }

    if ((Get-VmmSetting 'Ai.ConfirmEachSend' -Default $true) -and -not $Force) {
        Write-VmmLog "This text goes to the AI provider '$((Get-VmmSetting 'Ai.Provider' -Default 'None'))':" -Level Info
        Write-VmmColor ($safeQ.Text) -Role Text
        if ($safeC.Text) { Write-VmmColor $safeC.Text -Role Muted }
        if ((Read-VmmPrompt 'Send it? (y/N)') -notmatch '^[yY]') { Write-VmmLog 'Not sent.' -Level Muted; return }
    }
    $answer = Invoke-VmmAiChat -Messages $msgs
    foreach ($k in $safeC.Map.Keys) { $answer = $answer -replace ('\b' + $safeC.Map[$k] + '\b'), $k }
    Write-VmmLog 'Assistant (advisory - verify before acting):' -Level Info
    Write-Host $answer
}
