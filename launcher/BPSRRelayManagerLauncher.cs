using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("BPSR Relay Manager")]
[assembly: AssemblyDescription("Launcher for BPSR Android DPSMeter Relay")]
[assembly: AssemblyCompany("Zudin987")]
[assembly: AssemblyProduct("BPSR Android DPSMeter Relay")]
[assembly: AssemblyVersion("0.0.0.0")]
[assembly: AssemblyFileVersion("0.0.0.0")]

namespace BpsrRelayManagerLauncher
{
    internal static class Program
    {
        private const string ProductName = "BPSR Relay Manager";

        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(
                    Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar
                );
                string launcherScript = Path.Combine(root, "scripts", "LaunchManager.ps1");
                string managerScript = Path.Combine(root, "scripts", "BPSRRelayManager.ps1");

                if (!File.Exists(launcherScript))
                {
                    throw new FileNotFoundException("scripts\\LaunchManager.ps1 is missing. Re-extract the complete release ZIP.", launcherScript);
                }
                if (!File.Exists(managerScript))
                {
                    throw new FileNotFoundException("scripts\\BPSRRelayManager.ps1 is missing. Re-extract the complete release ZIP.", managerScript);
                }

                bool selfTest = args != null && args.Length == 1 &&
                    string.Equals(args[0], "--launcher-self-test", StringComparison.OrdinalIgnoreCase);

                string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
                string powershell = Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
                if (!File.Exists(powershell))
                {
                    powershell = "powershell.exe";
                }

                var startInfo = new ProcessStartInfo
                {
                    FileName = powershell,
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + launcherScript + "\"",
                    WorkingDirectory = root,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };

                // CI/package probe: run the real launcher script in UI self-test mode.
                // This validates the packaged layout plus tray/single-instance bootstrap
                // without opening the normal manager window or starting the relay.
                if (selfTest)
                {
                    startInfo.EnvironmentVariables["BPSR_RELAY_UI_SELF_TEST"] = "1";
                }

                Process process = Process.Start(startInfo);
                if (process == null)
                {
                    throw new InvalidOperationException("Windows could not start the manager process.");
                }

                if (!selfTest)
                {
                    return 0;
                }

                using (process)
                {
                    if (!process.WaitForExit(45000))
                    {
                        try { process.Kill(); }
                        catch { }
                        throw new TimeoutException("Packaged launcher self-test timed out.");
                    }
                    return process.ExitCode;
                }
            }
            catch (Exception ex)
            {
                try
                {
                    Application.EnableVisualStyles();
                    MessageBox.Show(
                        ex.Message,
                        ProductName + " could not start",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error
                    );
                }
                catch
                {
                    // WinExe has no console; if MessageBox itself fails there is no safe UI fallback.
                }
                return 1;
            }
        }
    }
}
