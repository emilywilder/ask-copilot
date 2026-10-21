# Stand-in for copilot, op and glow in the tests. The Windows launcher (launcher.cs) or the shell
# wrapper written by helpers.ps1 passes the role as the only argument and the real arguments in
# STUB_ARGS (base64 of NUL-terminated UTF-8 strings), so pwsh never re-parses them.
# Each run writes what it received to $env:STUB_LOG_DIR/<role>.json.
param(
    [Parameter(Mandatory)]
    [ValidateSet('copilot', 'op', 'glow')]
    [string] $Role
)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$stdout = [System.IO.StreamWriter]::new([Console]::OpenStandardOutput(), $utf8)
$stdout.AutoFlush = $true

$decoded = $utf8.GetString([Convert]::FromBase64String("$env:STUB_ARGS"))
$stubArgs = @(if ($decoded) { $decoded.Split([char]0) | Select-Object -SkipLast 1 })

function Write-StubLog([System.Collections.IDictionary] $Entry) {
    $Entry['args'] = $stubArgs
    $path = Join-Path $env:STUB_LOG_DIR "$Role.json"
    [System.IO.File]::WriteAllText($path, ($Entry | ConvertTo-Json -Depth 5), $utf8)
}

function Get-StubExitCode([string] $Value) {
    if ($Value) { [int]$Value } else { 0 }
}

switch ($Role) {
    'copilot' {
        if ($stubArgs -contains '--help') {
            # STUB_HELP: 'full' (default), 'noprompt' (no --prompt flag) or 'minimal' (no optional flags).
            $flags = @('-p <text>', '--silent', '--no-ask-user', '--no-custom-instructions', '--deny-tool <tools>', '--model <model>')
            if ($env:STUB_HELP -ne 'noprompt') { $flags += '--prompt <text>' }
            if ($env:STUB_HELP -ne 'minimal') {
                $flags += '--disable-builtin-mcps', '--no-auto-update', '--disable-client-telemetry', '--no-color'
            }
            $stdout.WriteLine('Usage: copilot [options]')
            foreach ($f in $flags) { $stdout.WriteLine("  $f") }
            exit 0
        }

        $cwd = (Get-Location).Path
        $envVars = [ordered]@{}
        $all = [Environment]::GetEnvironmentVariables()
        foreach ($k in ($all.Keys | Where-Object { $_ -match '^(COPILOT|GITHUB|GH_)' } | Sort-Object)) { $envVars[$k] = $all[$k] }
        Write-StubLog ([ordered]@{
            cwd = $cwd
            cwdEmpty = -not (Get-ChildItem -LiteralPath $cwd -Force)
            env = $envVars
        })

        if ($env:STUB_HOLD_CWD_SECONDS) {
            # Keep the working directory in use after this stub exits, so it can't be deleted (Windows only).
            # Started through WMI so the holder inherits none of this process's handles, such as stdout.
            $null = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
                CommandLine      = "`"$env:STUB_PWSH`" -NoProfile -NonInteractive -Command Start-Sleep -Seconds $env:STUB_HOLD_CWD_SECONDS"
                CurrentDirectory = $cwd
            }
        }

        # Simulate Copilot thinking before it answers.
        if ($env:STUB_DELAY_MS) { Start-Sleep -Milliseconds ([int]$env:STUB_DELAY_MS) }

        [Console]::Error.WriteLine('stub copilot stderr')
        foreach ($line in '# Answer', '', 'Some **bold** text: naïve ✓', '', '```powershell', 'Get-Date', '```') {
            $stdout.WriteLine($line)
        }
        exit (Get-StubExitCode $env:STUB_EXIT)
    }

    'op' {
        Write-StubLog ([ordered]@{})
        $code = Get-StubExitCode $env:STUB_OP_EXIT
        if ($code -ne 0) {
            [Console]::Error.WriteLine('stub op failure')
            exit $code
        }
        $stdout.Write($(if ($env:STUB_TOKEN) { $env:STUB_TOKEN } else { 'github_pat_TEST0123456789' }))
        exit 0
    }

    'glow' {
        $markdown = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8).ReadToEnd()
        Write-StubLog ([ordered]@{ stdin = $markdown })
        foreach ($line in $markdown -split '\r?\n') { $stdout.WriteLine("GLOW> $line") }
        exit (Get-StubExitCode $env:STUB_GLOW_EXIT)
    }
}
