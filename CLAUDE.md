# CLAUDE.md

Guidance for Claude when working on this repository.

## Project

`ask-copilot.ps1` is a single PowerShell 7 script that asks GitHub Copilot a question from the terminal
by running the Copilot CLI in one-shot prompt mode, locked down so Copilot can only answer.

It is a CLI tool, not a module: keep the name `ask-copilot`. Where PowerShell's cmdlet guidelines conflict
with how the tool is typed and called (e.g. Verb-Noun naming, SD01/SD02), the CLI's ease of use wins. Follow the
guidelines everywhere else (parameter validation, parameter sets, verbose/debug output, help, helper naming).

## Releasing

The `<#PSScriptInfo#>` block (after the shebang, before `#Requires`) holds the PowerShell Gallery metadata. Its
`.VERSION` must equal the tag without the `v`: the release job fails otherwise. Gallery versions can never be
reused or deleted, so bump `.VERSION` for any change to the published file. The `publish` job runs in the
`psgallery` GitHub environment and reads the Gallery API key from 1Password with `1password/load-secrets-action`,
using a service account (`OP_SERVICE_ACCOUNT_TOKEN` environment secret) and the key's reference
(`PSGALLERY_API_KEY_REF` environment variable). The key is a step output (`export-env: false`), never a job env
var or a GitHub secret. GitHub API calls use the built-in `github.token`, not a stored PAT.

## Hard requirements (do not weaken)

These came from the original request. Every change must keep them true.

1. **Copilot gets no filesystem access and cannot run commands.**
   - `--deny-tool=shell,write,read,url,memory,github`, `--no-custom-instructions`, `--no-ask-user`.
   - Runs in a fresh empty working directory with a fresh empty `COPILOT_HOME`, both deleted in `finally`.
   - Every inherited `COPILOT_*`, `GITHUB_COPILOT_*`, `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`,
     `GITHUB_ENTERPRISE_TOKEN` and `GH_HOST` is removed from the child environment (`COPILOT_ALLOW_ALL` would
     otherwise grant all tools).
   - Optional hardening flags (`--disable-builtin-mcps`, `--no-auto-update`, `--disable-client-telemetry`,
     `--no-color`) are added only if `copilot --help` lists them, so the script survives CLI version changes.
     Mandatory controls are never gated this way: if the CLI rejects them, the script should fail closed.
2. **Most secure authentication available.** A fine-grained PAT with only the "Copilot Requests" account
   permission. Classic `ghp_` tokens are refused. `copilot login` is never used because it always persists the token.
3. **No credentials written to the local filesystem.** The token is held as a SecureString, converted to plain
   text only to set `COPILOT_GITHUB_TOKEN` on the child's `ProcessStartInfo.Environment`, never in this session's
   `$env:`, never on a command line. Each source is a parameter set (`OpReference`, the default, and `SecretName`),
   and `Get-CopilotToken` switches on `$PSCmdlet.ParameterSetName`, so an explicit `-SecretName` wins over
   `ASK_COPILOT_OP_REF`. Sources:
   - `-OpReference` / `$env:ASK_COPILOT_OP_REF` → `op read --no-newline` (1Password CLI with desktop app
     integration; this is what the user actually uses).
   - `-SecretName` / `-Vault` → SecretManagement, refusing the local `Microsoft.PowerShell.SecretStore` vault.
   - Otherwise a masked `Read-Host -AsSecureString` prompt.
   - `op run` is deliberately unsupported (the env stripping would remove its variable).

## Behaviour to preserve

- **Dependency checks first:** the end of `begin` resolves Copilot CLI, glow (`-Glow on` throws if it is missing),
  and reads and checks the token (`Assert-CopilotToken`: refuses `ghp_` and anything not matching
  `^(github_pat_|gho_|ghu_)[A-Za-z0-9_]+$`, case-sensitive). The token source's tool (`op`, SecretManagement) is
  checked before it is used. All of this runs before the question prompt, the `copilot --help` probe and the temp
  directory. The token is never sent to a GitHub API to validate it: plain text only ever goes to the child's
  environment. The SecureString is disposed of in `end`'s `finally`.

- **Verbose/debug output:** `Write-Verbose` reports each step and `Write-Debug` shows Copilot's arguments with the
  prompt replaced by its length. Neither may ever include the token.
- **Waiting feedback:** `Wait-CopilotOutput` awaits an async read of Copilot's stdout in 250 ms steps, updating
  `Write-Progress` with the elapsed seconds: until the first line when streaming, until the whole answer in glow
  mode. The record is completed in `finally` before any output or glow rendering. Use `Write-Progress`, not a
  console spinner (cmdlet guidelines: no `System.Console`, and it must never touch the output).

- **Windows launching:** only start a native `copilot.exe` (or one found under an npm shim's `node_modules\@github`).
  Never launch a `.cmd`/`.bat` shim: cmd.exe re-parses arguments, so `&`, `|`, `>` in a question would run commands.
  Always pass arguments through `ProcessStartInfo.ArgumentList`, and pass the prompt as `--prompt=<text>` so a
  question starting with `-` isn't read as a flag.
- **Markdown output:** an instruction appended to every prompt asks for GitHub-flavored Markdown with fenced code
  blocks and tells Copilot it has no tools or files.
- **Pipeline output:** Copilot's stdout is redirected (UTF-8, no BOM) and streamed line by line to the pipeline;
  stderr stays on the console. Piped input is appended under the question as context.
- **glow:** `-Glow auto|on|off`, default from `$env:ASK_COPILOT_GLOW`, else `auto`.
  - `auto` renders with glow only when output goes straight to the terminal. `Test-OutputToTerminal` parses
    `$MyInvocation.Line` and checks the command is a bare statement: not piped, not redirected, not assigned,
    not inside `( )`/`$( )`/`@( )`. Walking out from the command, every enclosing construct must be the body of an
    `if`/loop/`switch`/`try`, up to the top level of the line; anything else (including script blocks) means raw Markdown. With `pwsh -File` (empty `Line` and `Statement`) it relies on
    `[Console]::IsOutputRedirected`; there `PipelineLength` is 2, so that check must come after the `-File` case.
  - glow is launched with stdin redirected and stdout inherited, so it sees a real terminal. Output is buffered
    for glow (no streaming); if glow fails at render time, the raw Markdown is emitted instead.
- **Help:** `-Help`, `-h`, and `--help` or `/?` as the only argument print `Get-Help -Detailed`.
  `Get-Help ... | Out-String` is required (help objects emitted from inside a script render blank, including via
  `Out-Host`). A question like `what is --help` must still go to Copilot.

## PowerShell gotchas found in this project

- Comment-based help is ignored if it sits directly under another comment line. Keep the blank line between
  `#Requires -Version 7.2` and `<#`.
- The reverse also bites: a `#` comment directly under `#>` is appended to the last help section (it showed up
  under the last example, then broke the last `.LINK`). Keep comments below `[CmdletBinding()]`/`[OutputType()]`.
- Variable names are case-insensitive: any `$help` variable collides with the `-Help` switch. The CLI help
  probe uses `$cliHelpText` for this reason.
- Inside PowerShell, `--help` arrives as a plain string in `$Question`, not as a parameter.
- `@($null).Count` is 1; test `$Question -and $Question.Count -eq 1`.

## Testing

Automated tests: `Invoke-Pester ./tests` (Pester 5+). `tests/stubs/stub.ps1` plays copilot, op and glow; on Windows
`tests/stubs/launcher.cs` is compiled with the .NET Framework `csc.exe` into native `.exe` stand-ins, elsewhere
`tests/helpers.ps1` writes `/bin/sh` wrappers. Terminal (glow auto) cases use a hidden console on Windows and
`script` elsewhere. The non-Windows path has not been run yet.

Manual approach (Linux workspace):

PowerShell, Copilot CLI and 1Password may not be installable in Claude's workspace (npm was blocked), but these work:

- PowerShell: download `powershell-7.4.6-linux-x64.tar.gz` from the PowerShell GitHub releases.
- glow: download `glow_2.0.0_Linux_x86_64.tar.gz` from the charmbracelet/glow GitHub releases.
- Put stub `copilot` and `op` scripts first on PATH. The `copilot` stub answers `--help` with a flag list, logs its
  arguments and environment, and prints sample Markdown. The `op` stub prints a fake `github_pat_...` token.
- Run cases under `script -qc` to get a real TTY, and detect glow by the presence of ANSI escapes. Cover: bare call,
  `$a=1; call`, `| Select-Object`, `$x = call`, `(call).Count`, `> file`, `-Glow off/on`, `ASK_COPILOT_GLOW=off`,
  `pwsh -File` with and without a pipe, glow missing with `-Glow on`, every help form, and parse-check with
  `[Parser]::ParseFile`.
- Also verify the child environment has `COPILOT_ALLOW_ALL` and `GH_TOKEN` stripped and the temp directory is removed.
- Real Copilot and 1Password behaviour can only be checked by the user on Windows; say so when reporting.
