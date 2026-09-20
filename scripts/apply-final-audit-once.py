from pathlib import Path
import re


def patch(path, changes):
    p = Path(path)
    s = p.read_text(encoding='utf-8-sig')
    for old, new in changes:
        count = s.count(old)
        if count != 1:
            raise RuntimeError(f'{path}: expected exactly one anchor, got {count}: {old[:100]!r}')
        s = s.replace(old, new, 1)
    p.write_text(s, encoding='utf-8', newline='')
    print('Updated', path)

engine = 'src/BpsrRelayManager/RelayEngine.cs'
patch(engine, [
('''                    catch { File.Delete(path); File.Move(temp, path); }
''','''                    catch
                    {
                        // File.Replace may be unsupported on some filesystems. Keep a recoverable
                        // original until the replacement has actually reached its destination.
                        string backup = path + ".backup-" + Guid.NewGuid().ToString("N");
                        File.Copy(path, backup, false);
                        try
                        {
                            File.Delete(path);
                            File.Move(temp, path);
                        }
                        catch
                        {
                            if (!File.Exists(path)) File.Copy(backup, path, false);
                            throw;
                        }
                        finally { try { if (File.Exists(backup)) File.Delete(backup); } catch { } }
                    }
'''),
('''            ProfileMeta meta = ReadJson<ProfileMeta>(_profileMeta);
            return meta != null && string.IsNullOrWhiteSpace(meta.profileId) && File.Exists(_androidConfig);
        }

        public bool PhoneProfileDownloaded()''','''            // Legacy metadata without an explicit identity must not imply phone import.
            return false;
        }

        public bool PhoneProfileDownloaded()'''),
('''        public void MarkPhoneProfileDownloaded()
        {
            string id = GetCurrentProfileId();
            if (string.IsNullOrWhiteSpace(id) || PhoneProfileConfirmed()) return;
            WriteJson(_phoneState, new PhoneProfileState { profileId = id, confirmedUtc = DateTime.UtcNow.ToString("o"), reason = "profile-downloaded" });
        }

        public bool RuntimeReady''','''        public void MarkPhoneProfileDownloaded()
        {
            string id = GetCurrentProfileId();
            if (string.IsNullOrWhiteSpace(id) || PhoneProfileConfirmed()) return;
            WriteJson(_phoneState, new PhoneProfileState { profileId = id, confirmedUtc = DateTime.UtcNow.ToString("o"), reason = "profile-downloaded" });
        }

        private static bool ValidCredentials(RelayCredentials credentials)
        {
            return credentials != null && credentials.mode == "v4-compatible-socks5" &&
                credentials.frontUsername == "bpsr" && IsHex32(credentials.frontPassword) &&
                credentials.internalUsername == "internal" && IsHex32(credentials.internalPassword);
        }

        public bool ProfileReady(string ip)
        {
            try
            {
                ProfileMeta meta = ReadJson<ProfileMeta>(_profileMeta);
                RelayCredentials creds = ReadJson<RelayCredentials>(_credentialsFile);
                if (meta == null || string.IsNullOrWhiteSpace(meta.profileId) || meta.pcIp != ip ||
                    !File.Exists(_androidConfig) || !ValidCredentials(creds)) return false;
                if (!string.Equals(meta.profileId, Sha256File(_androidConfig), StringComparison.OrdinalIgnoreCase)) return false;
                string profile = File.ReadAllText(_androidConfig, Encoding.UTF8);
                // Parse values, rather than scanning JSON text, to avoid accepting stale or
                // unrelated credentials present in another field.
                Dictionary<string, object> config = _json.Deserialize<Dictionary<string, object>>(profile);
                if (config == null || !config.ContainsKey("outbounds")) return false;
                object[] outbounds = config["outbounds"] as object[];
                if (outbounds == null || outbounds.Length != 1) return false;
                Dictionary<string, object> outbound = outbounds[0] as Dictionary<string, object>;
                if (outbound == null) return false;
                return Convert.ToString(outbound["type"]) == "socks" &&
                    Convert.ToString(outbound["server"]) == ip &&
                    Convert.ToInt32(outbound["server_port"]) == FrontPort &&
                    Convert.ToString(outbound["username"]) == creds.frontUsername &&
                    Convert.ToString(outbound["password"]) == creds.frontPassword;
            }
            catch { return false; }
        }

        public bool RuntimeReady'''),
('''            if (existing != null && existing.mode == "v4-compatible-socks5" && existing.frontUsername == "bpsr" && IsHex32(existing.frontPassword) && existing.internalUsername == "internal" && IsHex32(existing.internalPassword)) return existing;''','''            if (ValidCredentials(existing)) return existing;'''),
('''            if (!RuntimeReady() || GetProfilePcIp() != ip) throw new InvalidOperationException("Run Prepare Relay first.");
            VerifyRuntimeCopies();''','''            if (!RuntimeReady() || !ProfileReady(ip)) throw new InvalidOperationException("PC setup, Android profile or relay credentials are missing or mismatched. Run Prepare Relay, reimport the generated profile in SFA if it changed, and confirm phone setup again.");
            VerifyRuntimeCopies();'''),
('''            RelayCredentials creds = GetOrCreateCredentials();
            int internalPort = FindFreeInternalPort();
            WritePcConfigs(ip, creds, internalPort);''','''            RelayCredentials creds = ReadJson<RelayCredentials>(_credentialsFile);
            if (!ValidCredentials(creds)) throw new InvalidOperationException("Relay credentials are missing or invalid. Run Prepare Relay and reimport the profile in SFA.");
            int internalPort = FindFreeInternalPort();
            WritePcConfigs(ip, creds, internalPort);'''),
('''            if (!File.Exists(_androidConfig) || GetProfilePcIp() != ip) throw new InvalidOperationException("Run Prepare Relay first.");''','''            if (!ProfileReady(ip)) throw new InvalidOperationException("Android profile or credentials are missing or mismatched. Run Prepare Relay first.");'''),
('''            AddCheck(checks, "Android profile", GetProfilePcIp() == ip, "Current profile matches " + ip, "Run Prepare Relay to refresh the profile.");''','''            AddCheck(checks, "Android profile", ProfileReady(ip), "Profile file, identity and credentials match " + ip, "Profile file, identity or credentials are missing/mismatched. Run Prepare Relay and reimport in SFA if changed.");''')
])

form = 'src/BpsrRelayManager/MainForm.cs'
patch(form, [
('''            ToolStripMenuItem stopExit = new ToolStripMenuItem("Stop Relay && Exit"); stopExit.Click += delegate { try { _engine.StopRelay(); } catch { } _forceExit = true; Close(); }; menu.Items.Add(stopExit);''','''            ToolStripMenuItem stopExit = new ToolStripMenuItem("Stop Relay && Exit"); stopExit.Click += delegate
            {
                if (_busy) return;
                try { _engine.StopRelay(); }
                catch (Exception ex) { ShowFriendlyError("Could not stop relay; manager will remain open", ex); return; }
                _forceExit = true;
                Close();
            }; menu.Items.Add(stopExit);'''),
('''            if (running)
            {
                SetStatus(_relayState, "Running", _success); SetStatus(_runtimeState, "Ready", _success); SetStatus(_profileState, _engine.PhoneProfileConfirmed() ? "Saved (phone not probed)" : "Not confirmed", _engine.PhoneProfileConfirmed() ? _success : _warning); SetStatus(_firewallState, "Ready", _success); _nextAction.Text = "Relay is running. Start SFA on your phone if needed, then open BPSR and play."; SetButtonStates(true, true, true, true, false); SetOverallState("RELAY RUNNING", _success, _successSoft); SetRecommendedAction(null); UpdateTray(true); return;
            }''','''            if (running)
            {
                bool degraded = _engine.ListenerDetail.IndexOf("degraded", StringComparison.OrdinalIgnoreCase) >= 0;
                bool profileReady = _engine.ProfileReady(selectedIp);
                bool firewallReady = _engine.FirewallReady(selectedIp);
                SetStatus(_relayState, degraded ? "Degraded" : "Running", degraded ? _warning : _success);
                SetStatus(_runtimeState, _engine.RuntimeReady() ? "Ready" : "Needs repair", _engine.RuntimeReady() ? _success : _danger);
                SetStatus(_profileState, !profileReady ? "Needs repair" : (_engine.PhoneProfileConfirmed() ? "Saved (phone not probed)" : "Not confirmed"), profileReady && _engine.PhoneProfileConfirmed() ? _success : _warning);
                SetStatus(_firewallState, firewallReady ? "Ready" : "Not ready", firewallReady ? _success : _danger);
                _nextAction.Text = degraded ? "Relay processes are alive but listener health is degraded. Open Details to diagnose; avoid interrupting a live game unnecessarily." : "Relay processes are running. Start SFA on your phone if needed, then open BPSR and play.";
                SetButtonStates(true, true, true, true, false);
                SetOverallState(degraded ? "RELAY DEGRADED" : "RELAY RUNNING", degraded ? _warning : _success, degraded ? _warningSoft : _successSoft);
                SetRecommendedAction(null); UpdateTray(true); return;
            }'''),
('''            bool profile = !string.IsNullOrWhiteSpace(ip) && _engine.GetProfilePcIp() == ip && _engine.IsLocalIp(ip); bool confirmed = profile && _engine.PhoneProfileConfirmed();''','''            bool profile = !string.IsNullOrWhiteSpace(ip) && _engine.IsLocalIp(ip) && _engine.ProfileReady(ip); bool confirmed = profile && _engine.PhoneProfileConfirmed();'''),
('''            _log.AppendText(line + Environment.NewLine); _log.SelectionStart = _log.TextLength; _log.ScrollToCaret();''','''            _log.AppendText(line + Environment.NewLine);
            if (_log.TextLength > 65536) _log.Text = _log.Text.Substring(_log.TextLength - 49152);
            _log.SelectionStart = _log.TextLength; _log.ScrollToCaret();''')
])

server = 'src/BpsrRelayManager/ProfileServer.cs'
patch(server, [('''                    catch { }
                    finally { if (client != null) try { client.Close(); } catch { } }
''','''                    catch (Exception ex)
                    {
                        // Do not log the token, URL or profile contents.
                        if (!_stop && _log != null) _log("Phone setup request failed: " + ex.GetType().Name);
                    }
                    finally { if (client != null) try { client.Close(); } catch { } }
''')])

version = 'src/BpsrRelayManager/VersionInfo.cs'
patch(version, [('public const string Version = "1.1.3";', 'public const string Version = "1.1.4";')])

print('Final reliability source changes applied; regression tests are added in a separate step.')
