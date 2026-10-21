# Helpers for ask-copilot.Tests.ps1. Dot-source in BeforeAll.

$script:AskCopilot = Join-Path (Split-Path $PSScriptRoot) 'ask-copilot.ps1'
$script:Pwsh = [Environment]::ProcessPath
$script:Nl = [Environment]::NewLine

# Copilot, op and glow live in separate directories so each can be left off PATH on its own.
function Initialize-StubToolSet {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ask-copilot-tests-' + [guid]::NewGuid().ToString('N'))
    $tools = [pscustomobject]@{
        Root        = $root
        CopilotBin  = Join-Path $root 'copilot-bin'
        OpBin       = Join-Path $root 'op-bin'
        GlowBin     = Join-Path $root 'glow-bin'
        StubScript  = Join-Path $PSScriptRoot 'stubs\stub.ps1'
        Modules     = Join-Path $PSScriptRoot 'fixtures\modules'
        Launcher    = $null
        SystemPath  = @()
    }
    $null = New-Item -ItemType Directory -Path $tools.CopilotBin, $tools.OpBin, $tools.GlowBin

    if ($IsWindows) {
        # ask-copilot.ps1 only launches native .exe files on Windows, so compile a tiny launcher.
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path $csc)) { throw "The tests need the .NET Framework C# compiler at $csc." }
        $tools.Launcher = Join-Path $root 'launcher.exe'
        $cscOutput = & $csc /nologo /target:exe "/out:$($tools.Launcher)" (Join-Path $PSScriptRoot 'stubs\launcher.cs')
        if ($LASTEXITCODE -ne 0) { throw "Compiling the stub launcher failed:$Nl$cscOutput" }
        Copy-Item $tools.Launcher (Join-Path $tools.CopilotBin 'copilot.exe')
        Copy-Item $tools.Launcher (Join-Path $tools.OpBin 'op.exe')
        Copy-Item $tools.Launcher (Join-Path $tools.GlowBin 'glow.exe')
        $tools.SystemPath = @(Join-Path $env:WINDIR 'System32'), $env:WINDIR
    }
    else {
        $dirs = @{ copilot = $tools.CopilotBin; op = $tools.OpBin; glow = $tools.GlowBin }
        foreach ($role in $dirs.Keys) {
            $wrapper = Join-Path $dirs[$role] $role
            $content = "#!/bin/sh`n" +
                "STUB_ARGS=`$(printf '%s\0' `"`$@`" | base64 | tr -d '\n') exec `"`$STUB_PWSH`" -NoProfile -NonInteractive -File `"`$STUB_SCRIPT`" $role`n"
            [IO.File]::WriteAllText($wrapper, $content)
            & chmod +x $wrapper
        }
        $tools.SystemPath = @('/usr/bin', '/bin')
    }
    $tools
}

function Remove-StubToolSet($Tools) {
    if ($Tools -and (Test-Path -LiteralPath $Tools.Root)) { Remove-Item -LiteralPath $Tools.Root -Recurse -Force }
}

function Read-StubLog([string] $Dir, [string] $Name) {
    $path = Join-Path $Dir "$Name.json"
    if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
}

# True when Invoke-AskCopilot -Terminal can give the script a real console or pty.
function Test-TerminalSupported {
    $IsWindows -or [bool](Get-Command script -CommandType Application -ErrorAction SilentlyContinue)
}

<#
Runs $Command in a fresh pwsh, where $S is the path to ask-copilot.ps1, and returns what happened.
The child gets its own PATH (stub tools plus system directories only), TEMP and log directory, plus
COPILOT_*/GitHub token variables that ask-copilot.ps1 must strip. ASK_COPILOT_OP_REF points op at a
test reference. -Env overrides any variable; a $null value removes it.
With -Terminal the child gets a real console (Windows) or pty (script(1)) and its output is not captured.
#>
function Invoke-AskCopilot {
    param(
        [Parameter(Mandatory)] [string] $Command,
        [hashtable] $Env = @{},
        [switch] $WithGlow,
        [switch] $WithoutCopilot,
        [string[]] $PrependPath = @(),
        [switch] $Terminal
    )
    $run = Join-Path $StubTools.Root ('run-' + [guid]::NewGuid().ToString('N'))
    $logs = Join-Path $run 'logs'
    $temp = Join-Path $run 'temp'
    $null = New-Item -ItemType Directory -Path $logs, $temp

    $caseFile = Join-Path $run 'case.ps1'
    $quotedScript = $AskCopilot.Replace("'", "''")
    $caseScript = @"
`$S = '$quotedScript'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
try {
$Command
}
catch { 'EXCEPTION: ' + `$_.Exception.Message; exit 99 }
exit `$LASTEXITCODE
"@
    [IO.File]::WriteAllText($caseFile, $caseScript)

    $path = @($PrependPath) +
        @(if (-not $WithoutCopilot) { $StubTools.CopilotBin }) +
        @($StubTools.OpBin) +
        @(if ($WithGlow) { $StubTools.GlowBin }) +
        @($PSHOME) + $StubTools.SystemPath

    $pwshArgs = '-NoProfile', '-NonInteractive', '-File', $caseFile
    if ($Terminal -and -not $IsWindows) {
        $inner = (@($Pwsh) + $pwshArgs | ForEach-Object { "'" + $_.Replace("'", "'\''") + "'" }) -join ' '
        $psi = [System.Diagnostics.ProcessStartInfo]::new('script')
        if ($IsMacOS) { foreach ($a in @('-q', '/dev/null', 'sh', '-c', $inner)) { $psi.ArgumentList.Add($a) } }
        else { foreach ($a in @('-qec', $inner, '/dev/null')) { $psi.ArgumentList.Add($a) } }
    }
    else {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($Pwsh)
        foreach ($a in $pwshArgs) { $psi.ArgumentList.Add($a) }
    }
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $run
    if ($Terminal -and $IsWindows) {
        # A new, hidden console: the script sees a real terminal and nothing flashes on screen.
        $psi.CreateNoWindow = $true
    }
    else {
        # script(1) passes this stdin on to the pty, which is how the cursor-position replies below arrive.
        if ($Terminal) { $psi.RedirectStandardInput = $true }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    }

    foreach ($k in @($psi.Environment.Keys)) {
        # Includes the GITHUB_* variables CI runners set, so each test sees only the variables set below.
        if ($k -match '^(COPILOT_|GITHUB_|GH_|ASK_COPILOT_|STUB_)') { [void]$psi.Environment.Remove($k) }
    }
    $vars = [ordered]@{
        PATH                    = $path -join [IO.Path]::PathSeparator
        TEMP                    = $temp
        TMP                     = $temp
        TMPDIR                  = $temp
        PSModulePath            = $StubTools.Modules + [IO.Path]::PathSeparator + $env:PSModulePath
        STUB_PWSH               = $Pwsh
        STUB_SCRIPT             = $StubTools.StubScript
        STUB_LOG_DIR            = $logs
        # Some pwsh versions colour verbose and warning text even when redirected; keep output plain.
        NO_COLOR                = '1'
        ASK_COPILOT_OP_REF      = 'op://Test/Copilot PAT/credential'
        COPILOT_ALLOW_ALL       = 'true'
        COPILOT_MODEL           = 'should-be-stripped'
        GITHUB_COPILOT_TOKEN    = 'should-be-stripped'
        GH_TOKEN                = 'should-be-stripped'
        GITHUB_TOKEN            = 'should-be-stripped'
        GH_ENTERPRISE_TOKEN     = 'should-be-stripped'
        GITHUB_ENTERPRISE_TOKEN = 'should-be-stripped'
        GH_HOST                 = 'should-be-stripped.example'
    }
    foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
    foreach ($k in $vars.Keys) {
        if ($null -eq $vars[$k]) { [void]$psi.Environment.Remove($k) } else { $psi.Environment[$k] = $vars[$k] }
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        if ($psi.RedirectStandardInput) {
            # Drawing progress makes pwsh ask the terminal where the cursor is (ESC[6n) and wait for the
            # reply. A real terminal answers at once; script(1) does not, so each query would time out
            # after several seconds. Queue replies the way a terminal would. stdin stays open until exit.
            $proc.StandardInput.Write("`e[1;1R" * 500)
            $proc.StandardInput.Flush()
        }
        $stdoutTask = $stderrTask = $null
        if ($psi.RedirectStandardOutput) {
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
        }
        if (-not $proc.WaitForExit(120000)) {
            $proc.Kill($true)
            throw "Timed out running: $Command"
        }
        $proc.WaitForExit()
        [pscustomobject]@{
            ExitCode         = $proc.ExitCode
            Stdout           = if ($stdoutTask) { $stdoutTask.Result } else { $null }
            Stderr           = if ($stderrTask) { $stderrTask.Result } else { $null }
            Copilot          = Read-StubLog $logs 'copilot'
            Op               = Read-StubLog $logs 'op'
            Glow             = Read-StubLog $logs 'glow'
            Secret           = Read-StubLog $logs 'secret'
            LogDir           = $logs
            LeftoverTempDirs = @(Get-ChildItem -LiteralPath $temp -Directory -Filter 'ask-copilot-*')
        }
    }
    finally { $proc.Dispose() }
}

# The prompt Copilot received, from either --prompt=<text> or -p <text>.
function Get-CopilotPrompt($Result) {
    $cliArgs = @($Result.Copilot.args)
    $long = $cliArgs | Where-Object { $_.StartsWith('--prompt=') } | Select-Object -First 1
    if ($long) { return $long.Substring('--prompt='.Length) }
    $i = [array]::IndexOf($cliArgs, '-p')
    if ($i -ge 0) { return $cliArgs[$i + 1] }
}

# The question part of the prompt, without the instruction ask-copilot.ps1 appends.
function Get-CopilotQuestion($Result) {
    $prompt = Get-CopilotPrompt $Result
    $marker = "$Nl$Nl---$Nl"
    $prompt.Substring(0, $prompt.LastIndexOf($marker))
}
