// Native stand-in for copilot.exe, op.exe and glow.exe on Windows (ask-copilot.ps1 only launches .exe files).
// Runs stub.ps1 with the role taken from this executable's name and hands over the arguments in
// STUB_ARGS (base64 of NUL-terminated UTF-8 strings), so they are never re-quoted on the way.
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

static class Launcher
{
    static int Main(string[] args)
    {
        string role = Path.GetFileNameWithoutExtension(Process.GetCurrentProcess().MainModule.FileName);
        var joined = new StringBuilder();
        foreach (string a in args) joined.Append(a).Append('\0');

        var psi = new ProcessStartInfo(
            Environment.GetEnvironmentVariable("STUB_PWSH"),
            "-NoProfile -NonInteractive -File \"" + Environment.GetEnvironmentVariable("STUB_SCRIPT") + "\" " + role);
        psi.UseShellExecute = false;
        psi.EnvironmentVariables["STUB_ARGS"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(joined.ToString()));

        using (Process p = Process.Start(psi))
        {
            p.WaitForExit();
            return p.ExitCode;
        }
    }
}
