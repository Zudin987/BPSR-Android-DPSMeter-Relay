using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace BpsrRelayManager
{
    internal sealed class RelayProcessInfo
    {
        public string Name;
        public int Id;
        public DateTime StartUtc;
        public string Path;
        public bool ProjectOwned;
    }

    internal sealed class CheckResult
    {
        public string Name;
        public string State;
        public string Detail;
    }

    internal sealed class RelayCredentials
    {
        public string mode { get; set; }
        public string frontUsername { get; set; }
        public string frontPassword { get; set; }
        public string internalUsername { get; set; }
        public string internalPassword { get; set; }
        public string createdUtc { get; set; }
    }

    internal sealed class ProfileMeta
    {
        public string managerVersion { get; set; }
        public string profileId { get; set; }
        public string pcIp { get; set; }
        public int relayPort { get; set; }
        public int internalPort { get; set; }
        public string ingress { get; set; }
        public string testedSingBoxVersion { get; set; }
        public string generatedUtc { get; set; }
    }

    internal sealed class PhoneProfileState
    {
        public string profileId { get; set; }
        public string confirmedUtc { get; set; }
        public string reason { get; set; }
    }

    internal sealed class PidState
    {
        public int starPid { get; set; }
        public string starStartUtc { get; set; }
        public int frontPid { get; set; }
        public string frontStartUtc { get; set; }
        public string starPath { get; set; }
        public string frontPath { get; set; }
        public string pcIp { get; set; }
        public int internalPort { get; set; }
        public string startedUtc { get; set; }
    }

    internal sealed class RelayEngine
    {
        public const int FrontPort = 10808;
        public const int InternalPortStart = 18080;
        public const int InternalPortEnd = 18180;

        private readonly string _root;
        private readonly string _runtime;
        private readonly string _output;
        private readonly string _config;
        private readonly string _rollback;
        private readonly string _pidFile;
        private readonly string _credentialsFile;
        private readonly string _versionFile;
        private readonly string _runtimeHashFile;
        private readonly string _singBoxExe;
        private readonly string _frontExe;
        private readonly string _starExe;
        private readonly string _frontConfig;
        private readonly string _starConfig;
        private readonly string _androidConfig;
        private readonly string _profileMeta;
        private readonly string _phoneState;
        private readonly string _logFile;
        private readonly string _qrHtml;
        private readonly JavaScriptSerializer _json = new JavaScriptSerializer();
        private Action<string> _logger;
        private PidState _tracked;
        private DateTime _lastListenerCheck = DateTime.MinValue;
        private bool _lastListenerHealthy;
        private string _listenerDetail = "not running";
        private DateTime _runtimeHashCheckedUtc = DateTime.MinValue;
        private DateTime _runtimeLastWriteUtc = DateTime.MinValue;
        private long _runtimeSize = -1;
        private bool _runtimeHealthy;

        public RelayEngine(string root, Action<string> logger)
        {
            _root = root;
            _runtime = Path.Combine(root, ".runtime");
            _output = Path.Combine(root, "output");
            _config = Path.Combine(_runtime, "config");
            _rollback = Path.Combine(_runtime, "rollback");
            _pidFile = Path.Combine(_runtime, "pids.json");
            _credentialsFile = Path.Combine(_runtime, "relay-credentials.json");
            _versionFile = Path.Combine(_runtime, "sing-box-version.txt");
            _runtimeHashFile = Path.Combine(_runtime, "sing-box-sha256.txt");
            _singBoxExe = Path.Combine(_runtime, "sing-box.exe");
            _frontExe = Path.Combine(_runtime, "BPSRMobileFront.exe");
            _starExe = Path.Combine(_runtime, "StarSEA.exe");
            _frontConfig = Path.Combine(_config, "pc-relay-front.json");
            _starConfig = Path.Combine(_config, "pc-relay-back.json");
            _androidConfig = Path.Combine(_output, "android-bpsr-relay.json");
            _profileMeta = Path.Combine(_output, "profile-meta.json");
            _phoneState = Path.Combine(_runtime, "phone-profile-state.json");
            _logFile = Path.Combine(_runtime, "manager.log");
            _qrHtml = Path.Combine(_output, "sfa-setup-qr.html");
            _logger = logger;
            EnsureDirectories();
            LoadTrackedState();
        }

        public string Root { get { return _root; } }
        public string OutputDirectory { get { return _output; } }
        public string QrHtmlPath { get { return _qrHtml; } }
        public string ListenerDetail { get { return _listenerDetail; } }
        public string ManagerVersion { get { return VersionInfo.Version; } }
        public string TestedSingBoxVersion { get { return VersionInfo.TestedSingBoxVersion; } }

        public void SetLogger(Action<string> logger) { _logger = logger; }

        public void Log(string message)
        {
            EnsureDirectories();
            string line = "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + message;
            try
            {
                RotateLog();
                File.AppendAllText(_logFile, line + Environment.NewLine, new UTF8Encoding(false));
            }
            catch { }
            if (_logger != null) _logger(line);
        }

        private void RotateLog()
        {
            try
            {
                if (!File.Exists(_logFile)) return;
                if (new FileInfo(_logFile).Length < 2097152) return;
                string backup = _logFile + ".1";
                if (File.Exists(backup)) File.Delete(backup);
                File.Move(_logFile, backup);
            }
            catch { }
        }

        private void EnsureDirectories()
        {
            Directory.CreateDirectory(_runtime);
            Directory.CreateDirectory(_output);
            Directory.CreateDirectory(_config);
            Directory.CreateDirectory(_rollback);
        }

        private void WriteTextAtomic(string path, string text)
        {
            string parent = Path.GetDirectoryName(path);
            if (!string.IsNullOrWhiteSpace(parent)) Directory.CreateDirectory(parent);
            string temp = path + ".tmp-" + Guid.NewGuid().ToString("N");
            File.WriteAllText(temp, text, new UTF8Encoding(false));
            try
            {
                if (File.Exists(path))
                {
                    try { File.Replace(temp, path, null); }
                    catch { File.Delete(path); File.Move(temp, path); }
                }
                else File.Move(temp, path);
            }
            finally { try { if (File.Exists(temp)) File.Delete(temp); } catch { } }
        }

        private void WriteJson<T>(string path, T value) { WriteTextAtomic(path, _json.Serialize(value)); }
        private T ReadJson<T>(string path) where T : class
        {
            try { return File.Exists(path) ? _json.Deserialize<T>(File.ReadAllText(path, Encoding.UTF8)) : null; }
            catch { return null; }
        }

        public List<LanAddress> GetLanAddresses() { return WindowsIntegration.GetLanAddresses(); }
        public bool IsLocalIp(string ip) { return WindowsIntegration.IsLocalIPv4(ip); }

        public string GetAdapterId(string ip)
        {
            LanAddress item = WindowsIntegration.FindLanAddress(ip);
            return item == null ? string.Empty : item.AdapterId;
        }

        public string GetAdapterName(string ip)
        {
            LanAddress item = WindowsIntegration.FindLanAddress(ip);
            return item == null ? "unknown" : item.InterfaceName;
        }

        public string GetNetworkCategory(string ip)
        {
            LanAddress item = WindowsIntegration.FindLanAddress(ip);
            return item == null ? "Unknown" : WindowsIntegration.GetNetworkCategory(item.AdapterId);
        }

        public bool FirewallReady(string ip)
        {
            LanAddress item = WindowsIntegration.FindLanAddress(ip);
            return item != null && WindowsIntegration.FirewallReady(ip, item.AdapterId);
        }

        public void AllowFirewall(string ip)
        {
            LanAddress item = RequireSelectedIp(ip);
            string exe = Process.GetCurrentProcess().MainModule.FileName;
            Log("Requesting Administrator permission for Private-LAN TCP+UDP relay rules on " + ip + ":" + FrontPort + "...");
            int exit = WindowsIntegration.RunElevatedFirewallHelper(exe, ip, item.AdapterId);
            // The elevated helper already shows the precise failure. Do not show a second generic error.
            if (exit != 0) { Log("Firewall setup did not finish. See the Administrator helper error message."); return; }
            if (!FirewallReady(ip)) throw new InvalidOperationException("The Private-network TCP+UDP firewall rules could not be verified after setup.");
            Log("Firewall ready: selected network Private; TCP+UDP; selected IP only; LocalSubnet remote only.");
        }

        private LanAddress RequireSelectedIp(string ip)
        {
            if (!WindowsIntegration.IsValidIPv4(ip)) throw new InvalidOperationException("Choose a valid PC LAN IPv4 address.");
            if (ip == "127.0.0.1" || ip.StartsWith("169.254.", StringComparison.Ordinal)) throw new InvalidOperationException("Choose the PC Wi-Fi/Ethernet LAN IPv4 that the phone can reach.");
            LanAddress item = WindowsIntegration.FindLanAddress(ip);
            if (item == null) throw new InvalidOperationException("The selected LAN IP is not currently assigned to this PC.");
            return item;
        }

        public string GetProfilePcIp()
        {
            ProfileMeta meta = ReadJson<ProfileMeta>(_profileMeta);
            return meta == null ? string.Empty : (meta.pcIp ?? string.Empty);
        }

        public string GetCurrentProfileId()
        {
            ProfileMeta meta = ReadJson<ProfileMeta>(_profileMeta);
            if (meta != null && !string.IsNullOrWhiteSpace(meta.profileId)) return meta.profileId;
            if (!File.Exists(_androidConfig)) return string.Empty;
            try { return Sha256File(_androidConfig); } catch { return string.Empty; }
        }

        public bool PhoneProfileConfirmed()
        {
            string id = GetCurrentProfileId();
            if (string.IsNullOrWhiteSpace(id)) return false;
            PhoneProfileState state = ReadJson<PhoneProfileState>(_phoneState);
            if (state != null && string.Equals(state.profileId, id, StringComparison.OrdinalIgnoreCase))
            {
                return state.reason == "confirmed" || state.reason == "user-confirmed-manual-import" || state.reason == "preserved-unchanged-profile";
            }
            ProfileMeta meta = ReadJson<ProfileMeta>(_profileMeta);
            return meta != null && string.IsNullOrWhiteSpace(meta.profileId) && File.Exists(_androidConfig);
        }

        public bool PhoneProfileDownloaded()
        {
            string id = GetCurrentProfileId();
            PhoneProfileState state = ReadJson<PhoneProfileState>(_phoneState);
            return !string.IsNullOrWhiteSpace(id) && state != null && string.Equals(state.profileId, id, StringComparison.OrdinalIgnoreCase) && state.reason == "profile-downloaded";
        }

        public void MarkPhoneProfileConfirmed(string reason)
        {
            string id = GetCurrentProfileId();
            if (string.IsNullOrWhiteSpace(id)) throw new InvalidOperationException("The current phone profile is missing.");
            WriteJson(_phoneState, new PhoneProfileState { profileId = id, confirmedUtc = DateTime.UtcNow.ToString("o"), reason = reason });
        }

        public void MarkPhoneProfileDownloaded()
        {
            string id = GetCurrentProfileId();
            // A second SFA/browser download cannot revoke explicit confirmation for this profile.
            if (string.IsNullOrWhiteSpace(id) || PhoneProfileConfirmed()) return;
            WriteJson(_phoneState, new PhoneProfileState { profileId = id, confirmedUtc = DateTime.UtcNow.ToString("o"), reason = "profile-downloaded" });
        }

        public bool RuntimeReady()
        {
            try
            {
                if (!File.Exists(_singBoxExe) || !File.Exists(_runtimeHashFile)) { _runtimeHealthy = false; return false; }
                FileInfo info = new FileInfo(_singBoxExe);
                DateTime now = DateTime.UtcNow;
                if (_runtimeHealthy && (now - _runtimeHashCheckedUtc).TotalSeconds < 30 &&
                    _runtimeSize == info.Length && _runtimeLastWriteUtc == info.LastWriteTimeUtc)
                    return true;
                string expected = File.ReadAllText(_runtimeHashFile).Trim().ToLowerInvariant();
                _runtimeHealthy = expected.Length == 64 && string.Equals(expected, Sha256File(_singBoxExe), StringComparison.OrdinalIgnoreCase);
                _runtimeHashCheckedUtc = now;
                _runtimeSize = info.Length;
                _runtimeLastWriteUtc = info.LastWriteTimeUtc;
                return _runtimeHealthy;
            }
            catch { _runtimeHealthy = false; return false; }
        }

        public string InstalledRuntimeVersion()
        {
            try { return File.Exists(_versionFile) ? File.ReadAllText(_versionFile).Trim() : string.Empty; }
            catch { return string.Empty; }
        }

        public void PrepareRelay(string ip)
        {
            RequireSelectedIp(ip);
            StopRelay();
            List<RelayProcessInfo> foreign = GetForeignRelayProcesses();
            if (foreign.Count > 0) throw new InvalidOperationException("Foreign or duplicate relay process detected. Close the old relay first.");
            Log("Setup / Repair started for " + ip + ".");
            EnsureTestedSingBox();
            RelayCredentials credentials = GetOrCreateCredentials();
            File.Copy(_singBoxExe, _frontExe, true);
            File.Copy(_singBoxExe, _starExe, true);
            if (Sha256File(_singBoxExe) != Sha256File(_frontExe) || Sha256File(_singBoxExe) != Sha256File(_starExe)) throw new InvalidOperationException("Relay runtime copy verification failed.");
            RemoveLegacyFiles();
            WriteRelayConfigs(ip, credentials);
            ValidateGeneratedConfigs(ip);
            Log("Setup / Repair complete. Native manager v" + VersionInfo.Version + " keeps the field-tested two-stage SOCKS5 route.");
        }

        private void EnsureTestedSingBox()
        {
            if (InstalledRuntimeVersion() == VersionInfo.TestedSingBoxVersion && RuntimeReady())
            {
                Log("Tested sing-box " + VersionInfo.TestedSingBoxVersion + " is already installed and verified.");
                return;
            }
            InstallSingBoxVersion(VersionInfo.TestedSingBoxVersion);
        }

        private void InstallSingBoxVersion(string version)
        {
            if (version != "v1.13.19") throw new InvalidOperationException("No pinned metadata is available for sing-box " + version + ".");
            bool arm = string.Equals(Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE"), "ARM64", StringComparison.OrdinalIgnoreCase) || string.Equals(Environment.GetEnvironmentVariable("PROCESSOR_ARCHITEW6432"), "ARM64", StringComparison.OrdinalIgnoreCase);
            string arch = arm ? "arm64" : "amd64";
            string asset = "sing-box-1.13.19-windows-" + arch + ".zip";
            string expected = arm ? "dbb6c4803f94a997fcc4a1cce313eff65a901abc197731b55109ea4fbd412c88" : "e011a4def2f5e2b143ed54adb2b1a20a6be407806ab4442f3667f1dd817a2c8d";
            string temp = Path.Combine(_runtime, "download-temp");
            try
            {
                if (Directory.Exists(temp)) Directory.Delete(temp, true);
                Directory.CreateDirectory(temp);
                string zip = Path.Combine(temp, asset);
                Log("Downloading tested sing-box " + version + " for Windows/" + arch + "...");
                using (WebClient client = new WebClient())
                {
                    client.Headers[HttpRequestHeader.UserAgent] = "BPSR-Android-DPSMeter-Relay";
                    client.DownloadFile("https://github.com/SagerNet/sing-box/releases/download/v1.13.19/" + asset, zip);
                }
                if (!string.Equals(Sha256File(zip), expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("SHA256 verification failed for the official sing-box archive.");
                string extract = Path.Combine(temp, "extracted");
                ZipFile.ExtractToDirectory(zip, extract);
                string found = FindFileRecursive(extract, "sing-box.exe");
                if (string.IsNullOrWhiteSpace(found)) throw new InvalidOperationException("The official archive did not contain sing-box.exe.");
                if (File.Exists(_singBoxExe) && InstalledRuntimeVersion() != version) SaveRollbackRuntime();
                File.Copy(found, _singBoxExe, true);
                WriteTextAtomic(_versionFile, version);
                WriteTextAtomic(_runtimeHashFile, Sha256File(_singBoxExe));
                Log("Installed tested sing-box " + version + ".");
            }
            finally { try { if (Directory.Exists(temp)) Directory.Delete(temp, true); } catch { } }
        }

        private static string FindFileRecursive(string root, string name)
        {
            foreach (string file in Directory.GetFiles(root, name, SearchOption.AllDirectories)) return file;
            return string.Empty;
        }

        private RelayCredentials GetOrCreateCredentials()
        {
            RelayCredentials existing = ReadJson<RelayCredentials>(_credentialsFile);
            if (existing != null && existing.mode == "v4-compatible-socks5" && existing.frontUsername == "bpsr" && IsHex32(existing.frontPassword) && existing.internalUsername == "internal" && IsHex32(existing.internalPassword)) return existing;
            RelayCredentials created = new RelayCredentials();
            created.mode = "v4-compatible-socks5";
            created.frontUsername = "bpsr";
            created.frontPassword = Guid.NewGuid().ToString("N");
            created.internalUsername = "internal";
            created.internalPassword = Guid.NewGuid().ToString("N");
            created.createdUtc = DateTime.UtcNow.ToString("o");
            WriteJson(_credentialsFile, created);
            Log("Generated persistent v4-compatible SOCKS5 credentials.");
            return created;
        }

        private static bool IsHex32(string value)
        {
            if (value == null || value.Length != 32) return false;
            foreach (char c in value) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
            return true;
        }

        private void WriteRelayConfigs(string ip, RelayCredentials credentials)
        {
            string oldId = GetCurrentProfileId();
            bool oldConfirmed = PhoneProfileConfirmed();
            int internalPort = FindFreeInternalPort();
            WritePcConfigs(ip, credentials, internalPort);

            Dictionary<string, object> android = new Dictionary<string, object>();
            android["log"] = Dict("disabled", true, "level", "error");
            android["dns"] = Dict("servers", new object[] { Dict("type", "local", "tag", "local") }, "strategy", "ipv4_only", "final", "local");
            android["inbounds"] = new object[] { Dict("type", "tun", "tag", "tun-in", "address", new object[] { "172.19.0.1/30" }, "auto_route", true, "route_exclude_address", new object[] { ip + "/32" }, "stack", "system") };
            android["outbounds"] = new object[] { Dict("type", "socks", "tag", "bpsr-pc", "server", ip, "server_port", FrontPort, "version", "5", "username", credentials.frontUsername, "password", credentials.frontPassword) };
            android["route"] = Dict("rules", new object[] { Dict("port", 53, "action", "hijack-dns") }, "final", "bpsr-pc");
            WriteTextAtomic(_androidConfig, _json.Serialize(android));
            string profileId = Sha256File(_androidConfig);
            WriteJson(_profileMeta, new ProfileMeta { managerVersion = VersionInfo.Version, profileId = profileId, pcIp = ip, relayPort = FrontPort, internalPort = internalPort, ingress = "v4-compatible-socks5", testedSingBoxVersion = VersionInfo.TestedSingBoxVersion, generatedUtc = DateTime.UtcNow.ToString("o") });
            if (oldConfirmed && !string.IsNullOrWhiteSpace(oldId) && string.Equals(oldId, profileId, StringComparison.OrdinalIgnoreCase)) MarkPhoneProfileConfirmed("preserved-unchanged-profile");
            else try { if (File.Exists(_phoneState)) File.Delete(_phoneState); } catch { }

            string notes = "BPSR Android DPSMeter Relay\r\n\r\nPC LAN IPv4 in this profile: " + ip + "\r\nPhone relay port: " + FrontPort + "\r\n\r\nSFA:\r\n- Use per-app mode / Proxy selected apps.\r\n- Select BPSR only.\r\n- Start SFA after Start Relay on the PC.\r\n\r\nDPS meter:\r\n- Universal capture target: StarSEA\r\n- Do NOT target BPSRMobileFront.\r\n\r\nTransport:\r\n- Android -> BPSRMobileFront -> localhost StarSEA -> game server.\r\n- Phone -> PC uses authenticated SOCKS5 on your trusted Private LAN.\r\n- Do not port-forward relay port " + FrontPort + ".\r\n";
            WriteTextAtomic(Path.Combine(_output, "IMPORT-THIS-PROFILE.txt"), notes);
        }

        private void WritePcConfigs(string ip, RelayCredentials credentials, int internalPort)
        {
            Dictionary<string, object> front = new Dictionary<string, object>();
            front["log"] = Dict("disabled", true, "level", "error");
            front["inbounds"] = new object[] { Dict("type", "socks", "tag", "phone-in", "listen", ip, "listen_port", FrontPort, "users", new object[] { Dict("username", credentials.frontUsername, "password", credentials.frontPassword) }) };
            front["outbounds"] = new object[] { Dict("type", "socks", "tag", "to-starsea", "server", "127.0.0.1", "server_port", internalPort, "version", "5", "username", credentials.internalUsername, "password", credentials.internalPassword) };
            front["route"] = Dict("final", "to-starsea");

            Dictionary<string, object> star = new Dictionary<string, object>();
            star["log"] = Dict("disabled", true, "level", "error");
            star["inbounds"] = new object[] { Dict("type", "socks", "tag", "internal-in", "listen", "127.0.0.1", "listen_port", internalPort, "users", new object[] { Dict("username", credentials.internalUsername, "password", credentials.internalPassword) }) };
            star["outbounds"] = new object[] { Dict("type", "direct", "tag", "direct") };
            star["route"] = Dict("auto_detect_interface", true, "final", "direct");
            WriteTextAtomic(_frontConfig, _json.Serialize(front));
            WriteTextAtomic(_starConfig, _json.Serialize(star));
        }

        private static Dictionary<string, object> Dict(params object[] values)
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            for (int i = 0; i + 1 < values.Length; i += 2) result[Convert.ToString(values[i])] = values[i + 1];
            return result;
        }

        private void ValidateGeneratedConfigs(string ip)
        {
            AssertTopology(ip);
            CheckSingBoxConfig(_frontConfig);
            CheckSingBoxConfig(_starConfig);
            CheckSingBoxConfig(_androidConfig);
            Log("Config validation passed: two-stage SOCKS5 topology, no sniffing/multiplex, one StarSEA game-server path.");
        }

        private void AssertTopology(string ip)
        {
            string front = File.ReadAllText(_frontConfig);
            string star = File.ReadAllText(_starConfig);
            string android = File.ReadAllText(_androidConfig);
            string all = front + "\n" + star + "\n" + android;
            RequireContains(front, "\"type\":\"socks\"");
            RequireContains(front, "\"server\":\"127.0.0.1\"");
            RequireContains(front, "\"listen\":\"" + ip + "\"");
            RequireContains(star, "\"listen\":\"127.0.0.1\"");
            RequireContains(star, "\"type\":\"direct\"");
            RequireContains(android, "\"final\":\"bpsr-pc\"");
            RequireContains(android, "route_exclude_address");
            RequireContains(android, ip + "/32");
            if (all.IndexOf("shadowsocks", StringComparison.OrdinalIgnoreCase) >= 0 || all.IndexOf("multiplex", StringComparison.OrdinalIgnoreCase) >= 0 || all.IndexOf("\"action\":\"sniff\"", StringComparison.OrdinalIgnoreCase) >= 0 || android.IndexOf("strict_route", StringComparison.OrdinalIgnoreCase) >= 0) throw new InvalidOperationException("Topology validation found a forbidden relay option.");
        }

        private static void RequireContains(string value, string needle)
        {
            if (value.IndexOf(needle, StringComparison.Ordinal) < 0) throw new InvalidOperationException("Topology validation is missing: " + needle);
        }

        private void CheckSingBoxConfig(string path)
        {
            if (!File.Exists(_singBoxExe)) throw new InvalidOperationException("sing-box runtime is missing.");
            ProcessStartInfo psi = new ProcessStartInfo(_singBoxExe, "check -c \"" + path + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardError = true;
            psi.RedirectStandardOutput = true;
            using (Process p = Process.Start(psi))
            {
                string output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                p.WaitForExit();
                if (p.ExitCode != 0) throw new InvalidOperationException("sing-box rejected " + Path.GetFileName(path) + ": " + output.Trim());
            }
        }

        private int FindFreeInternalPort()
        {
            for (int port = InternalPortStart; port <= InternalPortEnd; port++) if (CanBindTcp("127.0.0.1", port) && CanBindUdp("127.0.0.1", port)) return port;
            throw new InvalidOperationException("Could not find a free localhost bridge port.");
        }

        private static bool CanBindTcp(string ip, int port)
        {
            TcpListener listener = null;
            try { listener = new TcpListener(IPAddress.Parse(ip), port); listener.Start(); return true; }
            catch { return false; }
            finally { if (listener != null) try { listener.Stop(); } catch { } }
        }

        private static bool CanBindUdp(string ip, int port)
        {
            UdpClient udp = null;
            try { udp = new UdpClient(new IPEndPoint(IPAddress.Parse(ip), port)); return true; }
            catch { return false; }
            finally { if (udp != null) udp.Close(); }
        }

        private void AssertFrontPortFree(string ip)
        {
            if (!CanBindTcp(ip, FrontPort) || !CanBindUdp(ip, FrontPort)) throw new InvalidOperationException("Relay port " + FrontPort + " is already in use. Stop the conflicting program first.");
        }

        public void StartRelay(string ip)
        {
            RequireSelectedIp(ip);
            if (IsRelayRunning()) { Log("Relay is already running."); return; }
            StopRelay();
            if (!RuntimeReady() || GetProfilePcIp() != ip) throw new InvalidOperationException("Run Prepare Relay first.");
            if (!FirewallReady(ip)) throw new InvalidOperationException("The Windows Private-LAN firewall rule is not ready.");
            if (GetForeignRelayProcesses().Count > 0) throw new InvalidOperationException("Foreign or duplicate relay process detected.");
            AssertFrontPortFree(ip);
            // Verify the executable copies that will actually be launched, not only the master.
            if (!File.Exists(_frontExe) || !File.Exists(_starExe) ||
                !string.Equals(Sha256File(_singBoxExe), Sha256File(_frontExe), StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Sha256File(_singBoxExe), Sha256File(_starExe), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Relay executable integrity check failed. Run Prepare Relay to repair the copies.");
            RelayCredentials creds = GetOrCreateCredentials();
            int internalPort = FindFreeInternalPort();
            WritePcConfigs(ip, creds, internalPort);
            ValidateGeneratedConfigs(ip);

            Process star = null;
            Process front = null;
            try
            {
                star = StartHidden(_starExe, "run -c \"" + _starConfig + "\"");
                WaitForListener(star, "127.0.0.1", internalPort, "StarSEA");
                front = StartHidden(_frontExe, "run -c \"" + _frontConfig + "\"");
                WaitForListener(front, ip, FrontPort, "BPSRMobileFront");
                PidState state = new PidState();
                state.starPid = star.Id;
                state.starStartUtc = star.StartTime.ToUniversalTime().ToString("o");
                state.frontPid = front.Id;
                state.frontStartUtc = front.StartTime.ToUniversalTime().ToString("o");
                state.starPath = _starExe;
                state.frontPath = _frontExe;
                state.pcIp = ip;
                state.internalPort = internalPort;
                state.startedUtc = DateTime.UtcNow.ToString("o");
                WriteJson(_pidFile, state);
                _tracked = state;
                _lastListenerCheck = DateTime.MinValue;
                _lastListenerHealthy = true;
                _listenerDetail = "running";
                Log("Relay RUNNING: Android -> BPSRMobileFront PID " + front.Id + " -> localhost -> StarSEA PID " + star.Id + " -> game server.");
            }
            catch
            {
                SafeKill(front);
                SafeKill(star);
                try { if (File.Exists(_pidFile)) File.Delete(_pidFile); } catch { }
                _tracked = null;
                throw;
            }
        }

        private static Process StartHidden(string file, string args)
        {
            ProcessStartInfo psi = new ProcessStartInfo(file, args);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.WorkingDirectory = Path.GetDirectoryName(file);
            Process p = Process.Start(psi);
            if (p == null) throw new InvalidOperationException("Windows could not start " + Path.GetFileName(file) + ".");
            return p;
        }

        private static void WaitForListener(Process process, string ip, int port, string label)
        {
            for (int i = 0; i < 50; i++)
            {
                process.Refresh();
                if (process.HasExited) throw new InvalidOperationException(label + " exited during startup.");
                TcpClient client = new TcpClient();
                try
                {
                    IAsyncResult result = client.BeginConnect(ip, port, null, null);
                    if (result.AsyncWaitHandle.WaitOne(80) && client.Connected) { client.EndConnect(result); return; }
                }
                catch { }
                finally { try { client.Close(); } catch { } }
                Thread.Sleep(100);
            }
            throw new InvalidOperationException(label + " did not begin listening within 5 seconds.");
        }

        public bool IsRelayRunning()
        {
            if (_tracked == null) LoadTrackedState();
            if (_tracked == null) return false;
            if (!ExpectedProcess(_tracked.starPid, _starExe, _tracked.starStartUtc) || !ExpectedProcess(_tracked.frontPid, _frontExe, _tracked.frontStartUtc))
            {
                // A dead half must not leave the surviving process orphaned or reported healthy.
                StopRelay();
                _lastListenerHealthy = false;
                _listenerDetail = "relay process exited; remaining owned process cleaned up";
                Log("Relay process unexpectedly exited; remaining verified process stopped. Start Relay to reconnect.");
                return false;
            }
            if ((DateTime.UtcNow - _lastListenerCheck).TotalSeconds < 10) return _lastListenerHealthy;
            _lastListenerCheck = DateTime.UtcNow;
            _lastListenerHealthy = CanConnect(_tracked.pcIp, FrontPort) && CanConnect("127.0.0.1", _tracked.internalPort);
            _listenerDetail = _lastListenerHealthy ? "TCP listeners healthy; UDP remains on-demand" : "relay listener check failed";
            return _lastListenerHealthy;
        }

        private static bool CanConnect(string ip, int port)
        {
            if (string.IsNullOrWhiteSpace(ip) || port <= 0) return false;
            TcpClient client = new TcpClient();
            try
            {
                IAsyncResult result = client.BeginConnect(ip, port, null, null);
                if (!result.AsyncWaitHandle.WaitOne(120)) return false;
                client.EndConnect(result);
                return client.Connected;
            }
            catch { return false; }
            finally { try { client.Close(); } catch { } }
        }

        public void StopRelay()
        {
            PidState state = ReadJson<PidState>(_pidFile) ?? _tracked;
            if (state == null) { _tracked = null; return; }
            StopExpected(state.frontPid, _frontExe, state.frontStartUtc, "BPSRMobileFront");
            StopExpected(state.starPid, _starExe, state.starStartUtc, "StarSEA");
            try { if (File.Exists(_pidFile)) File.Delete(_pidFile); } catch { }
            _tracked = null;
            _lastListenerHealthy = false;
            _listenerDetail = "not running";
        }

        private void StopExpected(int pid, string expectedPath, string startUtc, string label)
        {
            if (!ExpectedProcess(pid, expectedPath, startUtc)) return;
            try { using (Process p = Process.GetProcessById(pid)) { p.Kill(); p.WaitForExit(3000); } Log("Stopped " + label + " (PID " + pid + ")."); }
            catch (Exception ex) { Log("Warning: could not stop " + label + ": " + ex.Message); }
        }

        private void LoadTrackedState()
        {
            PidState state = ReadJson<PidState>(_pidFile);
            if (state != null && ExpectedProcess(state.starPid, _starExe, state.starStartUtc) && ExpectedProcess(state.frontPid, _frontExe, state.frontStartUtc)) _tracked = state;
            else _tracked = null;
        }

        private static bool ExpectedProcess(int pid, string expectedPath, string startUtc)
        {
            if (pid <= 0 || string.IsNullOrWhiteSpace(expectedPath)) return false;
            try
            {
                using (Process p = Process.GetProcessById(pid))
                {
                    string actual = p.MainModule.FileName;
                    if (!string.Equals(Path.GetFullPath(actual), Path.GetFullPath(expectedPath), StringComparison.OrdinalIgnoreCase)) return false;
                    if (!string.IsNullOrWhiteSpace(startUtc))
                    {
                        DateTime expected = DateTime.Parse(startUtc).ToUniversalTime();
                        if (Math.Abs((p.StartTime.ToUniversalTime() - expected).TotalSeconds) > 2) return false;
                    }
                    return !p.HasExited;
                }
            }
            catch { return false; }
        }

        public List<RelayProcessInfo> GetForeignRelayProcesses()
        {
            List<RelayProcessInfo> result = new List<RelayProcessInfo>();
            AddForeignByName(result, "StarSEA", _starExe, _tracked == null ? 0 : _tracked.starPid);
            AddForeignByName(result, "BPSRMobileFront", _frontExe, _tracked == null ? 0 : _tracked.frontPid);
            AddForeignByName(result, "BPSRRelayIngress", Path.Combine(_runtime, "BPSRRelayIngress.exe"), 0);
            return result;
        }

        private static void AddForeignByName(List<RelayProcessInfo> list, string name, string expectedPath, int trackedPid)
        {
            foreach (Process p in Process.GetProcessesByName(name))
            {
                using (p)
                {
                    if (p.Id == trackedPid) continue;
                    RelayProcessInfo info = new RelayProcessInfo();
                    info.Name = name;
                    info.Id = p.Id;
                    try { info.StartUtc = p.StartTime.ToUniversalTime(); } catch { info.StartUtc = DateTime.MinValue; }
                    try { info.Path = p.MainModule.FileName; } catch { info.Path = string.Empty; }
                    info.ProjectOwned = !string.IsNullOrWhiteSpace(info.Path) && string.Equals(Path.GetFullPath(info.Path), Path.GetFullPath(expectedPath), StringComparison.OrdinalIgnoreCase);
                    list.Add(info);
                }
            }
        }

        public bool CloseForeignProjectRelay(RelayProcessInfo info)
        {
            if (info == null || !info.ProjectOwned || info.StartUtc == DateTime.MinValue) return false;
            string expected = info.Name == "StarSEA" ? _starExe : (info.Name == "BPSRMobileFront" ? _frontExe : Path.Combine(_runtime, "BPSRRelayIngress.exe"));
            if (!ExpectedProcess(info.Id, expected, info.StartUtc.ToString("o"))) return false;
            try { using (Process p = Process.GetProcessById(info.Id)) { p.Kill(); p.WaitForExit(3000); } Log("Closed old project relay " + info.Name + " (PID " + info.Id + ") after path/start-time verification."); return true; }
            catch { return false; }
        }

        public ProfileServer CreateProfileServer(string ip)
        {
            RequireSelectedIp(ip);
            if (!File.Exists(_androidConfig) || GetProfilePcIp() != ip) throw new InvalidOperationException("Run Prepare Relay first.");
            if (IsRelayRunning()) throw new InvalidOperationException("Stop the relay before starting Phone Setup.");
            if (!FirewallReady(ip)) throw new InvalidOperationException("Click Allow Firewall before Phone Setup.");
            if (GetForeignRelayProcesses().Count > 0) throw new InvalidOperationException("Close old relay processes before Phone Setup.");
            AssertFrontPortFree(ip);
            string token = Guid.NewGuid().ToString("N");
            ProfileServer server = new ProfileServer(ip, FrontPort, token, _androidConfig, GetCurrentProfileId(), delegate { MarkPhoneProfileDownloaded(); }, Log);
            server.Start();
            return server;
        }

        public string CreateQrHtml(string sfaImportUrl)
        {
            string library = Path.Combine(_root, "assets", "qrcode.min.js");
            if (!File.Exists(library)) throw new InvalidOperationException("Local QR component is missing. Re-extract the complete release ZIP.");
            string payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(sfaImportUrl));
            string html = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>BPSR Relay - SFA QR</title><style>body{font-family:Segoe UI,system-ui,sans-serif;background:#f4f7fb;color:#0f172a;margin:0;padding:32px}.card{max-width:520px;margin:auto;background:#fff;border:1px solid #dae1eb;border-radius:14px;padding:24px;box-sizing:border-box}#qrcode{display:flex;justify-content:center;padding:16px}</style></head><body><div class=\"card\"><h1>BPSR Relay - SFA setup</h1><p>On Android: SFA &gt; + &gt; Scan QR Code</p><div id=\"qrcode\"></div><p>Generated locally on this PC.</p></div><script>" + File.ReadAllText(library) + "\nvar value=window.atob('" + payload + "');new QRCode(document.getElementById('qrcode'),{text:value,width:420,height:420,colorDark:'#000000',colorLight:'#ffffff',correctLevel:QRCode.CorrectLevel.M});</script></body></html>";
            WriteTextAtomic(_qrHtml, html);
            return _qrHtml;
        }

        public string GetDpsNotes(string ip)
        {
            return "Universal DPS meter capture target: StarSEA\r\nPhysical network adapter: " + GetAdapterName(ip) + "\r\nConfigure the meter to detect/capture StarSEA. BPSRMobileFront is only the phone-facing proxy.\r\nZDPS example: Game Capture Preference = Custom; Custom BPSR Executable Name: StarSEA\r\nDo not target BPSRMobileFront or BPSRRelayIngress.";
        }

        public List<CheckResult> GetPreflightChecks(string ip)
        {
            List<CheckResult> checks = new List<CheckResult>();
            AddCheck(checks, "LAN IP", IsLocalIp(ip), ip, "Selected IP is not assigned to this PC.");
            AddCheck(checks, "Runtime", RuntimeReady(), InstalledRuntimeVersion() + " verified", "Run Prepare Relay first.");
            AddCheck(checks, "Android profile", GetProfilePcIp() == ip, "Current profile matches " + ip, "Run Prepare Relay to refresh the profile.");
            AddCheck(checks, "Phone import", PhoneProfileConfirmed(), "Current SFA profile manually confirmed.", "Import the current profile in SFA and confirm it in Start Relay; a download alone is insufficient.");
            AddCheck(checks, "Duplicate relay processes", GetForeignRelayProcesses().Count == 0, "No extra relay process detected.", "Old/duplicate relay process found.");
            AddCheck(checks, "Firewall", FirewallReady(ip), "Private-LAN TCP+UDP rules ready.", "Click Allow Firewall.");
            if (!IsRelayRunning()) AddCheck(checks, "Relay port", CanBindTcp(ip, FrontPort) && CanBindUdp(ip, FrontPort), "TCP+UDP " + FrontPort + " free.", "Port " + FrontPort + " is already in use.");
            return checks;
        }

        private static void AddCheck(List<CheckResult> checks, string name, bool ok, string okText, string failText)
        {
            checks.Add(new CheckResult { Name = name, State = ok ? "OK" : "FAIL", Detail = ok ? okText : failText });
        }

        public string GetDiagnostics(string ip)
        {
            string category = GetNetworkCategory(ip);
            return "BPSR Android DPSMeter Relay Diagnostics\r\nManager: " + VersionInfo.Version + " (native C# WinForms)\r\nTested sing-box: " + VersionInfo.TestedSingBoxVersion + "\r\nInstalled sing-box: " + InstalledRuntimeVersion() + "\r\nRuntime integrity: " + (RuntimeReady() ? "OK" : "FAIL/UNKNOWN") + "\r\n\r\nSelected PC IP: " + ip + "\r\nSelected adapter: " + GetAdapterName(ip) + "\r\nWindows network category: " + category + "\r\nProfile IP: " + GetProfilePcIp() + "\r\nFirewall: " + (FirewallReady(ip) ? "OK - Private LAN TCP+UDP" : "not ready") + "\r\n\r\nRelay running: " + IsRelayRunning() + "\r\nRelay listener health: " + _listenerDetail + "\r\nTopology: Android -> BPSRMobileFront -> localhost StarSEA -> game server\r\nIngress transport: authenticated SOCKS5 on trusted Private LAN\r\nAndroid protocol sniffing: DISABLED\r\nMultiplexing: DISABLED\r\n\r\nUniversal DPS meter target: StarSEA\r\nDo NOT target: BPSRMobileFront\r\n\r\nNo relay passwords or profile secrets are included in this diagnostic.";
        }

        public void RestorePreviousRuntime()
        {
            StopRelay();
            string exe = Path.Combine(_rollback, "sing-box.exe");
            string version = Path.Combine(_rollback, "version.txt");
            string hash = Path.Combine(_rollback, "sha256.txt");
            if (!File.Exists(exe) || !File.Exists(version) || !File.Exists(hash)) throw new InvalidOperationException("No previous verified runtime is available for rollback.");
            string expected = File.ReadAllText(hash).Trim().ToLowerInvariant();
            if (!string.Equals(expected, Sha256File(exe), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Rollback runtime integrity check failed.");
            File.Copy(exe, _singBoxExe, true);
            File.Copy(version, _versionFile, true);
            File.Copy(hash, _runtimeHashFile, true);
            File.Copy(_singBoxExe, _frontExe, true);
            File.Copy(_singBoxExe, _starExe, true);
            if (!RuntimeReady()) throw new InvalidOperationException("Restored runtime failed verification.");
            Log("Runtime rollback successful. Active sing-box: " + InstalledRuntimeVersion() + ".");
        }

        private void SaveRollbackRuntime()
        {
            if (!RuntimeReady() || string.IsNullOrWhiteSpace(InstalledRuntimeVersion())) return;
            Directory.CreateDirectory(_rollback);
            File.Copy(_singBoxExe, Path.Combine(_rollback, "sing-box.exe"), true);
            File.Copy(_versionFile, Path.Combine(_rollback, "version.txt"), true);
            File.Copy(_runtimeHashFile, Path.Combine(_rollback, "sha256.txt"), true);
        }

        private void RemoveLegacyFiles()
        {
            string[] paths = { Path.Combine(_runtime, "BPSRRelayIngress.exe"), Path.Combine(_config, "front-socks.json"), Path.Combine(_config, "relay-hidden.json"), Path.Combine(_config, "starsea-relay.json") };
            foreach (string path in paths) try { if (File.Exists(path)) File.Delete(path); } catch { }
        }

        public void RunSelfTest()
        {
            EnsureTestedSingBox();
            RelayCredentials credentials = GetOrCreateCredentials();
            File.Copy(_singBoxExe, _frontExe, true);
            File.Copy(_singBoxExe, _starExe, true);
            WriteRelayConfigs("192.0.2.10", credentials);
            ValidateGeneratedConfigs("192.0.2.10");
            string android = File.ReadAllText(_androidConfig);
            if (android.IndexOf("route_exclude_address", StringComparison.Ordinal) < 0 || android.IndexOf("\"final\":\"bpsr-pc\"", StringComparison.Ordinal) < 0) throw new InvalidOperationException("Native self-test found a broken Android relay route.");
        }

        private static Process SafeGetProcess(int pid) { try { return Process.GetProcessById(pid); } catch { return null; } }
        private static void SafeKill(Process process) { if (process == null) return; try { if (!process.HasExited) process.Kill(); } catch { } try { process.Dispose(); } catch { } }

        private static string Sha256File(string path)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream stream = File.OpenRead(path))
            {
                byte[] hash = sha.ComputeHash(stream);
                StringBuilder sb = new StringBuilder(hash.Length * 2);
                foreach (byte b in hash) sb.Append(b.ToString("x2"));
                return sb.ToString();
            }
        }
    }
}
