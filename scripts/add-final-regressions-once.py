from pathlib import Path

p = Path('src/BpsrRelayManager/WindowsApiSelfTest.cs')
s = p.read_text(encoding='utf-8-sig')
a = 'using System.Net.Sockets;\n'
assert s.count(a) == 1
s = s.replace(a, a + 'using System.Security.Cryptography;\n')
a = '            TestPhoneProfileConfirmation();\n'
assert s.count(a) == 1
s = s.replace(a, a + '            TestProfileReadinessAndCredentialRotation();\n')
marker = '        private static string HttpGet(string url, string method)\n'
assert s.count(marker) == 1
s = s.replace(marker, '''        private static string ProfileHash(string path)
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
                string profile = "{\\"outbounds\\":[{\\"type\\":\\"socks\\",\\"server\\":\\"192.0.2.10\\",\\"server_port\\":10808,\\"username\\":\\"bpsr\\",\\"password\\":\\"" + originalPassword + "\\"}]}";
                string credentials = "{\\"mode\\":\\"v4-compatible-socks5\\",\\"frontUsername\\":\\"bpsr\\",\\"frontPassword\\":\\"" + originalPassword + "\\",\\"internalUsername\\":\\"internal\\",\\"internalPassword\\":\\"33333333333333333333333333333333\\"}";
                File.WriteAllText(profilePath, profile, new UTF8Encoding(false));
                File.WriteAllText(credentialsPath, credentials, new UTF8Encoding(false));
                string identity = ProfileHash(profilePath);
                File.WriteAllText(metaPath, "{\\"pcIp\\":\\"" + ip + "\\",\\"profileId\\":\\"" + identity + "\\"}", new UTF8Encoding(false));
                if (!engine.ProfileReady(ip)) throw new InvalidOperationException("Matching generated profile was rejected.");
                if (engine.ProfileReady("192.0.2.11")) throw new InvalidOperationException("Wrong IP accepted.");
                File.Delete(profilePath);
                if (engine.ProfileReady(ip)) throw new InvalidOperationException("Missing Android file accepted as ready.");
                File.WriteAllText(profilePath, profile.Replace(originalPassword, changedPassword), new UTF8Encoding(false));
                if (engine.ProfileReady(ip)) throw new InvalidOperationException("Tampered Android profile hash was accepted.");
                File.WriteAllText(metaPath, "{\\"pcIp\\":\\"" + ip + "\\",\\"profileId\\":\\"" + ProfileHash(profilePath) + "\\"}", new UTF8Encoding(false));
                if (engine.ProfileReady(ip)) throw new InvalidOperationException("Stale PC credentials were accepted despite matching profile hash.");
                File.WriteAllText(profilePath, profile, new UTF8Encoding(false));
                File.WriteAllText(metaPath, "{\\"pcIp\\":\\"" + ip + "\\",\\"profileId\\":\\"" + ProfileHash(profilePath) + "\\"}", new UTF8Encoding(false));
                if (!engine.ProfileReady(ip)) throw new InvalidOperationException("Restored valid profile was rejected.");
                File.Delete(credentialsPath);
                if (engine.ProfileReady(ip)) throw new InvalidOperationException("Missing relay credentials were accepted.");
                File.WriteAllText(credentialsPath, credentials, new UTF8Encoding(false));
                File.WriteAllText(metaPath, "{\\"pcIp\\":\\"" + ip + "\\",\\"profileId\\":\\"\\"}", new UTF8Encoding(false));
                if (engine.PhoneProfileConfirmed() || engine.ProfileReady(ip)) throw new InvalidOperationException("Legacy missing profile identity was incorrectly accepted.");
                Console.WriteLine("NATIVE PROFILE READINESS PASS: matching profile, missing/tampered JSON, stale/missing credentials, wrong IP and legacy state.");
            }
            finally { try { if (Directory.Exists(root)) Directory.Delete(root, true); } catch { } }
        }

''' + marker)
p.write_text(s, encoding='utf-8', newline='')

p = Path('.github/workflows/validate.yml')
s = p.read_text(encoding='utf-8-sig')
a = "          foreach ($needle in @('GetNetworkCategory','HNetCfg.FwPolicy2','CurrentProfileTypes'))"
assert s.count(a) == 1
s = s.replace(a, "          foreach ($needle in @('TestProfileReadinessAndCredentialRotation','Missing Android file accepted','Stale PC credentials were accepted')) { if (-not $windowsTest.Contains($needle)) { throw ('Reliability regression guard missing: ' + $needle) } }\n" + a)
p.write_text(s, encoding='utf-8', newline='')

notes = Path('docs/releases/v1.1.4.md')
assert not notes.exists()
notes.write_text('''# BPSR Android DPSMeter Relay v1.1.4 (candidate)

## Recovery and correctness
- Reject missing or tampered Android profiles, invalid/missing relay credentials, incorrect PC IP and mismatched phone/PC credentials before starting or serving the phone profile. Run Prepare Relay and reimport the regenerated file in SFA when credentials change.
- Do not infer successful SFA import from a legacy profile file without explicit identity and confirmation.
- Preserve a backup of state files during the non-atomic filesystem fallback so failed replacements can restore the original.
- Keep the manager open with a visible error when Stop Relay & Exit cannot stop owned processes.
- Show degraded listener health and actual profile/firewall readiness separately from merely running processes.
- Report sanitized phone-setup request failures and cap UI log retention.

## Validation and release gating
- Windows CI covers native build, profile and confirmation regression tests, UI checks, two-stage authenticated TCP/UDP smoke, and package validation.
- A fresh Android/SFA test is required after these changes: import or reimport the new profile, BPSR-only per-app routing, real StarSEA DPS capture, game TCP/UDP, Wi-Fi recovery, repeated start/stop and resource use. CI is not a real-device substitute.
- Do not publish v1.1.4 solely because automated checks pass. Record genuine field-test results and confirm the exact-main commit passes Validate before running the gated release workflow.

## Updating
Close the manager and extract the release ZIP into the existing folder, keeping generated runtime/profile data. If a profile mismatch is reported, run Prepare Relay, reimport the generated local JSON into SFA and explicitly confirm it. Use StarSEA as the DPS meter capture target.
''', encoding='utf-8', newline='')
print('Added profile corruption / credential rotation / legacy-state regressions, CI guard and v1.1.4 candidate release notes.')
