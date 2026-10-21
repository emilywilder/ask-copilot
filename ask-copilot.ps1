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

    Output is always Markdown. It is written to the pipeline as lines of text, so it can be
    piped, redirected or captured (ask-copilot q | Set-Content answer.md, $x = ask-copilot q).
    When glow (https://github.com/charmbracelet/glow) is installed and the output is going
    straight to the terminal, it is rendered with glow; anything piped, redirected or captured
    always gets the raw Markdown. Control this with -Glow.

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
    With neither -OpReference nor -SecretName, and no ASK_COPILOT_OP_REF, you are prompted for the token.
    Cannot be combined with -SecretName.

.PARAMETER SecretName
    Name of a SecretManagement secret holding the token. Takes precedence over $env:ASK_COPILOT_OP_REF.
    Cannot be combined with -OpReference.

.PARAMETER Vault
    SecretManagement vault to read -SecretName from. Defaults to your default vault. Requires -SecretName.

.PARAMETER Glow
    Render the Markdown answer with glow: auto (default), on or off.
      auto  use glow if it is installed and the output is going straight to the terminal
      on    always render with glow on the terminal, even when piped or captured
            (glow draws directly on the console, so nothing is sent down the pipe)
      off   never use glow; always emit raw Markdown
    Set a default with $env:ASK_COPILOT_GLOW. While glow is used the answer appears when
    Copilot finishes rather than streaming.

.PARAMETER Help
    Show this usage information and exit. Also available as -h, --help or /? (on their own).

.EXAMPLE
    ask-copilot how do I reverse a list in python

.EXAMPLE
    git diff | ask-copilot -Model gpt-5 review this diff

.EXAMPLE
    ask-copilot -Glow off explain git rebase | Set-Content rebase.md

.EXAMPLE
    ask-copilot -OpReference "op://Private/GitHub Copilot PAT/credential" what is a monad

.EXAMPLE
    ask-copilot -SecretName CopilotToken -Vault AzKV "what is a monad"
#>
[CmdletBinding(DefaultParameterSetName = 'OpReference')]
# One parameter set per token source. OpReference (the default) also covers the masked prompt.
# (This comment must not sit directly under the help block, or Get-Help shows it as part of the help.)
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]] $Question,

    [Parameter(ValueFromPipeline)]
    [string] $InputObject,

    [string] $Model,

    [Parameter(ParameterSetName = 'OpReference')]
    [string] $OpReference = $env:ASK_COPILOT_OP_REF,

    [Parameter(Mandatory, ParameterSetName = 'SecretName')]
    [string] $SecretName,

    [Parameter(ParameterSetName = 'SecretName')]
    [string] $Vault,

    # ValidateSet checks -Glow when given; a default taken from ASK_COPILOT_GLOW is checked in begin.
    [ValidateSet('auto', 'on', 'off')]
    [string] $Glow = $(if ($env:ASK_COPILOT_GLOW) { $env:ASK_COPILOT_GLOW } else { 'auto' }),

    [Alias('h', '-help')]
    [switch] $Help
)

begin {
    # Inside PowerShell, "--help" arrives as plain text, so also accept it (or /?) as the only argument.
    if ($Help -or ($Question -and $Question.Count -eq 1 -and $Question[0] -in '--help', '/?')) {
        # Out-String first: help objects emitted from inside a script render blank.
        Get-Help -Name $PSCommandPath -Detailed | Out-String
        exit 0
    }

    # A separate variable: assigning an invalid value back to $Glow would fail its ValidateSet.
    $glowMode = $Glow.Trim().ToLowerInvariant()
    if ($glowMode -notin 'auto', 'on', 'off') { throw "ASK_COPILOT_GLOW must be auto, on or off (got '$($Glow.Trim())')." }
    $invocation = $MyInvocation

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $piped = [System.Collections.Generic.List[string]]::new()

    # ---- Prompt ----------------------------------------------------------------------------

    # Puts any piped context under the question and appends the answer-format instruction.
    function New-Prompt([string] $Text, [string] $Context) {
        $nl = [Environment]::NewLine
        $prompt = if ($Context) {
            if ($Text) { "$Text$nl$nl$Context" } else { $Context }
        } else { $Text }

        $prompt + "$nl$nl---$nl" +
            'Answer from your own knowledge: you have no tools and no access to any files. ' +
            'Format your entire response as GitHub-flavored Markdown. Put all code, commands and ' +
            'file contents in fenced code blocks with a language tag. Do not wrap the whole response in a code block.'
    }

    # ---- glow ------------------------------------------------------------------------------

    # True only when this script is a bare statement whose output goes straight to the host:
    # not piped, not redirected (> file), not assigned ($x = ...), not inside ( ), $( ) or @( ).
    function Test-OutputToTerminal([System.Management.Automation.InvocationInfo] $Invocation) {
        if ([Console]::IsOutputRedirected) { return $false }
        $line = "$($Invocation.Line)"
        $statement = "$($Invocation.Statement)".Trim()
        # pwsh -File ask-copilot.ps1 ... from another shell: no source line, and the console
        # redirect check above already caught "| more" or "> file" in that shell.
        if (-not $line.Trim() -and -not $statement) { return $true }
        if ($Invocation.PipelineLength -gt 1) { return $false }
        if (-not $statement) { return $false }

        $tokens = $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors) { return $false }
        # Find this invocation's command in the line, then look at what contains it.
        $cmd = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.Extent.Text.Trim() -eq $statement
            }, $true) | Select-Object -First 1
        if (-not $cmd) { return $false }
        if ($cmd.Redirections.Count -gt 0) { return $false }
        $pipeline = $cmd.Parent
        if ($pipeline -isnot [System.Management.Automation.Language.PipelineAst] -or $pipeline.PipelineElements.Count -ne 1) { return $false }

        # Walk out to the top level of the line. Output reaches the host only if every enclosing
        # construct passes it straight through: the body of an if, loop, switch or try. $( ) and @( )
        # also hold a statement block but capture it, as do assignments, conditions and script blocks.
        $node = $pipeline
        while ($true) {
            $block = $node.Parent
            if ($block -is [System.Management.Automation.Language.NamedBlockAst]) { return ($null -eq $block.Parent.Parent) }
            if ($block -isnot [System.Management.Automation.Language.StatementBlockAst]) { return $false }
            $owner = $block.Parent
            if ($owner -is [System.Management.Automation.Language.CatchClauseAst]) { $owner = $owner.Parent }
            if ($owner -isnot [System.Management.Automation.Language.IfStatementAst] -and
                $owner -isnot [System.Management.Automation.Language.LoopStatementAst] -and
                $owner -isnot [System.Management.Automation.Language.SwitchStatementAst] -and
                $owner -isnot [System.Management.Automation.Language.TryStatementAst]) { return $false }
            $node = $owner
        }
    }

    function Resolve-Glow {
        $g = Get-Command -Name glow -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($g) { $g.Source }
    }

    # Returns the glow executable to render with, or nothing if the answer should stay raw Markdown.
    function Get-GlowPath([string] $Mode, [System.Management.Automation.InvocationInfo] $Invocation) {
        if ($Mode -eq 'off') { Write-Verbose 'glow: off; emitting raw Markdown.'; return }
        $glowPath = Resolve-Glow
        if (-not $glowPath) {
            if ($Mode -eq 'on') { Write-Warning 'glow not found on PATH; showing raw Markdown.' }
            else { Write-Verbose 'glow: not found on PATH; emitting raw Markdown.' }
            return
        }
        if ($Mode -eq 'auto' -and -not (Test-OutputToTerminal $Invocation)) {
            Write-Verbose 'glow: output is piped, redirected or captured; emitting raw Markdown.'
            return
        }
        Write-Verbose "glow: rendering with $glowPath."
        $glowPath
    }

    # Renders Markdown with glow directly on the console (so glow sees a real terminal).
    # Returns $false if glow failed, so the caller can fall back to raw Markdown.
    function Invoke-Glow([string] $GlowPath, [string] $Markdown) {
        $gsi = [System.Diagnostics.ProcessStartInfo]::new($GlowPath)
        $gsi.ArgumentList.Add('-')
        $gsi.UseShellExecute = $false
        $gsi.RedirectStandardInput = $true
        $gsi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
        $g = [System.Diagnostics.Process]::Start($gsi)
        try {
            $g.StandardInput.Write($Markdown)
            $g.StandardInput.Close()
            $g.WaitForExit()
            return ($g.ExitCode -eq 0)
        }
        finally { $g.Dispose() }
    }

    # ---- Copilot CLI -----------------------------------------------------------------------

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

    # Builds Copilot's command-line arguments. The mandatory lockdown flags are always passed;
    # optional hardening flags are probed for so the script keeps working across CLI versions.
    function New-CopilotArgumentList([string] $Exe, [string] $Prompt, [string] $Model) {
        $cliHelpText = (& $Exe --help 2>&1 | Out-String)
        $hasFlag = { param($f) $cliHelpText -match "(?<![\w-])$([regex]::Escape($f))(?![\w-])" }

        $cliArgs = [System.Collections.Generic.List[string]]::new()
        # Use the --prompt=VALUE form so a question that starts with '-' can't be read as a flag.
        if (& $hasFlag '--prompt') { $cliArgs.Add("--prompt=$Prompt") }
        else {
            Write-Verbose 'This Copilot CLI has no --prompt flag; passing the prompt with -p.'
            $cliArgs.Add('-p'); $cliArgs.Add($(if ($Prompt.StartsWith('-')) { " $Prompt" } else { $Prompt }))
        }
        $cliArgs.Add('--silent')
        $cliArgs.Add('--no-ask-user')
        $cliArgs.Add('--no-custom-instructions')
        $cliArgs.Add('--deny-tool=shell,write,read,url,memory,github')
        $optional = '--disable-builtin-mcps', '--no-auto-update', '--disable-client-telemetry', '--no-color'
        $supported = @($optional | Where-Object { & $hasFlag $_ })
        foreach ($f in $supported) { $cliArgs.Add($f) }
        Write-Verbose "Optional hardening flags passed: $(if ($supported) { $supported -join ', ' } else { 'none' })."
        $unsupported = @($optional | Where-Object { $_ -notin $supported })
        if ($unsupported) { Write-Verbose "Not supported by this Copilot CLI: $($unsupported -join ', ')." }
        if ($Model) { $cliArgs.Add("--model=$Model") }

        # The prompt is shown by length only, to keep the debug line readable.
        $shown = foreach ($a in $cliArgs) { if ($a -in "--prompt=$Prompt", $Prompt, " $Prompt") { "<prompt: $($Prompt.Length) characters>" } else { $a } }
        Write-Debug "Copilot arguments: $($shown -join ' ')"
        $cliArgs
    }

    # Strips anything from Copilot's environment that could grant permissions, change providers
    # or supply another credential, and points it at its own empty home.
    # The token is set separately by the caller so it is never passed as a command argument.
    function Initialize-CopilotEnvironment([System.Diagnostics.ProcessStartInfo] $StartInfo, [string] $CopilotHome) {
        $strip = @($StartInfo.Environment.Keys | Where-Object {
            $_ -like 'COPILOT_*' -or $_ -like 'GITHUB_COPILOT_*' -or
            $_ -in 'GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN', 'GH_HOST'
        })
        foreach ($k in $strip) { [void]$StartInfo.Environment.Remove($k) }
        if ($strip) { Write-Verbose "Removed from Copilot's environment: $(($strip | Sort-Object) -join ', ')." }
        else { Write-Verbose 'No inherited Copilot or GitHub token variables to remove.' }

        $StartInfo.Environment['COPILOT_HOME'] = $CopilotHome
        $StartInfo.Environment['COPILOT_AUTO_UPDATE'] = 'false'
    }

    # Deletes the temporary working directory, retrying briefly while Copilot releases its files.
    function Remove-TempRoot([string] $Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        for ($i = 0; $i -lt 5; $i++) {
            try {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
                Write-Verbose "Deleted the temporary directory $Path."
                return
            }
            catch { Start-Sleep -Milliseconds 200 }
        }
        Write-Warning "Could not delete the temporary directory $Path. It may hold Copilot's files for this session; delete it yourself."
    }

    # ---- Token -----------------------------------------------------------------------------

    function Read-OpToken([string] $Reference) {
        if (-not $Reference.StartsWith('op://')) { throw "-OpReference must look like op://vault/item/field." }
        $op = Get-Command -Name op -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { -not $IsWindows -or $_.Extension -eq '.exe' } | Select-Object -First 1
        if (-not $op) { throw '1Password CLI (op) not found on PATH. Install it with: winget install AgileBits.1Password.CLI' }
        Write-Verbose "Reading the token from 1Password ($Reference) with $($op.Source)."
        $value = & $op.Source read --no-newline -- $Reference
        if ($LASTEXITCODE -ne 0 -or -not $value) { throw "op could not read $Reference (exit $LASTEXITCODE)." }
        $secure = ConvertTo-SecureString -String ([string]$value) -AsPlainText -Force
        $value = $null
        return $secure
    }

    function Get-VaultToken([string] $Name, [string] $VaultName) {
        Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
        $vaultInfo = if ($VaultName) { Get-SecretVault -Name $VaultName } else {
            Get-SecretVault | Where-Object IsDefault | Select-Object -First 1
        }
        if (-not $vaultInfo) { throw 'No SecretManagement vault specified and no default vault is registered.' }
        if ($vaultInfo.ModuleName -eq 'Microsoft.PowerShell.SecretStore') {
            throw "Vault '$($vaultInfo.Name)' is a local SecretStore, which saves secrets to a file on this machine. Use a remote vault or omit -SecretName to be prompted."
        }
        Write-Verbose "Reading secret '$Name' from SecretManagement vault '$($vaultInfo.Name)' ($($vaultInfo.ModuleName))."
        $secret = Get-Secret -Name $Name -Vault $vaultInfo.Name
        if ($secret -is [pscredential]) { $secret = $secret.Password }
        if ($secret -is [string]) { $secret = ConvertTo-SecureString -String $secret -AsPlainText -Force }
        if ($secret -isnot [securestring]) { throw "Secret '$Name' is not a string, SecureString or PSCredential." }
        return $secret
    }

    # $ParameterSet picks the source; parameter binding already rejects -OpReference with -SecretName.
    function Get-CopilotToken([string] $ParameterSet, [string] $OpReference, [string] $SecretName, [string] $Vault) {
        if ($ParameterSet -eq 'SecretName') { return Get-VaultToken $SecretName $Vault }
        if ($OpReference) { return Read-OpToken $OpReference }

        Write-Verbose 'No -OpReference, -SecretName or ASK_COPILOT_OP_REF; prompting for the token.'
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
    $context = ($piped -join [Environment]::NewLine).Trim()
    if (-not $q -and -not $context) {
        $q = (Read-Host -Prompt 'Question').Trim()
    }
    if (-not $q -and -not $context) { throw 'No question given.' }
    $prompt = New-Prompt $q $context
    Write-Verbose "Question: $($q.Length) characters; piped context: $($context.Length) characters."

    $glowPath = Get-GlowPath $glowMode $invocation
    $exe = Resolve-CopilotExecutable
    Write-Verbose "Copilot CLI: $exe"
    $cliArgs = New-CopilotArgumentList $exe $prompt $Model

    $root = Join-Path ([IO.Path]::GetTempPath()) ("ask-copilot-" + [guid]::NewGuid().ToString('N'))
    Write-Verbose "Temporary directory (working directory and COPILOT_HOME): $root"
    $copilotHome = Join-Path $root 'home'
    $workDir = Join-Path $root 'work'
    $proc = $null
    $token = $null
    try {
        $secureToken = Get-CopilotToken -ParameterSet $PSCmdlet.ParameterSetName -OpReference $OpReference -SecretName $SecretName -Vault $Vault
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
        # Capture stdout so the answer goes to the PowerShell pipeline; stderr (errors) still goes to the console.
        $psi.RedirectStandardOutput = $true
        $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        Initialize-CopilotEnvironment $psi $copilotHome
        $psi.Environment['COPILOT_GITHUB_TOKEN'] = $token

        $proc = [System.Diagnostics.Process]::Start($psi)
        $psi.Environment['COPILOT_GITHUB_TOKEN'] = $null
        $token = $null
        Write-Verbose "Started Copilot (process $($proc.Id)) with the token in COPILOT_GITHUB_TOKEN."

        if ($glowPath) {
            # glow needs the whole document, so buffer it, then render. Nothing appears until
            # Copilot finishes, so show progress in the meantime.
            Write-Progress -Activity 'Asking Copilot' -Status 'Waiting for the answer'
            try {
                $markdown = $proc.StandardOutput.ReadToEnd()
                $proc.WaitForExit()
            }
            finally { Write-Progress -Activity 'Asking Copilot' -Completed }
            if ($markdown.Trim()) {
                $rendered = $false
                try { $rendered = Invoke-Glow $glowPath $markdown } catch { Write-Warning "glow failed: $_" }
                if (-not $rendered) { $markdown -split '\r?\n' }
            }
        }
        else {
            # Stream line by line so downstream commands get output as it arrives.
            while ($null -ne ($outLine = $proc.StandardOutput.ReadLine())) { $outLine }
            $proc.WaitForExit()
        }
        Write-Verbose "Copilot exited with code $($proc.ExitCode)."
        $global:LASTEXITCODE = $proc.ExitCode
        if ($proc.ExitCode -ne 0) { exit $proc.ExitCode }
    }
    finally {
        $token = $null
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill($true) } catch { } }
        if ($proc) { $proc.Dispose() }
        Remove-TempRoot $root
    }
}
