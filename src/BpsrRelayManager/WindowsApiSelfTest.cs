using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace BpsrRelayManager
{
    internal static class WindowsApiSelfTest
    {
        public static void Run()
        {
            List<LanAddress> addresses = WindowsIntegration.GetLanAddresses();
            if (addresses.Count == 0)
            {
                throw new InvalidOperationException("Windows API self-test could not find an active non-loopback IPv4 adapter.");
            }

            string category = WindowsIntegration.GetNetworkCategory(addresses[0].AdapterId);
            if (string.Equals(category, "Unknown", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Network List Manager COM could not resolve the active adapter category.");
            }

            Type policyType = Type.GetTypeFromProgID("HNetCfg.FwPolicy2");
            if (policyType == null)
            {
                throw new InvalidOperationException("Windows Firewall COM policy object is unavailable.");
            }

            dynamic policy = Activator.CreateInstance(policyType);
            int currentProfiles = (int)policy.CurrentProfileTypes;
            if (currentProfiles <= 0)
            {
                throw new InvalidOperationException("Windows Firewall COM returned no active profile types.");
            }

            TestNativeProfileServer();
        }

        private static string HttpGet(string url, string method)
        {
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = method;
            request.Proxy = null;
            request.KeepAlive = false;
            request.Timeout = 3000;
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
            {
                if (response.StatusCode != HttpStatusCode.OK) throw new InvalidOperationException("Unexpected native profile HTTP status.");
                return reader.ReadToEnd();
            }
        }

        private static void TestNativeProfileServer()
        {
            string root = Path.Combine(Path.GetTempPath(), "bpsr-native-profile-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            ProfileServer server = null;
            try
            {
                string profilePath = Path.Combine(root, "profile.json");
                string payload = "{\"nativeProfileSelfTest\":\"ok\"}";
                File.WriteAllText(profilePath, payload, new UTF8Encoding(false));
                int port;
                TcpListener probe = new TcpListener(IPAddress.Loopback, 0);
                try { probe.Start(); port = ((IPEndPoint)probe.LocalEndpoint).Port; }
                finally { probe.Stop(); }

                int downloaded = 0;
                server = new ProfileServer("127.0.0.1", port, Guid.NewGuid().ToString("N"), profilePath,
                    "native-profile-test", delegate { Interlocked.Increment(ref downloaded); }, delegate(string unused) { });
                server.Start();

                HttpGet(server.ProfileUrl, "HEAD");
                if (downloaded != 0) throw new InvalidOperationException("HEAD must not mark a phone profile as downloaded.");
                if (HttpGet(server.ProfileUrl, "GET") != payload) throw new InvalidOperationException("First native profile download failed.");
                if (!server.Running) throw new InvalidOperationException("Native setup server closed before SFA's second fetch.");
                if (HttpGet(server.ProfileUrl, "GET") != payload) throw new InvalidOperationException("SFA repeated native profile fetch failed.");
                if (downloaded != 1) throw new InvalidOperationException("Profile callback must run once after real GET, not for HEAD or repeated GET.");

                bool rejected = false;
                try { HttpGet("http://127.0.0.1:" + port + "/wrong-token/android-bpsr-relay.json", "GET"); }
                catch (WebException ex)
                {
                    using (HttpWebResponse response = ex.Response as HttpWebResponse)
                    {
                        rejected = response != null && response.StatusCode == HttpStatusCode.NotFound;
                    }
                }
                if (!rejected) throw new InvalidOperationException("Native profile server accepted an incorrect setup token.");
                server.Stop();
                if (server.Running) throw new InvalidOperationException("Profile server failed to release its setup state.");
                Console.WriteLine("NATIVE PROFILE SELF-TEST PASS: HEAD, repeated SFA GET, one callback, token isolation and stop.");
            }
            finally
            {
                if (server != null) server.Dispose();
                try { Directory.Delete(root, true); } catch { }
            }
        }
    }
}
