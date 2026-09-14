using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("BPSR Relay Manager")]
[assembly: AssemblyDescription("Native manager for BPSR Android DPSMeter Relay")]
[assembly: AssemblyCompany("Zudin987")]
[assembly: AssemblyProduct("BPSR Android DPSMeter Relay")]
[assembly: AssemblyVersion("0.0.0.0")]
[assembly: AssemblyFileVersion("0.0.0.0")]

namespace BpsrRelayManager
{
    internal static class Program
    {
        private const string MutexName = "Local\\Zudin987.BPSRAndroidRelayManager.Instance";
        private const string RestoreEventName = "Local\\Zudin987.BPSRAndroidRelayManager.Restore";

        [STAThread]
        private static int Main(string[] args)
        {
            ServicePointBootstrap.EnableTls12();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            bool nonInteractive = HasArg(args, "--windows-api-self-test") || HasArg(args, "--self-test") || HasArg(args, "--ui-self-test") || string.Equals(Environment.GetEnvironmentVariable("BPSR_RELAY_UI_SELF_TEST"), "1", StringComparison.Ordinal);

            try
            {
                string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                if (HasArg(args, "--firewall-helper")) return RunFirewallHelper(args);
                if (HasArg(args, "--windows-api-self-test"))
                {
                    WindowsApiSelfTest.Run();
                    Console.WriteLine("WINDOWS API SELF-TEST PASS: adapter category and firewall COM reads succeeded.");
                    return 0;
                }

                if (HasArg(args, "--self-test"))
                {
                    string requestedRoot = GetArgValue(args, "--self-test-root");
                    bool temporary = string.IsNullOrWhiteSpace(requestedRoot);
                    string testRoot = temporary ? Path.Combine(Path.GetTempPath(), "bpsr-relay-native-selftest-" + Guid.NewGuid().ToString("N")) : Path.GetFullPath(requestedRoot);
                    Directory.CreateDirectory(testRoot);
                    try
                    {
                        RelayEngine engine = new RelayEngine(testRoot, delegate(string message) { Console.WriteLine(message); });
                        engine.RunSelfTest();
                        Console.WriteLine("NATIVE SELF-TEST PASS: config generation, pinned runtime verification and relay topology validation succeeded.");
                        return 0;
                    }
                    finally
                    {
                        if (temporary) try { Directory.Delete(testRoot, true); } catch { }
                    }
                }

                bool uiSelfTest = HasArg(args, "--ui-self-test") || string.Equals(Environment.GetEnvironmentVariable("BPSR_RELAY_UI_SELF_TEST"), "1", StringComparison.Ordinal);
                if (uiSelfTest)
                {
                    RelayEngine uiEngine = new RelayEngine(root, delegate(string message) { });
                    using (MainForm testForm = new MainForm(uiEngine, true))
                    {
                        Branding.Apply(testForm);
                        testForm.RunUiSelfTest();
                    }
                    Console.WriteLine("UI SELF-TEST PASS: native Home/Details/Help layout, app branding and tray controls are present.");
                    return 0;
                }

                bool createdNew;
                using (Mutex mutex = new Mutex(true, MutexName, out createdNew))
                {
                    if (!createdNew)
                    {
                        try { using (EventWaitHandle evt = EventWaitHandle.OpenExisting(RestoreEventName)) evt.Set(); }
                        catch { }
                        return 0;
                    }

                    bool eventCreated;
                    using (EventWaitHandle restoreEvent = new EventWaitHandle(false, EventResetMode.AutoReset, RestoreEventName, out eventCreated))
                    {
                        RelayEngine engine = new RelayEngine(root, null);
                        using (MainForm form = new MainForm(engine, false))
                        {
                            Branding.Apply(form);
                            Thread restoreThread = new Thread(delegate()
                            {
                                while (!form.IsDisposed)
                                {
                                    try
                                    {
                                        restoreEvent.WaitOne();
                                        if (form.IsDisposed) break;
                                        form.BeginInvoke((MethodInvoker)delegate { form.RestoreFromTray(); });
                                    }
                                    catch { break; }
                                }
                            });
                            restoreThread.IsBackground = true;
                            restoreThread.Name = "BPSR Relay Manager restore listener";
                            restoreThread.Start();
                            Application.Run(form);
                        }
                    }
                }
                return 0;
            }
            catch (Exception ex)
            {
                if (nonInteractive)
                {
                    try { Console.Error.WriteLine(ex.ToString()); } catch { }
                    return 1;
                }
                try { MessageBox.Show(ex.Message, "BPSR Relay Manager could not start", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                catch { }
                return 1;
            }
        }

        private static int RunFirewallHelper(string[] args)
        {
            string ip = GetArgValue(args, "--ip");
            string adapterId = GetArgValue(args, "--adapter");
            if (string.IsNullOrWhiteSpace(ip) || string.IsNullOrWhiteSpace(adapterId)) throw new ArgumentException("Firewall helper arguments are incomplete.");
            try
            {
                WindowsIntegration.MakeNetworkPrivate(adapterId);
                WindowsIntegration.InstallFirewallRules(ip);
                return 0;
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Could not allow phone connection", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }

        private static bool HasArg(string[] args, string name)
        {
            if (args == null) return false;
            foreach (string arg in args) if (string.Equals(arg, name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        private static string GetArgValue(string[] args, string name)
        {
            if (args == null) return string.Empty;
            for (int i = 0; i + 1 < args.Length; i++) if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return args[i + 1];
            return string.Empty;
        }
    }

    internal static class ServicePointBootstrap
    {
        public static void EnableTls12()
        {
            try { System.Net.ServicePointManager.SecurityProtocol = (System.Net.SecurityProtocolType)3072; } catch { }
        }
    }
}
