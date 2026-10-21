#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Tests for ask-copilot.ps1. Copilot, op and glow are replaced by stubs (see stubs/stub.ps1), and every
# case runs the script in a fresh pwsh with an isolated PATH, TEMP and environment (see helpers.ps1).
# Run with: Invoke-Pester ./tests

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    $script:CanUseTerminal = Test-TerminalSupported
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    $script:StubTools = Initialize-StubTools
}

AfterAll {
    Remove-StubTools $StubTools
}

Describe 'Script file' {
    It 'parses without errors' {
        $tokens = $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($AskCopilot, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has comment-based help that Get-Help recognises' {
        (Get-Help $AskCopilot).Synopsis | Should -BeLike 'Ask GitHub Copilot a question from the terminal*'
    }
}

Describe 'Help' {
    It 'prints detailed help for <Form> without running Copilot' -ForEach @(
        @{ Form = '-Help' }
        @{ Form = '-h' }
        @{ Form = '--help' }
        @{ Form = '/?' }
    ) {
        $r = Invoke-AskCopilot "& `$S $Form"
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -Match 'Ask GitHub Copilot a question from the terminal'
        $r.Stdout | Should -Match '-OpReference'
        $r.Copilot | Should -BeNullOrEmpty
        $r.Op | Should -BeNullOrEmpty
    }

    It 'sends a question that merely contains --help to Copilot' {
        $r = Invoke-AskCopilot '& $S what is --help'
        $r.ExitCode | Should -Be 0
        Get-CopilotQuestion $r | Should -BeExactly 'what is --help'
    }
}

Describe 'Prompt' {
    It 'joins every word into one question' {
        $r = Invoke-AskCopilot '& $S how do I reverse a list in python'
        Get-CopilotQuestion $r | Should -BeExactly 'how do I reverse a list in python'
    }

    It 'appends the Markdown, no-tools instruction' {
        $r = Invoke-AskCopilot '& $S hi'
        $prompt = Get-CopilotPrompt $r
        $prompt | Should -BeLike "hi$Nl$Nl---$Nl*"
        $prompt | Should -Match 'you have no tools and no access to any files'
        $prompt | Should -Match 'GitHub-flavored Markdown'
        $prompt | Should -Match 'fenced code blocks'
    }

    It 'adds piped input under the question' {
        $r = Invoke-AskCopilot '"line one", "line two" | & $S explain this'
        Get-CopilotQuestion $r | Should -BeExactly "explain this$Nl${Nl}line one${Nl}line two"
    }

    It 'uses piped input alone when there is no question' {
        $r = Invoke-AskCopilot '"just context" | & $S'
        Get-CopilotQuestion $r | Should -BeExactly 'just context'
    }

    It 'ignores empty piped lines at the edges' {
        $r = Invoke-AskCopilot '"", "middle", "" | & $S q'
        Get-CopilotQuestion $r | Should -BeExactly "q$Nl${Nl}middle"
    }

    It 'passes shell metacharacters, quotes and backslashes through unchanged' {
        $question = 'a & b | c > d; "quoted" \"escaped\" C:\dir\ %PATH% $(x)'
        $r = Invoke-AskCopilot "& `$S '$($question.Replace("'", "''"))'"
        Get-CopilotQuestion $r | Should -BeExactly $question
    }

    It 'passes non-ASCII text through unchanged' {
        $r = Invoke-AskCopilot '& $S "naïve café ✓ 日本語"'
        Get-CopilotQuestion $r | Should -BeExactly 'naïve café ✓ 日本語'
    }

    It 'uses the --prompt=<text> form so a question starting with - is not read as a flag' {
        $r = Invoke-AskCopilot '& $S "-v is that a flag"'
        $cliArgs = @($r.Copilot.args)
        $cliArgs[0] | Should -BeLike "--prompt=-v is that a flag$Nl*"
        $cliArgs | Should -Not -Contain '-p'
    }

    It 'falls back to -p with a leading space for a question starting with - when the CLI has no --prompt' {
        $r = Invoke-AskCopilot '& $S "-v is that a flag"' -Env @{ STUB_HELP = 'noprompt' }
        $cliArgs = @($r.Copilot.args)
        $cliArgs[0] | Should -BeExactly '-p'
        $cliArgs[1] | Should -BeLike ' -v is that a flag*'
    }

    It 'falls back to -p without changing an ordinary question when the CLI has no --prompt' {
        $r = Invoke-AskCopilot '& $S hi' -Env @{ STUB_HELP = 'noprompt' }
        $cliArgs = @($r.Copilot.args)
        $cliArgs[0] | Should -BeExactly '-p'
        $cliArgs[1] | Should -BeLike "hi$Nl*"
    }

    It 'passes -Model as --model=<name>' {
        $r = Invoke-AskCopilot '& $S -Model gpt-5 hi'
        @($r.Copilot.args) | Should -Contain '--model=gpt-5'
    }

    It 'does not pass --model by default' {
        $r = Invoke-AskCopilot '& $S hi'
        @($r.Copilot.args) | Where-Object { $_ -like '--model*' } | Should -BeNullOrEmpty
    }

    It 'fails without running Copilot when there is no question and no input' {
        $r = Invoke-AskCopilot '& $S'
        $r.Stdout | Should -Match 'EXCEPTION:'
        $r.Copilot | Should -BeNullOrEmpty
    }
}

Describe 'Lockdown' {
    It 'always passes the mandatory lockdown flags' {
        $r = Invoke-AskCopilot '& $S hi' -Env @{ STUB_HELP = 'minimal' }
        $cliArgs = @($r.Copilot.args)
        $cliArgs | Should -Contain '--silent'
        $cliArgs | Should -Contain '--no-ask-user'
        $cliArgs | Should -Contain '--no-custom-instructions'
        $cliArgs | Should -Contain '--deny-tool=shell,write,read,url,memory,github'
    }

    It 'adds the optional hardening flags when the CLI lists them' {
        $r = Invoke-AskCopilot '& $S hi'
        $cliArgs = @($r.Copilot.args)
        foreach ($f in '--disable-builtin-mcps', '--no-auto-update', '--disable-client-telemetry', '--no-color') {
            $cliArgs | Should -Contain $f
        }
    }

    It 'leaves out optional flags the CLI does not list' {
        $r = Invoke-AskCopilot '& $S hi' -Env @{ STUB_HELP = 'minimal' }
        $cliArgs = @($r.Copilot.args)
        foreach ($f in '--disable-builtin-mcps', '--no-auto-update', '--disable-client-telemetry', '--no-color') {
            $cliArgs | Should -Not -Contain $f
        }
    }

    It 'strips inherited Copilot and GitHub variables and sets only its own' {
        $r = Invoke-AskCopilot '& $S hi'
        $names = @($r.Copilot.env.PSObject.Properties.Name) | Sort-Object
        $names | Should -Be @('COPILOT_AUTO_UPDATE', 'COPILOT_GITHUB_TOKEN', 'COPILOT_HOME')
        $r.Copilot.env.COPILOT_AUTO_UPDATE | Should -BeExactly 'false'
    }

    It 'gives Copilot the token only through COPILOT_GITHUB_TOKEN, never on its command line' {
        $r = Invoke-AskCopilot '& $S hi'
        $r.Copilot.env.COPILOT_GITHUB_TOKEN | Should -BeExactly 'github_pat_TEST0123456789'
        @($r.Copilot.args) | Where-Object { $_ -match 'github_pat_' } | Should -BeNullOrEmpty
    }

    It 'never puts the token in the calling session''s environment' {
        $r = Invoke-AskCopilot '& $S hi | Out-Null; "SESSION_TOKEN=[$env:COPILOT_GITHUB_TOKEN]"'
        $r.Stdout | Should -Match ([regex]::Escape('SESSION_TOKEN=[]'))
    }

    It 'runs Copilot in a fresh, empty working directory with a separate COPILOT_HOME under TEMP' {
        $r = Invoke-AskCopilot '& $S hi'
        $r.Copilot.cwdEmpty | Should -BeTrue
        $r.Copilot.cwd | Should -Match 'ask-copilot-[0-9a-f]{32}[\\/]work$'
        $r.Copilot.env.COPILOT_HOME | Should -Match 'ask-copilot-[0-9a-f]{32}[\\/]home$'
        (Split-Path $r.Copilot.cwd) | Should -Be (Split-Path $r.Copilot.env.COPILOT_HOME)
    }

    It 'deletes its temporary directories after <Case>' -ForEach @(
        @{ Case = 'a successful run'; Env = @{} }
        @{ Case = 'Copilot failing'; Env = @{ STUB_EXIT = '3' } }
        @{ Case = 'a refused token'; Env = @{ STUB_TOKEN = 'ghp_classic' } }
    ) {
        $r = Invoke-AskCopilot '& $S hi' -Env $Env
        $r.LeftoverTempDirs | Should -BeNullOrEmpty
    }

    It 'fails when Copilot CLI is not on PATH' {
        $r = Invoke-AskCopilot '& $S hi' -WithoutCopilot
        $r.Stdout | Should -Match 'EXCEPTION: GitHub Copilot CLI not found on PATH'
        $r.ExitCode | Should -Be 99
    }

    Context 'Windows launching' -Skip:(-not $IsWindows) {
        BeforeAll {
            $script:ShimDir = Join-Path $StubTools.Root ('shim-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $ShimDir
            # If this shim ever ran, cmd.exe would have re-parsed the question.
            Set-Content -LiteralPath (Join-Path $ShimDir 'copilot.cmd') -Value '@echo shim ran> "%STUB_LOG_DIR%\shim-ran.txt"'
        }

        It 'refuses to launch a .cmd shim' {
            $r = Invoke-AskCopilot '& $S hi' -WithoutCopilot -PrependPath $ShimDir
            $r.Stdout | Should -Match 'EXCEPTION: Only a script shim for Copilot CLI was found'
            Join-Path $r.LogDir 'shim-ran.txt' | Should -Not -Exist
            $r.Copilot | Should -BeNullOrEmpty
        }

        It 'launches the native copilot.exe inside an npm package next to the shim' {
            $pkg = Join-Path $ShimDir 'node_modules\@github\copilot-win32-x64'
            $null = New-Item -ItemType Directory -Path $pkg -Force
            Copy-Item $StubTools.Launcher (Join-Path $pkg 'copilot.exe')
            try {
                $r = Invoke-AskCopilot '& $S "a & b"' -WithoutCopilot -PrependPath $ShimDir
                $r.ExitCode | Should -Be 0
                $r.Copilot | Should -Not -BeNullOrEmpty
                Get-CopilotQuestion $r | Should -BeExactly 'a & b'
                Join-Path $r.LogDir 'shim-ran.txt' | Should -Not -Exist
            }
            finally { Remove-Item -LiteralPath (Join-Path $ShimDir 'node_modules') -Recurse -Force }
        }

        It 'prefers a native copilot.exe over a shim earlier on PATH' {
            $r = Invoke-AskCopilot '& $S hi' -PrependPath $ShimDir
            $r.Copilot | Should -Not -BeNullOrEmpty
            Join-Path $r.LogDir 'shim-ran.txt' | Should -Not -Exist
        }
    }
}

Describe 'Authentication' {
    Context '1Password' {
        It 'reads the token with op read --no-newline from ASK_COPILOT_OP_REF' {
            $r = Invoke-AskCopilot '& $S hi'
            @($r.Op.args) | Should -Be @('read', '--no-newline', '--', 'op://Test/Copilot PAT/credential')
        }

        It 'prefers -OpReference over ASK_COPILOT_OP_REF' {
            $r = Invoke-AskCopilot '& $S -OpReference "op://Other/Item/field" hi'
            @($r.Op.args)[-1] | Should -BeExactly 'op://Other/Item/field'
        }

        It 'rejects a reference that is not op://' {
            $r = Invoke-AskCopilot '& $S -OpReference "Private/item" hi'
            $r.Stdout | Should -Match 'EXCEPTION: -OpReference must look like op://vault/item/field'
            $r.Op | Should -BeNullOrEmpty
            $r.Copilot | Should -BeNullOrEmpty
        }

        It 'fails without running Copilot when op fails' {
            $r = Invoke-AskCopilot '& $S hi' -Env @{ STUB_OP_EXIT = '1' }
            $r.Stdout | Should -Match 'EXCEPTION: op could not read op://Test/Copilot PAT/credential \(exit 1\)'
            $r.Copilot | Should -BeNullOrEmpty
        }

        It 'refuses -OpReference together with -SecretName' {
            $r = Invoke-AskCopilot '& $S -SecretName tok hi'
            $r.Stdout | Should -Match 'EXCEPTION: Use either -OpReference or -SecretName, not both'
            $r.Op | Should -BeNullOrEmpty
        }
    }

    Context 'Token checks' {
        It 'refuses a classic ghp_ token without running Copilot' {
            $r = Invoke-AskCopilot '& $S hi' -Env @{ STUB_TOKEN = 'ghp_classic' }
            $r.Stdout | Should -Match 'EXCEPTION: Classic PATs \(ghp_\) are rejected'
            $r.Copilot | Should -BeNullOrEmpty
        }

        It 'accepts a <Prefix> token without a warning' -ForEach @(
            @{ Prefix = 'github_pat_' }
            @{ Prefix = 'ghu_' }
            @{ Prefix = 'gho_' }
        ) {
            $r = Invoke-AskCopilot '& $S hi' -Env @{ STUB_TOKEN = "${Prefix}abc" }
            $r.Copilot.env.COPILOT_GITHUB_TOKEN | Should -BeExactly "${Prefix}abc"
            $r.Stdout | Should -Not -Match 'does not look like'
        }

        It 'warns about, but still uses, an unrecognised token' {
            $r = Invoke-AskCopilot '& $S hi' -Env @{ STUB_TOKEN = 'something_else' }
            $r.Stdout | Should -Match 'Token does not look like a GitHub fine-grained PAT'
            $r.Copilot.env.COPILOT_GITHUB_TOKEN | Should -BeExactly 'something_else'
        }
    }

    Context 'SecretManagement' {
        It 'reads a <Kind> secret from the named vault' -ForEach @(
            @{ Kind = 'string' }
            @{ Kind = 'securestring' }
            @{ Kind = 'credential' }
        ) {
            $r = Invoke-AskCopilot '& $S -SecretName CopilotToken -Vault Remote hi' -Env @{ ASK_COPILOT_OP_REF = $null; STUB_SECRET_KIND = $Kind }
            $r.Secret.name | Should -BeExactly 'CopilotToken'
            $r.Secret.vault | Should -BeExactly 'Remote'
            $r.Copilot.env.COPILOT_GITHUB_TOKEN | Should -BeExactly 'github_pat_FROMVAULT'
        }

        It 'uses the default vault when -Vault is not given' {
            $r = Invoke-AskCopilot '& $S -SecretName CopilotToken hi' -Env @{ ASK_COPILOT_OP_REF = $null; STUB_DEFAULT_VAULT = 'Remote' }
            $r.Secret.vault | Should -BeExactly 'Remote'
            $r.Copilot | Should -Not -BeNullOrEmpty
        }

        It 'refuses the local SecretStore vault' {
            $r = Invoke-AskCopilot '& $S -SecretName CopilotToken -Vault Local hi' -Env @{ ASK_COPILOT_OP_REF = $null }
            $r.Stdout | Should -Match "EXCEPTION: Vault 'Local' is a local SecretStore"
            $r.Secret | Should -BeNullOrEmpty
            $r.Copilot | Should -BeNullOrEmpty
        }

        It 'refuses a local SecretStore that is the default vault' {
            $r = Invoke-AskCopilot '& $S -SecretName CopilotToken hi' -Env @{ ASK_COPILOT_OP_REF = $null; STUB_DEFAULT_VAULT = 'Local' }
            $r.Stdout | Should -Match 'is a local SecretStore'
            $r.Secret | Should -BeNullOrEmpty
        }

        It 'fails when no vault is given and none is the default' {
            $r = Invoke-AskCopilot '& $S -SecretName CopilotToken hi' -Env @{ ASK_COPILOT_OP_REF = $null }
            $r.Stdout | Should -Match 'EXCEPTION: No SecretManagement vault specified and no default vault is registered'
        }

        It 'rejects a secret that is not a string, SecureString or PSCredential' {
            $r = Invoke-AskCopilot '& $S -SecretName CopilotToken -Vault Remote hi' -Env @{ ASK_COPILOT_OP_REF = $null; STUB_SECRET_KIND = 'hashtable' }
            $r.Stdout | Should -Match "EXCEPTION: Secret 'CopilotToken' is not a string, SecureString or PSCredential"
            $r.Copilot | Should -BeNullOrEmpty
        }
    }
}

Describe 'Output' {
    It 'emits the answer to the pipeline one line at a time' {
        $r = Invoke-AskCopilot '& $S hi | ForEach-Object { "LINE[$_]" }'
        $lines = @($r.Stdout -split '\r?\n' | Where-Object { $_ -like 'LINE*' })
        $lines | Should -Be @('LINE[# Answer]', 'LINE[]', 'LINE[Some **bold** text: naïve ✓]', 'LINE[]', 'LINE[```powershell]', 'LINE[Get-Date]', 'LINE[```]')
    }

    It 'can be captured in a variable' {
        $r = Invoke-AskCopilot '$x = & $S hi; "COUNT=$($x.Count) FIRST=$($x[0])"'
        $r.Stdout | Should -Match 'COUNT=7 FIRST=# Answer'
    }

    It 'can be redirected to a file' {
        $r = Invoke-AskCopilot '& $S hi > answer.md; "FILE=" + (Get-Content answer.md -Raw -Encoding utf8)'
        $r.Stdout | Should -Match 'FILE=# Answer'
        $r.Stdout | Should -Match 'naïve ✓'
    }

    It 'leaves Copilot''s stderr on stderr' {
        $r = Invoke-AskCopilot '& $S hi'
        $r.Stderr | Should -Match 'stub copilot stderr'
        $r.Stdout | Should -Not -Match 'stub copilot stderr'
    }

    It 'passes on Copilot''s exit code after emitting its output' {
        $r = Invoke-AskCopilot '& $S hi' -Env @{ STUB_EXIT = '3' }
        $r.ExitCode | Should -Be 3
        $r.Stdout | Should -Match '# Answer'
    }
}

Describe 'glow' {
    Context 'Explicit and invalid modes' {
        It 'renders with glow for -Glow on, even when captured' {
            $r = Invoke-AskCopilot '$x = & $S -Glow on hi; "PIPELINE_EMPTY=$($null -eq $x)"' -WithGlow
            @($r.Glow.args) | Should -Be @('-')
            $r.Glow.stdin | Should -Match '# Answer'
            $r.Glow.stdin | Should -Match 'naïve ✓'
            $r.Glow.stdin | Should -Match 'Get-Date'
            $r.Stdout | Should -Match 'GLOW> # Answer'
            $r.Stdout | Should -Match 'PIPELINE_EMPTY=True'
        }

        It 'warns and emits raw Markdown for -Glow on when glow is missing' {
            $r = Invoke-AskCopilot '& $S -Glow on hi'
            $r.Stdout | Should -Match 'glow not found on PATH; showing raw Markdown'
            $r.Stdout | Should -Match '(?m)^# Answer'
        }

        It 'emits raw Markdown when glow fails' {
            $r = Invoke-AskCopilot '$x = & $S -Glow on hi; "FIRST=$($x[0]) LAST_CODE_LINE=$($x[6])"' -WithGlow -Env @{ STUB_GLOW_EXIT = '1' }
            $r.Glow | Should -Not -BeNullOrEmpty
            $r.Stdout | Should -Match 'FIRST=# Answer LAST_CODE_LINE=```'
        }

        It 'never runs glow for -Glow off' {
            $r = Invoke-AskCopilot '& $S -Glow off hi' -WithGlow
            $r.Glow | Should -BeNullOrEmpty
            $r.Stdout | Should -Match '(?m)^# Answer'
        }

        It 'rejects an invalid -Glow value before running Copilot' {
            $r = Invoke-AskCopilot '& $S -Glow sometimes hi' -WithGlow
            $r.Stdout | Should -Match "EXCEPTION: -Glow must be auto, on or off \(got 'sometimes'\)"
            $r.Copilot | Should -BeNullOrEmpty
        }

        It 'takes its default from ASK_COPILOT_GLOW, ignoring case and spaces' {
            $r = Invoke-AskCopilot '& $S hi | Out-String' -WithGlow -Env @{ ASK_COPILOT_GLOW = ' ON ' }
            $r.Glow | Should -Not -BeNullOrEmpty
        }

        It 'lets -Glow override ASK_COPILOT_GLOW' {
            $r = Invoke-AskCopilot '& $S -Glow off hi' -WithGlow -Env @{ ASK_COPILOT_GLOW = 'on' }
            $r.Glow | Should -BeNullOrEmpty
        }

        It 'does not use glow in auto mode when output is redirected' {
            $r = Invoke-AskCopilot '& $S hi' -WithGlow
            $r.Glow | Should -BeNullOrEmpty
            $r.Stdout | Should -Match '(?m)^# Answer'
        }
    }

    Context 'Auto mode in a terminal' -Skip:(-not $CanUseTerminal) {
        It 'renders with glow for <Case>' -ForEach @(
            @{ Case = 'a bare call'; Command = '& $S hi' }
            @{ Case = 'a call after another statement'; Command = '$a = 1; & $S hi' }
            @{ Case = 'pwsh -File'; Command = '& $env:STUB_PWSH -NoProfile -NonInteractive -File $S hi' }
            @{ Case = 'the body of an if'; Command = 'if ($true) { & $S hi }' }
            @{ Case = 'the body of a loop'; Command = 'foreach ($i in 1) { & $S hi }' }
            @{ Case = 'a try block'; Command = 'try { & $S hi } finally { }' }
        ) {
            $r = Invoke-AskCopilot $Command -WithGlow -Terminal
            $r.ExitCode | Should -Be 0
            $r.Copilot | Should -Not -BeNullOrEmpty
            $r.Glow | Should -Not -BeNullOrEmpty
        }

        It 'emits raw Markdown for <Case>' -ForEach @(
            @{ Case = 'a pipe'; Command = '& $S hi | Select-Object -First 3' }
            @{ Case = 'an assignment'; Command = '$x = & $S hi' }
            @{ Case = 'parentheses'; Command = '(& $S hi).Count' }
            @{ Case = 'a subexpression'; Command = '$(& $S hi)' }
            @{ Case = 'a subexpression in a string'; Command = '"$(& $S hi)"' }
            @{ Case = 'an assigned subexpression'; Command = '$x = $(& $S hi)' }
            @{ Case = 'an array subexpression'; Command = '@(& $S hi)' }
            @{ Case = 'an assigned if'; Command = '$x = if ($true) { & $S hi }' }
            @{ Case = 'a subexpression around an if'; Command = '$(if ($true) { & $S hi })' }
            @{ Case = 'a script block'; Command = '& { & $S hi }' }
            @{ Case = 'a file redirect'; Command = '& $S hi > answer.md' }
            @{ Case = 'pwsh -File into a pipe'; Command = '& $env:STUB_PWSH -NoProfile -NonInteractive -File $S hi | Select-Object -First 1' }
            @{ Case = '-Glow off'; Command = '& $S -Glow off hi' }
        ) {
            $r = Invoke-AskCopilot $Command -WithGlow -Terminal
            $r.ExitCode | Should -Be 0
            $r.Copilot | Should -Not -BeNullOrEmpty
            $r.Glow | Should -BeNullOrEmpty
        }

        It 'emits raw Markdown when ASK_COPILOT_GLOW is off' {
            $r = Invoke-AskCopilot '& $S hi' -WithGlow -Terminal -Env @{ ASK_COPILOT_GLOW = 'off' }
            $r.Copilot | Should -Not -BeNullOrEmpty
            $r.Glow | Should -BeNullOrEmpty
        }

        It 'falls back to raw Markdown when glow is not installed' {
            $r = Invoke-AskCopilot '& $S hi' -Terminal
            $r.ExitCode | Should -Be 0
            $r.Copilot | Should -Not -BeNullOrEmpty
        }
    }
}
