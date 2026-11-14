<!-- SUMMARY: VmMaintenance optional AI assistant: Microsoft account/Copilot answer, providers, setup, data sent, access request text, future MCP. SECTIONS: Can my Microsoft account / C:8-20 | Setup:21-39 | What is sent and what is not:40-48 | Access request copy fill in :49-73 | Future MCP with your work AI:74-87 -->
# AI assistant (optional)

Off by default (`Features.Ai = $false`). When on, it is **advisory only**: it explains an error,
suggests the next step, or drafts wording for a manager report. It cannot run commands, change
files or see credentials.

## Can my Microsoft account / Copilot power it?

| Option | Works? | How |
|---|---|---|
| Consumer Microsoft Copilot (personal Microsoft account) | No | There is no API a script can call. |
| Microsoft 365 Copilot (work licence) | Not directly | No general chat API for scripts; reachable later through a Copilot Studio agent (see Future). |
| **Azure OpenAI / Azure AI Foundry in your work tenant** | **Yes** | `Ai.Provider = AzureOpenAI`. You sign in with your work account (`vmm azure`); the tool gets an Entra ID token from Az.Accounts. No API key is stored or typed. |
| **Microsoft Foundry Local on the laptop** | **Yes** | `Ai.Provider = Local`. Runs Microsoft models (Phi family) on the laptop; nothing leaves it. |
| Ollama / LM Studio on the laptop | Yes | Same `Local` provider (OpenAI-compatible endpoint on localhost). |

Laptop hardware note: a local model needs RAM and ideally a GPU/NPU. Small models
(`phi-4-mini`, about 4 GB) run on CPU, slowly.

## Setup

Local (Foundry Local):

```powershell
winget install Microsoft.FoundryLocal
foundry model run phi-4-mini         # downloads once, starts the service
foundry service status               # shows the port, e.g. http://localhost:5273
vmm setup -Page Ai                    # Features.Ai = true, Provider = Local, Endpoint = http://localhost:5273/v1
```

Azure OpenAI (work account):

```powershell
vmm setup -Page Ai                    # Provider = AzureOpenAI, Endpoint, Deployment
vmm azure                             # sign in with your work account
vmm ai -Prompt 'Explain: The WinRM client cannot process the request...'
```

## What is sent, and what is not

1. Your question and, with `-IncludeFleet`, a short fleet summary (counts, step states, open blockers).
2. Before sending: passwords/tokens, IPs, UNC paths, e-mail addresses, `DOMAIN\user` accounts and your
   user name are masked; host names become `HOST01`, `HOST02`... (`Ai.SendHostNames = $false`).
3. With `Ai.ConfirmEachSend = $true` (default) you see the exact text and must type `y`.
4. Nothing is stored. Real names are restored only in the answer shown on your screen.
5. `Local` refuses any endpoint that is not on the laptop (loopback only).

## Access request (copy, fill in, send to your manager)

```
Subject: Access request - Azure OpenAI for the server maintenance tool

Hello <manager>,

For the in-place upgrade work I use a PowerShell tool on my laptop. I would like to use our
organisation's Azure OpenAI service as an optional helper (explaining errors, drafting reports).

What I need:
  - Role "Cognitive Services OpenAI User" for my account on the Azure OpenAI resource <resource name>
    (or a new resource in an approved subscription and region).
  - A chat model deployment (for example gpt-4o-mini) and its deployment name.
  - Confirmation that this use complies with our AI policy.

How it is used:
  - Sign-in with my work account (Entra ID); no API keys.
  - Host names, IPs, accounts and secrets are masked before sending; I confirm every request.
  - Advisory only: the tool cannot run commands from the model's answers.

Thank you,
<name>
```

## Future: MCP with your work AI model

Not built yet. The plan:

- An MCP server started by `vmm mcp` (stdio), exposing an allow-list of tools: `get_fleet_status`,
  `explain_host`, `get_time_window`, `draft_blocker_report`, `propose_setting_change`.
- Read tools return the same sanitized data as the assistant. Write tools only *propose*: the change
  appears in the console as a diff and is applied after you confirm, through `Set-VmmSetting`
  (which already refuses credential-like keys and keeps a backup).
- No tool can touch hosts, Azure resources, credentials or files outside the vmm config and reports.
- Client: a Copilot Studio or Azure AI Foundry agent your organisation approves, or a local client,
  signed in with your work account.

_Last updated: 2026-11-14 03:34 UTC_
