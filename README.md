# ask-copilot

[![CI](https://github.com/emilywilder/ask-copilot/actions/workflows/ci.yml/badge.svg)](https://github.com/emilywilder/ask-copilot/actions/workflows/ci.yml)

Ask GitHub Copilot a question from the terminal, with Copilot locked down so it can only answer.

`ask-copilot.ps1` is a single PowerShell 7 script that runs the [GitHub Copilot CLI](https://github.com/github/copilot-cli)
in one-shot prompt mode. Copilot gets no tools, no access to your files, and the token is never written to disk.

```powershell
ask-copilot how do I reverse a list in python
git diff | ask-copilot review this diff
ask-copilot -Glow off explain git rebase | Set-Content rebase.md
```

## What it locks down

- **No tools.** Shell, file read, file write, URL fetch, memory and the GitHub MCP server are all denied
  (`--deny-tool=shell,write,read,url,memory,github`). Custom instructions (`AGENTS.md` etc.) are not loaded
  and Copilot cannot stop to ask questions (`--no-ask-user`).
- **No filesystem.** Copilot runs in a fresh, empty working directory with a fresh, empty `COPILOT_HOME`,
  so it cannot see your files, settings, MCP servers, plugins or skills. Both are deleted when the script exits.
- **No permission overrides.** Every inherited `COPILOT_*` and `GITHUB_COPILOT_*` variable (for example
  `COPILOT_ALLOW_ALL`), plus `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN` and
  `GH_HOST`, is removed from Copilot's environment.
- **Extra hardening when available.** `--disable-builtin-mcps`, `--no-auto-update`, `--disable-client-telemetry`
  and `--no-color` are added if your Copilot CLI version supports them. The mandatory controls above are always
  passed; if the CLI rejects them, the script fails rather than running unprotected.
- **Safe launching on Windows.** Only a native `copilot.exe` is started, never an npm `.cmd`/`.bat` shim, because
  cmd.exe would re-parse the question and characters like `&`, `|` or `>` could run commands.

Only text you pass on the command line or pipe in is sent to Copilot.

## Requirements

- [PowerShell 7.2+](https://github.com/PowerShell/PowerShell)
- The native GitHub Copilot CLI: `winget install GitHub.Copilot`
- A GitHub account with Copilot access
- Optional: [1Password CLI](https://developer.1password.com/docs/cli/) (`winget install AgileBits.1Password.CLI`)
  for reading the token from 1Password
- Optional: [glow](https://github.com/charmbracelet/glow) for rendered Markdown in the terminal

## Setup

### 1. Create a fine-grained token

Create a token at <https://github.com/settings/personal-access-tokens/new>:

| Setting           | Value                                   |
| ----------------- | --------------------------------------- |
| Resource owner    | Your personal account                   |
| Repository access | Public repositories (read-only)         |
| Permissions       | Account → **Copilot Requests** only     |
| Expiration        | As short as you can tolerate            |

Classic `ghp_` tokens are refused: Copilot CLI rejects them and they grant far more access than needed.
`copilot login` is never used, because it saves the token.

### 2. Choose where the token comes from

The token is held as a `SecureString` and only placed in the Copilot child process's environment. It never
goes into your PowerShell session's `$env:`, onto a command line, or onto disk.

**1Password (recommended).** Turn on CLI integration in the 1Password desktop app so `op` unlocks with
Windows Hello and keeps no session token on disk. Then set the secret reference once in your profile
(the reference itself is not a secret):

```powershell
$env:ASK_COPILOT_OP_REF = 'op://Private/GitHub Copilot PAT/credential'
```

or pass it per call with `-OpReference`.

**SecretManagement.** Use `-SecretName` (and optionally `-Vault`) to read the token from a
[SecretManagement](https://github.com/PowerShell/SecretManagement) vault such as Azure Key Vault or Bitwarden.
The local `Microsoft.PowerShell.SecretStore` vault is refused because it saves secrets to a file on this machine.
`-SecretName` takes precedence over `ASK_COPILOT_OP_REF`, and can't be combined with `-OpReference`.

**Prompt.** With neither option, you are asked to paste the token at a masked prompt on each run.

`op run` is not supported: the script strips environment variables from Copilot's environment, which would
remove the one `op run` injects.

### 3. Download and verify

Download `ask-copilot.ps1` and `ask-copilot.ps1.sha256` from the
[latest release](https://github.com/emilywilder/ask-copilot/releases/latest). Every release is built by
GitHub Actions with a signed build-provenance attestation, so you can check the script came from this
repository's CI:

```powershell
gh attestation verify ask-copilot.ps1 --repo emilywilder/ask-copilot
```

or compare the checksum:

```powershell
(Get-FileHash ask-copilot.ps1 -Algorithm SHA256).Hash -eq (Get-Content ask-copilot.ps1.sha256).Split(' ')[0]
```

### 4. Put it on your PATH

Put `ask-copilot.ps1` in a directory on your `PATH`, or add an alias to your profile:

```powershell
Set-Alias ask-copilot C:\path\to\ask-copilot.ps1
```

## Usage

```text
ask-copilot [-Question] <words...> [-Model <name>] [-OpReference <op://...>] [-Glow auto|on|off] [-Help]
ask-copilot [-Question] <words...> [-Model <name>] -SecretName <name> [-Vault <name>] [-Glow auto|on|off] [-Help]
```

Every word after the script name is joined into one question, so quotes are optional (but still useful
for characters PowerShell treats specially). With no question and no piped input, you are prompted for one.

Add `-Verbose` to see each step: which Copilot CLI and flags are used, where the token comes from, which
variables are removed from Copilot's environment, and whether glow is used. `-Debug` also shows Copilot's
arguments, with the prompt shown only by length. The token never appears in either.

| Parameter      | Description                                                                                   |
| -------------- | --------------------------------------------------------------------------------------------- |
| `-Question`    | The question.                                                                                 |
| `-Model`       | Model name, e.g. `claude-sonnet-4.5` or `gpt-5`. Defaults to the Copilot CLI default.         |
| `-OpReference` | 1Password secret reference for the token. Defaults to `$env:ASK_COPILOT_OP_REF`.              |
| `-SecretName`  | SecretManagement secret holding the token.                                                    |
| `-Vault`       | SecretManagement vault for `-SecretName`. Defaults to your default vault.                     |
| `-Glow`        | `auto` (default), `on` or `off`. Defaults to `$env:ASK_COPILOT_GLOW` if set.                  |
| `-Help`        | Show detailed help. Also `-h`, or `--help` / `/?` as the only argument.                      |

### Piped input

Text piped into the script is added under the question as context:

```powershell
Get-Content build.log | ask-copilot why did this fail
git diff --staged | ask-copilot -Model gpt-5 write a commit message for this
```

### Output

Answers are always GitHub-flavored Markdown with fenced code blocks. Output is written to the pipeline line by
line as it arrives, so it can be piped, redirected or captured:

```powershell
ask-copilot explain git rebase | Set-Content rebase.md
$answer = ask-copilot what is a monad
```

Copilot's errors go to the console (stderr), and the script exits with Copilot's exit code.

While Copilot is thinking, a progress bar ("Asking Copilot – Waiting for the answer (3s)") shows the elapsed time
and disappears as soon as the answer starts, or once the whole answer is in when glow renders it. It is drawn by
PowerShell, never written to the output, and can be turned off with `$ProgressPreference = 'SilentlyContinue'`.

### glow

| Mode   | Behaviour                                                                                         |
| ------ | ------------------------------------------------------------------------------------------------- |
| `auto` | Render with glow only when glow is installed and output goes straight to the terminal. Anything piped, redirected, assigned or wrapped in `( )` gets raw Markdown. |
| `on`   | Always render with glow on the terminal. glow draws directly on the console, so nothing goes down the pipe. |
| `off`  | Never use glow.                                                                                   |

When glow is used, the answer appears once Copilot finishes rather than streaming. If glow fails, the raw
Markdown is shown instead.

## Examples

```powershell
ask-copilot how do I reverse a list in python
git diff | ask-copilot -Model gpt-5 review this diff
ask-copilot -Glow off explain git rebase | Set-Content rebase.md
ask-copilot -OpReference "op://Private/GitHub Copilot PAT/credential" what is a monad
ask-copilot -SecretName CopilotToken -Vault AzKV "what is a monad"
ask-copilot --help
```

## Running the tests

The tests use [Pester](https://pester.dev) 5 or later and replace `copilot`, `op` and `glow` with stubs, so
they need neither a GitHub token nor network access:

```powershell
Invoke-Pester ./tests
```

On Windows the stubs are compiled with the .NET Framework C# compiler that ships with Windows. Each test
runs the script in a fresh `pwsh` with its own `PATH`, `TEMP` and environment.

## CI and releases

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push and pull request:

- **Lint:** PSScriptAnalyzer with [`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1), which
  lists the rules that are excluded and why.
- **Test:** the Pester suite on Windows and Ubuntu; JUnit results are uploaded as artifacts.
- **Release:** pushing a `v*` tag (for example `git tag v1.0.0 && git push origin v1.0.0`) runs lint and
  tests, then publishes a GitHub release with `ask-copilot.ps1`, its SHA-256 checksum, generated release
  notes and a build-provenance attestation.

Actions are pinned to commit SHAs and kept current by Dependabot. The workflow token is read-only except
in the release job.

## License

[MIT](LICENSE)
