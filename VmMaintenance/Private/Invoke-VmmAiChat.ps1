function Invoke-VmmAiChat {
    # Sends chat messages to the configured provider and returns the answer text.
    #   Local       OpenAI-compatible server on THIS laptop (Microsoft Foundry Local, Ollama, LM Studio).
    #               [SEC] endpoint must be loopback, so nothing leaves the laptop.
    #   AzureOpenAI Azure OpenAI / Azure AI Foundry deployment in your work tenant, signed in with your
    #               work account (Entra ID token from Az.Accounts). [SEC] no API key is stored or read.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Messages)
    $prov = Get-VmmSetting 'Ai.Provider' -Default 'None'
    $timeout = [int](Get-VmmSetting 'Ai.TimeoutSeconds' -Default 120)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    switch ($prov) {
        'Local' {
            $ep = (Get-VmmSetting 'Ai.Endpoint' -Default 'http://localhost:5273/v1').TrimEnd('/')
            $u = $null
            if (-not [Uri]::TryCreate($ep, [UriKind]::Absolute, [ref]$u) -or -not $u.IsLoopback) {
                throw (New-VmmErrorRecord -Activity 'Local AI endpoint is not on this laptop.' -Target $ep `
                    -Cause 'Provider Local only talks to localhost, so fleet data never leaves the machine.' `
                    -Fix 'Set Ai.Endpoint to the local server, e.g. http://localhost:5273/v1 (Foundry Local: run "foundry service status" for the port) or http://localhost:11434/v1 (Ollama). For a cloud model use Provider AzureOpenAI.' `
                    -Category SecurityError -ErrorId 'VmmAiNotLocal')
            }
            $body = @{ model = (Get-VmmSetting 'Ai.Model' -Default 'phi-4-mini'); messages = $Messages; temperature = 0.2 } | ConvertTo-Json -Depth 6
            try { $r = Invoke-RestMethod -Method Post -Uri "$ep/chat/completions" -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec $timeout }
            catch {
                throw (New-VmmErrorRecord -Activity 'Local AI model did not answer.' -Target $ep -Exception $_.Exception `
                    -Cause 'The local model server is not running, uses another port, or the model name is wrong.' `
                    -Fix 'Foundry Local: "foundry model run <model>" then "foundry service status". Ollama: "ollama serve" and "ollama list". Then set Ai.Endpoint / Ai.Model.' `
                    -Category ConnectionError -ErrorId 'VmmAiLocal')
            }
        }
        'AzureOpenAI' {
            $ep = (Get-VmmSetting 'Ai.Endpoint' -Required).TrimEnd('/')
            if ($ep -notmatch '^https://') { throw (New-VmmErrorRecord -Activity 'Azure OpenAI endpoint must use https.' -Target $ep -Category SecurityError -ErrorId 'VmmAiHttps') }
            $dep = Get-VmmSetting 'Ai.Deployment' -Required
            $ver = Get-VmmSetting 'Ai.ApiVersion' -Default '2024-10-21'
            Assert-VmmModule -Name 'Az.Accounts'
            if (-not (Get-AzContext -ErrorAction SilentlyContinue)) { Connect-VmmAzure }
            $plain = $null
            try {
                $tok = Get-AzAccessToken -ResourceUrl 'https://cognitiveservices.azure.com' -ErrorAction Stop
                if ($tok.Token -is [securestring]) {
                    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($tok.Token)
                    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
                } else { $plain = $tok.Token }
            } catch {
                throw (New-VmmErrorRecord -Activity 'Could not get a work-account token for Azure OpenAI.' -Exception $_.Exception `
                    -Fix 'Sign in with vmm azure. Your account needs the "Cognitive Services OpenAI User" role on the Azure OpenAI resource (see docs/AI.md for the request text).' `
                    -Category AuthenticationError -ErrorId 'VmmAiToken')
            }
            $body = @{ messages = $Messages; temperature = 0.2 } | ConvertTo-Json -Depth 6
            try {
                $r = Invoke-RestMethod -Method Post -Uri "$ep/openai/deployments/$dep/chat/completions?api-version=$ver" `
                    -Headers @{ Authorization = "Bearer $plain" } -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec $timeout
            } catch {
                throw (New-VmmErrorRecord -Activity 'Azure OpenAI request failed.' -Target "$dep" -Exception $_.Exception `
                    -Cause '401/403: missing role or the resource does not allow Entra ID auth. 404: wrong deployment name or API version. 429: quota.' `
                    -Fix 'Check Ai.Endpoint, Ai.Deployment and Ai.ApiVersion, and the role assignment (docs/AI.md).' -Category ConnectionError -ErrorId 'VmmAiAzure')
            } finally { $plain = $null }
        }
        default {
            throw (New-VmmErrorRecord -Activity 'No AI provider configured.' -Fix 'Set Features.Ai = $true and Ai.Provider = Local or AzureOpenAI (Settings or vmm setup). See docs/AI.md.' -Category NotEnabled -ErrorId 'VmmAiOff')
        }
    }
    $answer = $r.choices[0].message.content
    if (-not $answer) { throw (New-VmmErrorRecord -Activity 'The AI model returned an empty answer.' -Category InvalidResult -ErrorId 'VmmAiEmpty') }
    "$answer"
}
