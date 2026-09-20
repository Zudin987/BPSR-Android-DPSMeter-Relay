using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
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
            TestPhoneProfileConfirmation();
            TestProfileReadinessAndCredentialRotation();
        }

        private static void TestPhoneProfileConfirmation()
        {
            string root = Path.Combine(Path.GetTempPath(), "bpsr-phone-confirmation-test-" + Guid.NewGuid().ToString("N"));
            try
            {
                RelayEngine engine = new RelayEngine(root, null);
                string meta = Path.Combine(root, "output", "profile-meta.json");
                File.WriteAllText(meta, "{\"profileId\":\"profile-one\",\"pcIp\":\"192.0.2.10\"}", new UTF8Encoding(false));
                if (engine.PhoneProfileConfirmed()) throw new InvalidOperationException("Fresh profile incorrectly confirmed.");
                engine.MarkPhoneProfileDownloaded();
                if (engine.PhoneProfileConfirmed() || !engine.PhoneProfileDownloaded())
                    throw new InvalidOperationException("Downloading must not confirm phone import.");
                engine.MarkPhoneProfileConfirmed("user-confirmed-manual-import");
                if (!engine.PhoneProfileConfirmed()) throw new InvalidOperationException("Manual confirmation failed.");
                engine.MarkPhoneProfileDownloaded();
                if (!engine.PhoneProfileConfirmed() || engine.PhoneProfileDownloaded())
                    throw new InvalidOperationException("Repeated download erased explicit confirmation.");
                File.WriteAllText(meta, "{\"profileId\":\"profile-two\",\"pcIp\":\"192.0.2.10\"}", new UTF8Encoding(false));
                if (engine.PhoneProfileConfirmed()) throw new InvalidOperationException("Changed profile retained stale confirmation.");
                Console.WriteLine("NATIVE PHONE CONFIRMATION PASS: downloaded not imported; repeated download preserves confirmation; changed profile invalidates confirmation.");
            }
            finally
            {
                try { if (Directory.Exists(root)) Directory.Delete(root, true); } catch { }
            }
        }

        private static string ProfileHash(string path)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream file = File.OpenRead(path))
                return BitConverter.ToString(sha.ComputeHash(file)).Replace("-", "").ToLowerInvariant();
        }

        private static void TestProfileReadinessAndCredentialRotation()
        {
            string root = Path.Combine(Path.GetTempPath(), "bpsr-profile-readiness-test-" + Guid.NewGuid().ToString("N"));
            try
            {
                RelayEngine engine = new RelayEngine(root, null);
                string metaPath = Path.Combine(root, "output", "profile-meta.json");
                string profilePath = Path.Combine(root, "output", "android-bpsr-relay.json");
                string credentialsPath = Path.Combine(root, ".runtime", "relay-credentials.json");
                const string ip = "192.0.2.10";
                const string originalPassword = "11111111111111111111111111111111";
                const string changedPassword = "22222222222222222222222222222222";
                string profile = "{\"outbounds\":[{\"type\":\"socks\",\"server\":\"192.0.2.10\",\"server_port\":10808,\"username\":\"bpsr\",\"password\":\"" + originalPassword + "\"}]}";
                string credentials = "{\"mode\":\"v4-compatible-socks5\",\"frontUsername\":\"bpsr\",\"frontPassword\":\"" + originalPassword + "\",\"internalUsername\":\"internal\",\"internalPassword\":\"33333333333333333333333333333333\"}";
                File.WriteAllText(profilePath, profile, new UTF8Encoding(false));
                File.WriteAllText(credentialsPath, credentials, new UTF8Encoding(false));
                string identity = ProfileHash(profilePath);
                File.WriteAllText(metaPath, "{\"pcIp\":\"" + ip + "\",\"profileId\":\"" + identity + "\"}", new UTF8Encoding(false));
                if (!engine.ProfileReady(ip)) throw new InvalidOperationException("Matching generated profile was rejected.");
                if (engine.ProfileReady("192.0.2.11")) throw new InvalidOperationException("Wrong IP accepted.");
                File.Delete(profilePath);
                if (engine.ProfileReady(ip)) throw new InvalidOperationException("Missing Android file accepted as ready.");
                File.WriteAllText(profilePath, profile.Replace(originalPassword, changedPassword), new UTF8Encoding(false));
                if (engine.ProfileReady(ip)) throw new InvalidOperationException("Tampered Android profile hash was accepted.");
                File.WriteAllText(metaPath, "{\"pcIp\":\"" + ip + "\",\"profileId\":\"" + ProfileHash(profilePath) + "\"}", new UTF8Encoding(false));
                if (engine.ProfileReady(ip)) throw new InvalidOperationException("Stale PC credentials were accepted despite matching profile hash.");
                File.WriteAllText(profilePath, profile, new UTF8Encoding(false));
                File.WriteAllText(metaPath, "{\"pcIp\":\"" + ip + "\",\"profileId\":\"" + ProfileHash(profilePath) + "\"}", new UTF8Encoding(false));
                if (!engine.ProfileReady(ip)) throw new InvalidOperationException("Restored valid profile was rejected.");
                File.Delete(credentialsPath);
                if (engine.ProfileReady(ip)) throw new InvalidOperationException("Missing relay credentials were accepted.");
                File.WriteAllText(credentialsPath, credentials, new UTF8Encoding(false));
                File.WriteAllText(metaPath, "{\"pcIp\":\"" + ip + "\",\"profileId\":\"\"}", new UTF8Encoding(false));
                if (engine.PhoneProfileConfirmed() || engine.ProfileReady(ip)) throw new InvalidOperationException("Legacy missing profile identity was incorrectly accepted.");
                Console.WriteLine("NATIVE PROFILE READINESS PASS: matching profile, missing/tampered JSON, stale/missing credentials, wrong IP and legacy state.");
            }
            finally { try { if (Directory.Exists(root)) Directory.Delete(root, true); } catch { } }
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
