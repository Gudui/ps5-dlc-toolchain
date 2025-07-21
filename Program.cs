// Program.cs – single-file bootstrapper
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;

namespace LauncherApp;

internal static class Program
{
    private const string ScriptRelativePath = @"Scripts\dlcpacker.ps1";

    static int Main(string[] args)
    {
    	int rc = 1;
        try
        {
            string workDir = ExtractResourcesOnce();
#if DEBUG
            Dump(workDir);
#endif
            string script = Path.Combine(workDir, ScriptRelativePath);
            if (!File.Exists(script))
                throw new FileNotFoundException($"Embedded script not found: {script}");

            rc = Run(
			    fileName: "powershell.exe",
			    arguments:$"-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{script}\" {ArgJoin(args)}",
			    workingDirectory: workDir);  
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            Console.ReadLine();
            rc = -1;
        }
        Console.WriteLine("\n(done)  Press any key to close …");
        Console.ReadKey(intercept: true);
		return rc;
    }

    // ───────────────────────── resource extraction ──────────────────────────
	private static string ExtractResourcesOnce()
	{
	    string root = Path.Combine(ExeDir, "data");          // .\data next to the EXE
	    if (Directory.Exists(root)) return root;             // idempotent

	    Assembly asm       = Assembly.GetExecutingAssembly();
	    string   asmPrefix = asm.GetName().Name + ".";

	    foreach (string res in asm.GetManifestResourceNames())
	    {
	        if (!res.StartsWith(asmPrefix, StringComparison.Ordinal)) continue;

	        string logical = res.Substring(asmPrefix.Length);         // bin.gengp4_patch.exe
	        int    lastDot = logical.LastIndexOf('.');
	        if (lastDot == -1) continue;

	        string relPath = logical[..lastDot].Replace('.', Path.DirectorySeparatorChar) +
	                         logical[lastDot..];                      // keep extension

	        string dest = Path.Combine(root, relPath);
	        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);

	        using Stream src = asm.GetManifestResourceStream(res)!;
	        using FileStream dst = File.Create(dest);
	        src.CopyTo(dst);
	    }
	    return root;
	}


    // ───────────────────────── process runner ───────────────────────────────
    private static int Run(string fileName, string arguments, string workingDirectory)
    {
        using var p = new Process
        {
            StartInfo = new ProcessStartInfo(fileName, arguments)
            {
                WorkingDirectory       = workingDirectory,
                UseShellExecute        = false,
                RedirectStandardOutput = true,
                RedirectStandardError  = true
            }
        };

        p.OutputDataReceived += (_, e) => { if (e.Data != null) Console.WriteLine(e.Data); };
        p.ErrorDataReceived  += (_, e) => { if (e.Data != null) Console.Error.WriteLine(e.Data); };

        p.Start();
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        p.WaitForExit();
        return p.ExitCode;
    }

    // ───────────────────────── utilities ────────────────────────────────────
    private static string ArgJoin(string[] argv) =>
        string.Join(' ', argv.Select(a => '"' + a.Replace("\"", "\\\"") + '"'));

#if DEBUG
    private static void Dump(string root)
    {
        Console.WriteLine($"[DEBUG] Extracted to: {root}");
        foreach (string f in Directory.GetFiles(root, "*", SearchOption.AllDirectories))
            Console.WriteLine("  " + Path.GetRelativePath(root, f));
        Console.WriteLine();
    }
#endif
    private static readonly string ExeDir =
    Path.GetDirectoryName(Environment.ProcessPath                            // .NET 6+
                          ?? Assembly.GetExecutingAssembly().Location)!;  
}
