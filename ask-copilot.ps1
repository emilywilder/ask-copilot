#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
    Ask GitHub Copilot a question from the terminal. Copilot gets no tools and no credentials touch disk.

.DESCRIPTION
    Runs the GitHub Copilot CLI in one-shot prompt mode, locked down so that it can only answer:

      * No tools: shell, file read, file write, URL fetch, memory and the GitHub MCP server
        are all denied (--deny-tool). Custom instructions (AGENTS.md etc.) are not loaded.
      * No filesystem: Copilot runs in a fresh, empty working directory with a fresh, empty
        COPILOT_HOME, so it cannot see your files, settings, MCP servers, plugins or skills.
        Both directories are deleted when the script exits.
      * No permission overrides: every inherited COPILOT_* variable (e.g. COPILOT_ALLOW_ALL)
        and every other GitHub token variable is removed from Copilot's environment.

    Authentication uses a fine-grained personal access token with only the "Copilot Requests"
    account permission. The token is never written to disk:
      * By default you paste it at a masked prompt on each run (kept as a SecureString).
      * Or use -OpReference to read it from 1Password with the `op` CLI (op://vault/item/field).
        With the 1Password desktop app's CLI integration on, op unlocks via Windows Hello and
        keeps no session token on disk.
      * Or use -SecretName to pull it from a PowerShell SecretManagement vault. Use a remote
        vault (e.g. Azure Key Vault, 1Password, Bitwarden). The local SecretStore vault is
        refused because it saves secrets to a file on this machine.
    The token goes only into the Copilot child process's environment, never into this
    PowerShell session's environment, the command line, or `copilot login` (which would save it).

    Create the token at https://github.com/settings/personal-access-tokens/new :
      Resource owner: your personal account
      Repository access: Public repositories (read-only)
      Permissions > Account > Copilot Requests
      Expiration: as short as you can tolerate

.PARAMETER Question
    The question. Every word after the script name is joined into one question, so quotes are optional.

.PARAMETER InputObject
    Text piped in, which is added under the question as context (e.g. Get-Content log.txt | ask-copilot why did this fail).
    Only the text you pipe is sent; Copilot still cannot open files itself.

.PARAMETER Model
    Optional model name, e.g. claude-sonnet-4.5 or gpt-5. Defaults to the Copilot CLI default.

.PARAMETER OpReference
    1Password secret reference for the token, e.g. "op://Private/GitHub Copilot PAT/credential".
    Can also be set once in your profile via $env:ASK_COPILOT_OP_REF (the reference is not a secret).

.PARAMETER SecretName
    Name of a SecretManagement secret holding the token. If omitted, you are prompted for it.

.PARAMETER Vault
    SecretManagement vault to read -SecretName from. Defaults to your default vault.

.EXAMPLE
    ask-copilot how do I reverse a list in python

.EXAMPLE
    git diff | ask-copilot -Model gpt-5 review this diff

.EXAMPLE
    ask-copilot -OpReference "op://Private/GitHub Copilot PAT/credential" what is a monad

.EXAMPLE
    ask-copilot -SecretName CopilotToken -Vault AzKV "what is a monad"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]] $Question,

    [Parameter(ValueFromPipeline)]
    [string] $InputObject,

    [string] $Model,

    [string] $OpReference = $env:ASK_COPILOT_OP_REF,

    [string] $SecretName,

    [string] $Vault
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $piped = [System.Collections.Generic.List[string]]::new()

    function Resolve-CopilotExecutable {
        $candidates = @(Get-Command -Name copilot -CommandType Application -All -ErrorAction SilentlyContinue)
        if (-not $candidates) {
            throw 'GitHub Copilot CLI not found on PATH. Install it with: winget install GitHub.Copilot'
        }
        if (-not $IsWindows) { return $candidates[0].Source }

        # On Windows, only launch a real .exe. A .cmd/.bat shim (npm) goes through cmd.exe, which
        # re-parses arguments and would let characters like & | > in the question run as commands.
        $exe = $candidates | Where-Object { $_.Extension -eq '.exe' } | Select-Object -First 1
        if ($exe) { return $exe.Source }

        foreach ($shim in $candidates) {
            $pkgDir = Join-Path (Split-Path $shim.Source) 'node_modules\@github'
            if (Test-Path $pkgDir) {
                $found = Get-ChildItem -Path $pkgDir -Filter 'copilot.exe' -Recurse -File -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($found) { return $found.FullName }
            }
        }
        throw ("Only a script shim for Copilot CLI was found ($($candidates[0].Source)). " +
               'It is not used because cmd.exe would re-interpret the question text. ' +
               'Install the native build instead: winget install GitHub.Copilot')
    }

    function Get-CopilotToken {
        if ($OpReference -and $SecretName) { throw 'Use either -OpReference or -SecretName, not both.' }
        if ($OpReference) {
            if (-not $OpReference.StartsWith('op://')) { throw "-OpReference must look like op://vault/item/field." }
            $op = Get-Command -Name op -CommandType Application -ErrorAction SilentlyContinue |
                Where-Object { -not $IsWindows -or $_.Extension -eq '.exe' } | Select-Object -First 1
            if (-not $op) { throw '1Password CLI (op) not found on PATH. Install it with: winget install AgileBits.1Password.CLI' }
            $value = & $op.Source read --no-newline -- $OpReference
            if ($LASTEXITCODE -ne 0 -or -not $value) { throw "op could not read $OpReference (exit $LASTEXITCODE)." }
            $secure = ConvertTo-SecureString -String ([string]$value) -AsPlainText -Force
            $value = $null
            return $secure
        }
        if ($SecretName) {
            Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
            $vaultInfo = if ($Vault) { Get-SecretVault -Name $Vault } else {
                Get-SecretVault | Where-Object IsDefault | Select-Object -First 1
            }
            if (-not $vaultInfo) { throw 'No SecretManagement vault specified and no default vault is registered.' }
            if ($vaultInfo.ModuleName -eq 'Microsoft.PowerShell.SecretStore') {
                throw "Vault '$($vaultInfo.Name)' is a local SecretStore, which saves secrets to a file on this machine. Use a remote vault or omit -SecretName to be prompted."
            }
            $secret = Get-Secret -Name $SecretName -Vault $vaultInfo.Name
            if ($secret -is [pscredential]) { $secret = $secret.Password }
            if ($secret -is [string]) { $secret = ConvertTo-SecureString -String $secret -AsPlainText -Force }
            if ($secret -isnot [securestring]) { throw "Secret '$SecretName' is not a string, SecureString or PSCredential." }
            return $secret
        }
        $secure = Read-Host -Prompt 'GitHub fine-grained token (Copilot Requests permission)' -AsSecureString
        if ($secure.Length -eq 0) { throw 'No token entered.' }
        return $secure
    }

    function ConvertFrom-SecureToken([securestring] $Secure) {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}

process {
    if ($null -ne $InputObject) { $piped.Add($InputObject) }
}

end {
    $q = (@($Question) -join ' ').Trim()
    if (-not $q -and $piped.Count -eq 0) {
        $q = (Read-Host -Prompt 'Question').Trim()
    }
    if (-not $q -and $piped.Count -eq 0) { throw 'No question given.' }

    $prompt = if ($piped.Count -gt 0) {
        $context = $piped -join [Environment]::NewLine
        if ($q) { "$q$([Environment]::NewLine)$([Environment]::NewLine)$context" } else { $context }
    } else { $q }

    $exe = Resolve-CopilotExecutable

    # Probe for optional hardening flags so the script keeps working across CLI versions.
    $help = (& $exe --help 2>&1 | Out-String)
    $hasFlag = { param($f) $help -match "(?<![\w-])$([regex]::Escape($f))(?![\w-])" }

    $cliArgs = [System.Collections.Generic.List[string]]::new()
    # Use the --prompt=VALUE form so a question that starts with '-' can't be read as a flag.
    if (& $hasFlag '--prompt') { $cliArgs.Add("--prompt=$prompt") }
    else { $cliArgs.Add('-p'); $cliArgs.Add($(if ($prompt.StartsWith('-')) { " $prompt" } else { $prompt })) }
    $cliArgs.Add('--silent')
    $cliArgs.Add('--no-ask-user')
    $cliArgs.Add('--no-custom-instructions')
    $cliArgs.Add('--deny-tool=shell,write,read,url,memory,github')
    foreach ($f in '--disable-builtin-mcps', '--no-auto-update', '--disable-client-telemetry') {
        if (& $hasFlag $f) { $cliArgs.Add($f) }
    }
    if ($Model) { $cliArgs.Add("--model=$Model") }

    $root = Join-Path ([IO.Path]::GetTempPath()) ("ask-copilot-" + [guid]::NewGuid().ToString('N'))
    $copilotHome = Join-Path $root 'home'
    $workDir = Join-Path $root 'work'
    $proc = $null
    $token = $null
    try {
        $secureToken = Get-CopilotToken
        $token = ConvertFrom-SecureToken $secureToken
        if ($token.StartsWith('ghp_')) {
            throw 'Classic PATs (ghp_) are rejected by Copilot CLI and grant far more access than needed. Use a fine-grained token with only Copilot Requests.'
        }
        if (-not ($token.StartsWith('github_pat_') -or $token.StartsWith('ghu_') -or $token.StartsWith('gho_'))) {
            Write-Warning 'Token does not look like a GitHub fine-grained PAT (github_pat_...). Trying anyway.'
        }

        $null = New-Item -ItemType Directory -Path $copilotHome, $workDir -Force

        $psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
        foreach ($a in $cliArgs) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.WorkingDirectory = $workDir

        # Strip anything that could grant permissions, change providers or supply another credential.
        $strip = @($psi.Environment.Keys | Where-Object {
            $_ -like 'COPILOT_*' -or $_ -like 'GITHUB_COPILOT_*' -or
            $_ -in 'GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN', 'GH_HOST'
        })
        foreach ($k in $strip) { [void]$psi.Environment.Remove($k) }

        $psi.Environment['COPILOT_HOME'] = $copilotHome
        $psi.Environment['COPILOT_AUTO_UPDATE'] = 'false'
        $psi.Environment['COPILOT_GITHUB_TOKEN'] = $token

        $proc = [System.Diagnostics.Process]::Start($psi)
        $psi.Environment['COPILOT_GITHUB_TOKEN'] = $null
        $token = $null
        $proc.WaitForExit()
        $global:LASTEXITCODE = $proc.ExitCode
        if ($proc.ExitCode -ne 0) { exit $proc.ExitCode }
    }
    finally {
        $token = $null
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill($true) } catch { } }
        if ($proc) { $proc.Dispose() }
        if (Test-Path -LiteralPath $root) {
            for ($i = 0; $i -lt 5; $i++) {
                try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop; break }
                catch { Start-Sleep -Milliseconds 200 }
            }
        }
    }
}
