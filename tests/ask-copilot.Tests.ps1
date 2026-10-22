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
    $script:StubTools = Initialize-StubToolSet
}

AfterAll {
    Remove-StubToolSet $StubTools
}

Describe 'Script file' {
    It 'parses without errors' {
        $tokens = $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($AskCopilot, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has valid PowerShell Gallery metadata' {
        Test-PSScriptFileInfo -Path $AskCopilot | Should -BeTrue
        $text = Get-Content -LiteralPath $AskCopilot -Raw
        $text | Should -Match '(?m)^\.VERSION \d+\.\d+\.\d+\s*$'
        $text | Should -Match '(?m)^\.GUID [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\s*$'
        $text | Should -Match '(?m)^\.PROJECTURI https://github\.com/emilywilder/ask-copilot\s*$'
        $text | Should -Match '(?m)^\.LICENSEURI https://github\.com/emilywilder/ask-copilot/blob/main/LICENSE\s*$'
    }

    It 'keeps the shebang on the first line' {
        (Get-Content -LiteralPath $AskCopilot -TotalCount 1) | Should -BeExactly '#!/usr/bin/env pwsh'
    }

    It 'has comment-based help that Get-Help recognises' {
        (Get-Help $AskCopilot).Synopsis | Should -BeLike 'Ask GitHub Copilot a question from the terminal*'
    }

    It 'documents strings as its pipeline input' {
        (Get-Help $AskCopilot -Full).inputTypes.inputType.type.name | Should -Match '^System\.String'
    }

    It 'documents strings as its output, in help and in OutputType' {
        (Get-Help $AskCopilot -Full).returnValues.returnValue.type.name | Should -Match '^System\.String'
        (Get-Command $AskCopilot).OutputType.Type | Should -Be @([string])
    }

    It 'has notes covering requirements and verbose output' {
        $notes = ((Get-Help $AskCopilot -Full).alertSet.alert.Text -join "`n")
        $notes | Should -Match 'PowerShell 7\.2 or later'
        $notes | Should -Match 'winget install GitHub\.Copilot'
        $notes | Should -Match 'neither ever shows the token'
    }

    It 'links to the project first, so Get-Help -Online opens it' {
        $links = @((Get-Help $AskCopilot -Full).relatedLinks.navigationLink.uri)
        $links[0] | Should -BeExactly 'https://github.com/emilywilder/ask-copilot'
        $links | Should -Contain 'https://github.com/github/copilot-cli'
        $links | Should -Not -Contain $null
    }

    It 'keeps code comments out of the examples' {
        foreach ($example in (Get-Help $AskCopilot -Examples).examples.example) {
            ($example.remarks.Text -join '').Trim() | Should -BeNullOrEmpty -Because "example '$($example.code)' has no remarks"
        }
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
            $r = Invoke-AskCopilot '& $S -OpReference "op://Other/Item/field" -SecretName tok hi'
            $r.Stdout | Should -Match 'EXCEPTION: Parameter set cannot be resolved'
            $r.Op | Should -BeNullOrEmpty
            $r.Secret | Should -BeNullOrEmpty
            $r.Copilot | Should -BeNullOrEmpty
        }
    }

    Context 'Parameter sets' {
        It 'has an OpReference set (the default) and a SecretName set' {
            $command = Get-Command $AskCopilot
            $command.ParameterSets.Name | Sort-Object | Should -Be @('OpReference', 'SecretName')
            ($command.ParameterSets | Where-Object IsDefault).Name | Should -BeExactly 'OpReference'
        }

        It 'lets -SecretName take precedence over ASK_COPILOT_OP_REF' {
            $r = Invoke-AskCopilot '& $S -SecretName CopilotToken -Vault Remote hi'
            $r.Op | Should -BeNullOrEmpty
            $r.Secret.name | Should -BeExactly 'CopilotToken'
            $r.Copilot.env.COPILOT_GITHUB_TOKEN | Should -BeExactly 'github_pat_FROMVAULT'
        }

        It 'requires -SecretName when -Vault is given' {
            $r = Invoke-AskCopilot '& $S -Vault Remote hi'
            $r.Stdout | Should -Match 'EXCEPTION: .*missing mandatory parameters: SecretName'
            $r.Op | Should -BeNullOrEmpty
            $r.Copilot | Should -BeNullOrEmpty
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

Describe 'Feedback' {
    It 'writes no verbose output by default' {
        $r = Invoke-AskCopilot '& $S hi'
        $r.Stdout | Should -Not -Match 'VERBOSE:'
    }

    It 'reports each step with -Verbose' {
        $r = Invoke-AskCopilot '& $S -Verbose hi'
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -Match 'VERBOSE: Question: 2 characters; piped context: 0 characters\.'
        $r.Stdout | Should -Match 'VERBOSE: glow: not found on PATH; emitting raw Markdown\.'
        $r.Stdout | Should -Match ('VERBOSE: Copilot CLI: .*' + [regex]::Escape([IO.Path]::DirectorySeparatorChar) + 'copilot')
        $r.Stdout | Should -Match 'VERBOSE: Optional hardening flags passed: --disable-builtin-mcps, --no-auto-update, --disable-client-telemetry, --no-color\.'
        $r.Stdout | Should -Match 'VERBOSE: Temporary directory \(working directory and COPILOT_HOME\): .*ask-copilot-[0-9a-f]{32}'
        $r.Stdout | Should -Match ([regex]::Escape('VERBOSE: Reading the token from 1Password (op://Test/Copilot PAT/credential)'))
        $r.Stdout | Should -Match 'VERBOSE: Started Copilot \(process \d+\) with the token in COPILOT_GITHUB_TOKEN\.'
        $r.Stdout | Should -Match 'VERBOSE: Copilot exited with code 0\.'
        $r.Stdout | Should -Match 'VERBOSE: Deleted the temporary directory .*ask-copilot-[0-9a-f]{32}\.'
    }

    It 'reports the length of piped context' {
        $r = Invoke-AskCopilot '"abc", "de" | & $S -Verbose q'
        $r.Stdout | Should -Match "VERBOSE: Question: 1 characters; piped context: $(5 + $Nl.Length) characters\."
    }

    It 'names the variables it removed from Copilot''s environment' {
        $r = Invoke-AskCopilot '& $S -Verbose hi'
        $line = ($r.Stdout -split '\r?\n' | Where-Object { $_ -like "VERBOSE: Removed from Copilot's environment:*" })
        $line | Should -Not -BeNullOrEmpty
        foreach ($name in 'COPILOT_ALLOW_ALL', 'COPILOT_MODEL', 'GITHUB_COPILOT_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN',
                          'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN', 'GH_HOST') {
            $line | Should -Match "\b$name\b"
        }
    }

    It 'reports optional flags the CLI does not support' {
        $r = Invoke-AskCopilot '& $S -Verbose hi' -Env @{ STUB_HELP = 'minimal' }
        $r.Stdout | Should -Match 'VERBOSE: Optional hardening flags passed: none\.'
        $r.Stdout | Should -Match 'VERBOSE: Not supported by this Copilot CLI: --disable-builtin-mcps, --no-auto-update, --disable-client-telemetry, --no-color\.'
    }

    It 'reports the -p fallback' {
        $r = Invoke-AskCopilot '& $S -Verbose hi' -Env @{ STUB_HELP = 'noprompt' }
        $r.Stdout | Should -Match 'VERBOSE: This Copilot CLI has no --prompt flag; passing the prompt with -p\.'
    }

    It 'reports the vault a secret is read from' {
        $r = Invoke-AskCopilot '& $S -Verbose -SecretName CopilotToken -Vault Remote hi'
        $r.Stdout | Should -Match "VERBOSE: Reading secret 'CopilotToken' from SecretManagement vault 'Remote' \(Az\.KeyVault\)\."
    }

    It 'reports the glow decision for <Case>' -ForEach @(
        @{ Case = '-Glow off'; Command = '& $S -Verbose -Glow off hi'; Expected = 'glow: off; emitting raw Markdown\.' }
        @{ Case = 'auto with redirected output'; Command = '& $S -Verbose hi'; Expected = 'glow: output is piped, redirected or captured; emitting raw Markdown\.' }
        @{ Case = '-Glow on'; Command = '& $S -Verbose -Glow on hi'; Expected = 'glow: rendering with .*glow' }
    ) {
        $r = Invoke-AskCopilot $Command -WithGlow
        $r.Stdout | Should -Match "VERBOSE: $Expected"
    }

    It 'shows Copilot''s arguments with -Debug, with the prompt shortened to its length' {
        $r = Invoke-AskCopilot '& $S -Debug hi'
        $r.Stdout | Should -Match 'DEBUG: Copilot arguments: <prompt: \d+ characters> --silent --no-ask-user --no-custom-instructions --deny-tool=shell,write,read,url,memory,github'
    }

    It 'never shows the token in verbose or debug output' {
        $r = Invoke-AskCopilot '& $S -Verbose -Debug hi'
        $r.Stdout | Should -Match 'VERBOSE:'
        $r.Stdout | Should -Not -Match 'github_pat_TEST0123456789'
        $r.Stderr | Should -Not -Match 'github_pat_TEST0123456789'
    }

    Context 'Progress while waiting for Copilot' {
        BeforeAll {
            # Runs the script in a PowerShell instance so its progress records can be read back.
            $script:ProgressCommand = @'
$ps = [powershell]::Create()
$null = $ps.AddCommand($S).AddArgument('hi')
if ($env:TEST_GLOW) { $null = $ps.AddParameter('Glow', $env:TEST_GLOW) }
$out = $ps.Invoke()
foreach ($p in $ps.Streams.Progress) { "PROGRESS|$($p.Activity)|$($p.StatusDescription)|$($p.RecordType)" }
"OUTPUT_LINES=$($out.Count)"
'@
            function Get-ProgressRecord($Result) {
                foreach ($line in $Result.Stdout -split '\r?\n' | Where-Object { $_ -like 'PROGRESS|*' }) {
                    $activity, $status, $type = $line.Substring('PROGRESS|'.Length) -split '\|'
                    [pscustomobject]@{ Activity = $activity; Status = $status; Type = $type }
                }
            }
        }

        It 'shows the elapsed time until the answer starts, then clears it' {
            $r = Invoke-AskCopilot $ProgressCommand -Env @{ STUB_DELAY_MS = '1600' }
            $records = @(Get-ProgressRecord $r)
            $waiting = @($records | Where-Object Type -EQ 'Processing')
            $waiting | Should -Not -BeNullOrEmpty
            $waiting.Activity | Sort-Object -Unique | Should -Be 'Asking Copilot'
            $waiting.Status | ForEach-Object { $_ | Should -Match '^Waiting for the answer \(\d+s\)$' }
            $waiting.Status | Should -Contain 'Waiting for the answer (1s)'
            $records[-1].Type | Should -Be 'Completed'
            $r.Stdout | Should -Match 'OUTPUT_LINES=7'
        }

        It 'shows the elapsed time until the full answer is in when rendering with glow' {
            $r = Invoke-AskCopilot $ProgressCommand -WithGlow -Env @{ STUB_DELAY_MS = '1600'; TEST_GLOW = 'on' }
            $records = @(Get-ProgressRecord $r)
            $waiting = @($records | Where-Object Type -EQ 'Processing')
            $waiting.Status | ForEach-Object { $_ | Should -Match '^Waiting for the full answer \(\d+s\)$' }
            $waiting.Status | Should -Contain 'Waiting for the full answer (1s)'
            $records[-1].Type | Should -Be 'Completed'
            $r.Glow | Should -Not -BeNullOrEmpty
        }

        It 'clears the progress even when Copilot answers immediately' {
            $r = Invoke-AskCopilot $ProgressCommand
            $records = @(Get-ProgressRecord $r)
            $records | Should -Not -BeNullOrEmpty
            $records[-1].Type | Should -Be 'Completed'
            $r.Stdout | Should -Match 'OUTPUT_LINES=7'
        }
    }

    It 'warns when the temporary directory cannot be deleted' -Skip:(-not $IsWindows) {
        $r = Invoke-AskCopilot '& $S hi' -Env @{ STUB_HOLD_CWD_SECONDS = '5' }
        try {
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -Match 'WARNING: Could not delete the temporary directory .*ask-copilot-[0-9a-f]{32}\. It may hold Copilot''s files for this session; delete it yourself\.'
            $r.LeftoverTempDirs | Should -Not -BeNullOrEmpty
        }
        finally {
            # Wait for the holder process to exit so the directory can be cleaned up.
            foreach ($dir in $r.LeftoverTempDirs) {
                for ($i = 0; $i -lt 40 -and (Test-Path -LiteralPath $dir.FullName); $i++) {
                    try { Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 250 }
                }
            }
        }
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
            $r.Stdout | Should -Match "EXCEPTION: Cannot validate argument on parameter 'Glow'"
            $r.Copilot | Should -BeNullOrEmpty
        }

        It 'accepts -Glow in any case' {
            $r = Invoke-AskCopilot '& $S -Glow ON hi | Out-String' -WithGlow
            $r.Glow | Should -Not -BeNullOrEmpty
        }

        It 'rejects an invalid ASK_COPILOT_GLOW before running Copilot' {
            $r = Invoke-AskCopilot '& $S hi' -WithGlow -Env @{ ASK_COPILOT_GLOW = ' sometimes ' }
            $r.Stdout | Should -Match "EXCEPTION: ASK_COPILOT_GLOW must be auto, on or off \(got 'sometimes'\)"
            $r.Copilot | Should -BeNullOrEmpty
        }

        It 'offers auto, on and off as tab completions for -Glow' {
            $line = "& '$($AskCopilot.Replace("'", "''"))' -Glow "
            $completions = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText
            $completions | Sort-Object | Should -Be @('auto', 'off', 'on')
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
