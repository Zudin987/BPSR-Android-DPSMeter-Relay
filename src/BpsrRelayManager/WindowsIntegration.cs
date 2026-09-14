using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace BpsrRelayManager
{
    internal sealed class LanAddress
    {
        public string Address;
        public string InterfaceName;
        public string AdapterId;
        public bool HasGateway;
        public int Score;
    }

    internal static class WindowsIntegration
    {
        private const string FirewallBaseName = "BPSR Android DPSMeter Relay";
        private const string FirewallTcpName = "BPSR Android DPSMeter Relay TCP";
        private const string FirewallUdpName = "BPSR Android DPSMeter Relay UDP";
        private const int PrivateProfile = 2;

        public static List<LanAddress> GetLanAddresses()
        {
            List<LanAddress> result = new List<LanAddress>();
            foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                try
                {
                    if (nic.OperationalStatus != OperationalStatus.Up) continue;
                    if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback || nic.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;
                    IPInterfaceProperties props = nic.GetIPProperties();
                    bool hasGateway = false;
                    foreach (GatewayIPAddressInformation gw in props.GatewayAddresses)
                    {
                        if (gw.Address != null && gw.Address.AddressFamily == AddressFamily.InterNetwork && !gw.Address.Equals(IPAddress.Any)) { hasGateway = true; break; }
                    }
                    foreach (UnicastIPAddressInformation unicast in props.UnicastAddresses)
                    {
                        IPAddress ip = unicast.Address;
                        if (ip == null || ip.AddressFamily != AddressFamily.InterNetwork) continue;
                        string text = ip.ToString();
                        if (text == "127.0.0.1" || text.StartsWith("169.254.", StringComparison.Ordinal)) continue;
                        int score = 0;
                        if (hasGateway) score += 100;
                        if (nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 || nic.NetworkInterfaceType == NetworkInterfaceType.Ethernet || nic.NetworkInterfaceType == NetworkInterfaceType.GigabitEthernet) score += 30;
                        if (IsPrivateIPv4(text)) score += 20;
                        string name = nic.Name ?? string.Empty;
                        if (name.IndexOf("vEthernet", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            name.IndexOf("VMware", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            name.IndexOf("VirtualBox", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            name.IndexOf("WSL", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            name.IndexOf("Tailscale", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            name.IndexOf("WireGuard", StringComparison.OrdinalIgnoreCase) >= 0) score -= 100;
                        result.Add(new LanAddress { Address = text, InterfaceName = name, AdapterId = nic.Id, HasGateway = hasGateway, Score = score });
                    }
                }
                catch { }
            }
            result.Sort(delegate(LanAddress a, LanAddress b) { return b.Score.CompareTo(a.Score); });
            return result;
        }

        public static LanAddress FindLanAddress(string ip)
        {
            foreach (LanAddress item in GetLanAddresses()) if (string.Equals(item.Address, ip, StringComparison.OrdinalIgnoreCase)) return item;
            return null;
        }

        public static bool IsLocalIPv4(string ip)
        {
            return FindLanAddress(ip) != null;
        }

        public static bool IsValidIPv4(string value)
        {
            IPAddress parsed;
            return IPAddress.TryParse(value, out parsed) && parsed.AddressFamily == AddressFamily.InterNetwork;
        }

        public static string GetNetworkCategory(string adapterId)
        {
            try
            {
                dynamic manager = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B")));
                IEnumerable connections = (IEnumerable)manager.GetNetworkConnections();
                Guid expected;
                if (!Guid.TryParse(adapterId, out expected)) return "Unknown";
                foreach (object raw in connections)
                {
                    dynamic connection = raw;
                    Guid actual = (Guid)connection.GetAdapterId();
                    if (actual != expected) continue;
                    dynamic network = connection.GetNetwork();
                    int category = (int)network.GetCategory();
                    if (category == 0) return "Public";
                    if (category == 1) return "Private";
                    if (category == 2) return "DomainAuthenticated";
                }
            }
            catch { }
            return "Unknown";
        }

        public static void MakeNetworkPrivate(string adapterId)
        {
            dynamic manager = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B")));
            IEnumerable connections = (IEnumerable)manager.GetNetworkConnections();
            Guid expected;
            if (!Guid.TryParse(adapterId, out expected)) throw new InvalidOperationException("The selected Windows adapter ID is invalid.");
            foreach (object raw in connections)
            {
                dynamic connection = raw;
                Guid actual = (Guid)connection.GetAdapterId();
                if (actual != expected) continue;
                dynamic network = connection.GetNetwork();
                int category = (int)network.GetCategory();
                if (category == 2) return;
                if (category != 1) network.SetCategory(1);
                return;
            }
            throw new InvalidOperationException("Windows could not find the selected network connection.");
        }

        public static void InstallFirewallRules(string ip)
        {
            if (!IsValidIPv4(ip)) throw new InvalidOperationException("The selected LAN IPv4 address is invalid.");
            dynamic policy = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2"));
            RemoveRule(policy, FirewallBaseName);
            RemoveRule(policy, FirewallTcpName);
            RemoveRule(policy, FirewallUdpName);
            AddRule(policy, FirewallTcpName, ip, 6);
            AddRule(policy, FirewallUdpName, ip, 17);
        }

        public static bool FirewallReady(string ip, string adapterId)
        {
            if (string.IsNullOrWhiteSpace(ip) || string.IsNullOrWhiteSpace(adapterId)) return false;
            string category = GetNetworkCategory(adapterId);
            if (!string.Equals(category, "Private", StringComparison.OrdinalIgnoreCase) && !string.Equals(category, "DomainAuthenticated", StringComparison.OrdinalIgnoreCase)) return false;
            try
            {
                dynamic policy = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2"));
                return RuleMatches(policy, FirewallTcpName, ip, 6) && RuleMatches(policy, FirewallUdpName, ip, 17);
            }
            catch { return false; }
        }

        private static void AddRule(dynamic policy, string name, string ip, int protocol)
        {
            dynamic rule = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FWRule"));
            rule.Name = name;
            rule.Description = "Allow BPSR phone relay only from the local subnet on the selected Private network.";
            rule.Protocol = protocol;
            rule.LocalPorts = "10808";
            rule.LocalAddresses = ip;
            rule.RemoteAddresses = "LocalSubnet";
            rule.Direction = 1;
            rule.Enabled = true;
            rule.Profiles = PrivateProfile;
            rule.EdgeTraversal = false;
            rule.Action = 1;
            policy.Rules.Add(rule);
        }

        private static void RemoveRule(dynamic policy, string name)
        {
            for (int i = 0; i < 4; i++)
            {
                try { policy.Rules.Remove(name); }
                catch { break; }
            }
        }

        private static bool RuleMatches(dynamic policy, string name, string ip, int protocol)
        {
            try
            {
                dynamic rule = policy.Rules.Item(name);
                if (!(bool)rule.Enabled) return false;
                if ((int)rule.Direction != 1 || (int)rule.Action != 1 || (int)rule.Protocol != protocol) return false;
                if ((((int)rule.Profiles) & PrivateProfile) == 0) return false;
                string ports = Convert.ToString(rule.LocalPorts) ?? string.Empty;
                string local = Convert.ToString(rule.LocalAddresses) ?? string.Empty;
                string remote = Convert.ToString(rule.RemoteAddresses) ?? string.Empty;
                return ContainsCsv(ports, "10808") && ContainsCsv(local, ip) && (ContainsCsv(remote, "LocalSubnet") || ContainsCsv(remote, "LocalSubnet4"));
            }
            catch { return false; }
        }

        private static bool ContainsCsv(string value, string expected)
        {
            foreach (string part in (value ?? string.Empty).Split(',')) if (string.Equals(part.Trim(), expected, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        private static bool IsPrivateIPv4(string ip)
        {
            if (ip.StartsWith("10.", StringComparison.Ordinal) || ip.StartsWith("192.168.", StringComparison.Ordinal)) return true;
            string[] parts = ip.Split('.');
            int second;
            return parts.Length == 4 && parts[0] == "172" && int.TryParse(parts[1], out second) && second >= 16 && second <= 31;
        }

        public static int RunElevatedFirewallHelper(string executablePath, string ip, string adapterId)
        {
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = executablePath;
            start.Arguments = "--firewall-helper --ip \"" + ip.Replace("\"", string.Empty) + "\" --adapter \"" + adapterId.Replace("\"", string.Empty) + "\"";
            start.UseShellExecute = true;
            start.Verb = "runas";
            start.WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory;
            Process process = Process.Start(start);
            if (process == null) throw new InvalidOperationException("Windows could not start the Administrator helper.");
            using (process)
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }
    }
}
