"""One-time, fail-closed source edits for PR #25; removed in the resulting commit."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def patch(path, before, after):
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    count = text.count(before)
    if count != 1:
        raise RuntimeError("Expected exactly one anchor in %s, found %d: %r" % (path, count, before[:90]))
    target.write_text(text.replace(before, after, 1), encoding="utf-8", newline="\n")
    print("Patched:", path, before[:64].replace("\n", " "))


E = "src/BpsrRelayManager/RelayEngine.cs"
M = "src/BpsrRelayManager/MainForm.cs"
P = "src/BpsrRelayManager/ProfileServer.cs"

# Cache both the verified executable and the expectation file. Never trust the
# status cache for security-sensitive startup and executable-copy repairs.
patch(E,
'''        private DateTime _runtimeCacheWriteUtc = DateTime.MinValue;
        private long _runtimeCacheLength = -1;
        private bool _runtimeCacheReady;''',
'''        private DateTime _runtimeCacheWriteUtc = DateTime.MinValue;
        private long _runtimeCacheLength = -1;
        private DateTime _runtimeHashCacheWriteUtc = DateTime.MinValue;
        private long _runtimeHashCacheLength = -1;
        private bool _runtimeCacheReady;''')

patch(E,
'''        public bool RuntimeReady()
        {
            if (!File.Exists(_singBoxExe) || !File.Exists(_runtimeHashFile))
            {
                _runtimeCacheReady = false;
                _runtimeCacheWriteUtc = DateTime.MinValue;
                _runtimeCacheLength = -1;
                return false;
            }
            try
            {
                FileInfo info = new FileInfo(_singBoxExe);
                if (_runtimeCacheWriteUtc == info.LastWriteTimeUtc && _runtimeCacheLength == info.Length) return _runtimeCacheReady;
                string expected = File.ReadAllText(_runtimeHashFile).Trim().ToLowerInvariant();
                bool ready = expected.Length == 64 && string.Equals(expected, Sha256File(_singBoxExe), StringComparison.OrdinalIgnoreCase);
                _runtimeCacheWriteUtc = info.LastWriteTimeUtc;
                _runtimeCacheLength = info.Length;
                _runtimeCacheReady = ready;
                return ready;
            }
            catch
            {
                _runtimeCacheReady = false;
                return false;
            }
        }''',
'''        public bool RuntimeReady(bool forceVerification = false)
        {
            if (!File.Exists(_singBoxExe) || !File.Exists(_runtimeHashFile))
            {
                ResetRuntimeCache();
                return false;
            }
            try
            {
                FileInfo info = new FileInfo(_singBoxExe);
                FileInfo expectedInfo = new FileInfo(_runtimeHashFile);
                if (!forceVerification && _runtimeCacheWriteUtc == info.LastWriteTimeUtc &&
                    _runtimeCacheLength == info.Length &&
                    _runtimeHashCacheWriteUtc == expectedInfo.LastWriteTimeUtc &&
                    _runtimeHashCacheLength == expectedInfo.Length) return _runtimeCacheReady;
                string expected = File.ReadAllText(_runtimeHashFile).Trim().ToLowerInvariant();
                bool ready = expected.Length == 64 && string.Equals(expected, Sha256File(_singBoxExe), StringComparison.OrdinalIgnoreCase);
                _runtimeCacheWriteUtc = info.LastWriteTimeUtc;
                _runtimeCacheLength = info.Length;
                _runtimeHashCacheWriteUtc = expectedInfo.LastWriteTimeUtc;
                _runtimeHashCacheLength = expectedInfo.Length;
                _runtimeCacheReady = ready;
                return ready;
            }
            catch
            {
                ResetRuntimeCache();
                return false;
            }
        }

        private void ResetRuntimeCache()
        {
            _runtimeCacheReady = false;
            _runtimeCacheWriteUtc = DateTime.MinValue;
            _runtimeCacheLength = -1;
            _runtimeHashCacheWriteUtc = DateTime.MinValue;
            _runtimeHashCacheLength = -1;
        }''')

patch(E,
'''            File.Copy(_singBoxExe, _frontExe, true);
            File.Copy(_singBoxExe, _starExe, true);
            VerifyRuntimeCopies();
            RemoveLegacyFiles();''',
'''            VerifyRuntimeCopies();
            RemoveLegacyFiles();''')

patch(E,
'''                _runtimeCacheWriteUtc = DateTime.MinValue;
                _runtimeCacheLength = -1;
                Log("Installed tested sing-box " + version + ".");''',
'''                ResetRuntimeCache();
                Log("Installed tested sing-box " + version + ".");''')

patch(E,
'''        private void VerifyRuntimeCopies()
        {
            if (!RuntimeReady()) throw new InvalidOperationException("The verified sing-box runtime is not ready.");
            string expected = Sha256File(_singBoxExe);
            if (!File.Exists(_frontExe) || !string.Equals(Sha256File(_frontExe), expected, StringComparison.OrdinalIgnoreCase)) File.Copy(_singBoxExe, _frontExe, true);
            if (!File.Exists(_starExe) || !string.Equals(Sha256File(_starExe), expected, StringComparison.OrdinalIgnoreCase)) File.Copy(_singBoxExe, _starExe, true);
            if (!string.Equals(Sha256File(_frontExe), expected, StringComparison.OrdinalIgnoreCase) || !string.Equals(Sha256File(_starExe), expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Relay runtime copy verification failed.");
        }''',
'''        private void VerifyRuntimeCopies()
        {
            // Force a fresh digest before trusting the primary executable for startup or repair.
            if (!RuntimeReady(true)) throw new InvalidOperationException("The verified sing-box runtime is not ready.");
            string expected = File.ReadAllText(_runtimeHashFile).Trim();
            VerifyRuntimeCopy(_frontExe, expected);
            VerifyRuntimeCopy(_starExe, expected);
        }

        private void VerifyRuntimeCopy(string path, string expected)
        {
            // A healthy copy needs one hash, not two. Only rehash when repairing it.
            if (File.Exists(path) && string.Equals(Sha256File(path), expected, StringComparison.OrdinalIgnoreCase)) return;
            File.Copy(_singBoxExe, path, true);
            if (!string.Equals(Sha256File(path), expected, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Relay runtime copy verification failed: " + Path.GetFileName(path));
        }''')

patch(E,
'''                    if (result.AsyncWaitHandle.WaitOne(80) && client.Connected) { client.EndConnect(result); return; }''',
'''                    using (WaitHandle wait = result.AsyncWaitHandle)
                    {
                        if (wait.WaitOne(80)) { client.EndConnect(result); if (client.Connected) return; }
                    }''')
patch(E,
'''            throw new InvalidOperationException(label + " did not begin listening within 5 seconds.");''',
'''            throw new InvalidOperationException(label + " did not begin listening within approximately 9 seconds.");''')

patch(E,
'''                PidState failed = _tracked;
                _lastListenerHealthy = false;
                _listenerDetail = "tracked relay process exited or changed";
                StopExpected(failed.frontPid, _frontExe, failed.frontStartUtc, "BPSRMobileFront");
                StopExpected(failed.starPid, _starExe, failed.starStartUtc, "StarSEA");
                try { if (File.Exists(_pidFile)) File.Delete(_pidFile); } catch { }
                _tracked = null;
                Log("Relay fault detected; cleaned up the remaining owned relay process. Start Relay again when ready.");
                return false;''',
'''                _lastListenerHealthy = false;
                _listenerDetail = "tracked relay process exited or changed";
                try
                {
                    StopRelay();
                    _listenerDetail = "tracked process exited; owned survivor stopped";
                    Log("Relay fault detected; stopped the remaining owned relay process. Start Relay again when ready.");
                }
                catch (Exception ex)
                {
                    _listenerDetail = "relay fault; owned process cleanup incomplete";
                    Log("Relay fault cleanup failed: " + ex.Message);
                }
                return false;''')

patch(E,
'''            if ((DateTime.UtcNow - _lastListenerCheck).TotalSeconds < 10) return _lastListenerHealthy;
            _lastListenerCheck = DateTime.UtcNow;
            _lastListenerHealthy = CanConnect(_tracked.pcIp, FrontPort) && CanConnect("127.0.0.1", _tracked.internalPort);
            _listenerDetail = _lastListenerHealthy ? "TCP listeners healthy; UDP remains on-demand" : "relay listener check failed";
            return _lastListenerHealthy;''',
'''            // Listener failures mean degraded health, not dead processes. Do not tear down a
            // live game session or restart it merely because a cached probe timed out.
            if ((DateTime.UtcNow - _lastListenerCheck).TotalSeconds < 10) return true;
            _lastListenerCheck = DateTime.UtcNow;
            _lastListenerHealthy = CanConnect(_tracked.pcIp, FrontPort) && CanConnect("127.0.0.1", _tracked.internalPort);
            _listenerDetail = _lastListenerHealthy ? "TCP listeners healthy; UDP remains on-demand" : "processes alive; TCP listener health degraded (check connection)";
            return true;''')

patch(E,
'''                if (!result.AsyncWaitHandle.WaitOne(120)) return false;
                client.EndConnect(result);''',
'''                using (WaitHandle wait = result.AsyncWaitHandle)
                {
                    if (!wait.WaitOne(120)) return false;
                }
                client.EndConnect(result);''')

patch(E,
'''            StopExpected(state.frontPid, _frontExe, state.frontStartUtc, "BPSRMobileFront");
            StopExpected(state.starPid, _starExe, state.starStartUtc, "StarSEA");
            try { if (File.Exists(_pidFile)) File.Delete(_pidFile); } catch { }''',
'''            bool frontStopped = StopExpected(state.frontPid, _frontExe, state.frontStartUtc, "BPSRMobileFront");
            bool starStopped = StopExpected(state.starPid, _starExe, state.starStartUtc, "StarSEA");
            if (!frontStopped || !starStopped)
            {
                _listenerDetail = "relay shutdown incomplete; tracked process details preserved";
                throw new InvalidOperationException("One or more relay processes could not be stopped. Check diagnostics and retry before restarting.");
            }
            try { if (File.Exists(_pidFile)) File.Delete(_pidFile); } catch { }''')

patch(E,
'''        private void StopExpected(int pid, string expectedPath, string startUtc, string label)
        {
            if (!ExpectedProcess(pid, expectedPath, startUtc)) return;
            try { using (Process p = Process.GetProcessById(pid)) { p.Kill(); p.WaitForExit(3000); } Log("Stopped " + label + " (PID " + pid + ")."); }
            catch (Exception ex) { Log("Warning: could not stop " + label + ": " + ex.Message); }
        }''',
'''        private bool StopExpected(int pid, string expectedPath, string startUtc, string label)
        {
            if (!ExpectedProcess(pid, expectedPath, startUtc)) return true;
            try
            {
                using (Process p = Process.GetProcessById(pid))
                {
                    p.Kill();
                    if (!p.WaitForExit(3000))
                    {
                        Log("Warning: timed out stopping " + label + " (PID " + pid + ").");
                        return false;
                    }
                }
                Log("Stopped " + label + " (PID " + pid + ").");
                return true;
            }
            catch (Exception ex)
            {
                Log("Warning: could not stop " + label + ": " + ex.Message);
                return !ExpectedProcess(pid, expectedPath, startUtc);
            }
        }''')

patch(E,
'''        public List<CheckResult> GetPreflightChecks(string ip)''',
'''        public List<CheckResult> GetPreflightChecks(string ip, bool phoneSetupActive = false)''')
patch(E,
'''            if (!IsRelayRunning()) AddCheck(checks, "Relay port", CanBindTcp(ip, FrontPort) && CanBindUdp(ip, FrontPort), "TCP+UDP " + FrontPort + " free.", "Port " + FrontPort + " is already in use.");''',
'''            if (!IsRelayRunning())
            {
                bool available = phoneSetupActive ? CanBindUdp(ip, FrontPort) : (CanBindTcp(ip, FrontPort) && CanBindUdp(ip, FrontPort));
                AddCheck(checks, "Relay port", available,
                    phoneSetupActive ? "This manager's temporary phone-setup server owns TCP " + FrontPort + "; Start Relay closes it first." : "TCP+UDP " + FrontPort + " free.",
                    "Port " + FrontPort + " is unavailable for the relay.");
            }''')

patch(E,
'''            _runtimeCacheWriteUtc = DateTime.MinValue;
            _runtimeCacheLength = -1;
            File.Copy(_singBoxExe, _frontExe, true);''',
'''            ResetRuntimeCache();
            File.Copy(_singBoxExe, _frontExe, true);''')

# UI operations may wait for process startup/shutdown, hashing or rollback copies.
# Use the existing busy guard and task runner rather than freezing WinForms.
patch(M, '''                _timer.Interval = 3000;''', '''                _timer.Interval = 5000;''')

patch(M,
'''        private void StartRelayGuided()
        {
            try
            {
                string ip = SelectedIp();
                if (!_engine.PhoneProfileConfirmed())
                {
                    bool downloaded = _engine.PhoneProfileDownloaded();
                    DialogResult choice;
                    using (Form prompt = CreatePhoneSetupPrompt(downloaded)) choice = prompt.ShowDialog(this);
                    if (choice == DialogResult.Yes) { StartPhoneSetupGuided(); return; }
                    if (choice == DialogResult.No) _engine.MarkPhoneProfileConfirmed("user-confirmed-manual-import"); else return;
                }
                StopProfileServer();
                _engine.StartRelay(ip);
            }
            catch (Exception ex) { ShowFriendlyError("Could not start relay", ex); }
            finally { UpdateStatus(); }
        }''',
'''        private async void StartRelayGuided()
        {
            if (_busy) return;
            bool started = false;
            try
            {
                string ip = SelectedIp();
                if (!_engine.PhoneProfileConfirmed())
                {
                    bool downloaded = _engine.PhoneProfileDownloaded();
                    DialogResult choice;
                    using (Form prompt = CreatePhoneSetupPrompt(downloaded)) choice = prompt.ShowDialog(this);
                    if (choice == DialogResult.Yes) { StartPhoneSetupGuided(); return; }
                    if (choice == DialogResult.No) _engine.MarkPhoneProfileConfirmed("user-confirmed-manual-import"); else return;
                }
                StopProfileServer();
                BeginSetupAction(_start, "Starting...", "Starting both relay stages and validating local listeners...");
                started = true;
                await Task.Run(delegate { _engine.StartRelay(ip); });
            }
            catch (Exception ex) { ShowFriendlyError("Could not start relay", ex); }
            finally
            {
                if (started) EndSetupAction(_start, "Start Relay");
                else UpdateStatus();
            }
        }''')

patch(M,
'''        private void StopRelayGuided()
        {
            if (!_engine.IsRelayRunning()) return;
            if (MessageBox.Show("Stop the relay now?\\r\\n\\r\\nIf BPSR is using this relay, stopping it can interrupt the phone's game connection.", "Stop relay?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            try { _engine.StopRelay(); }
            catch (Exception ex) { ShowFriendlyError("Could not stop relay", ex); }
            finally { UpdateStatus(); }
        }''',
'''        private async void StopRelayGuided()
        {
            if (_busy || !_engine.IsRelayRunning()) return;
            if (MessageBox.Show("Stop the relay now?\\r\\n\\r\\nIf BPSR is using this relay, stopping it can interrupt the phone's game connection.", "Stop relay?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            BeginSetupAction(_stop, "Stopping...", "Stopping both relay stages safely...");
            try { await Task.Run(delegate { _engine.StopRelay(); }); }
            catch (Exception ex) { ShowFriendlyError("Could not stop relay", ex); }
            finally { EndSetupAction(_stop, "Stop Relay"); }
        }''')

patch(M,
'''        private void RestorePreviousGuided()
        {
            if (MessageBox.Show("Restore the previous verified sing-box runtime?\\r\\n\\r\\nThis is a troubleshooting action.", "Restore previous runtime?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            try { _engine.RestorePreviousRuntime(); }
            catch (Exception ex) { ShowFriendlyError("Could not restore previous version", ex); }
            finally { UpdateStatus(); }
        }''',
'''        private async void RestorePreviousGuided()
        {
            if (_busy) return;
            if (MessageBox.Show("Restore the previous verified sing-box runtime?\\r\\n\\r\\nThis is a troubleshooting action.", "Restore previous runtime?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            BeginSetupAction(_rollback, "Restoring...", "Restoring and verifying the previous runtime...");
            try { await Task.Run(delegate { _engine.RestorePreviousRuntime(); }); }
            catch (Exception ex) { ShowFriendlyError("Could not restore previous version", ex); }
            finally { EndSetupAction(_rollback, "Restore Previous"); }
        }''')

patch(M,
'''List<CheckResult> checks = _engine.GetPreflightChecks(SelectedIp());''',
'''List<CheckResult> checks = _engine.GetPreflightChecks(SelectedIp(), _profileServer != null && _profileServer.Running);''')

patch(M,
'''SetStatus(_profileState, "Ready", _success); SetStatus(_firewallState, "Ready", _success);''',
'''SetStatus(_profileState, _engine.PhoneProfileConfirmed() ? "Saved (phone not probed)" : "Not confirmed", _engine.PhoneProfileConfirmed() ? _success : _warning); SetStatus(_firewallState, "Ready", _success);''')

patch(M,
'''                _engine.Log("Opened locally generated SFA-ready QR. No QR payload was sent to an external service.");''',
'''                _engine.Log("Opened locally generated QR. Remote profile auto-update must be disabled in SFA after import; alternatively import the downloaded JSON as a local profile.");''')

# The QR remains a five-minute remote-import shortcut. Make the setup page
# recommend SFA's permanent local-file import rather than implying a durable URL.
patch(P,
'''Open in SFA</a></p><p><a href=\\\"android-bpsr-relay.json\\\" download>Download SFA profile</a></p><p class=\\\"small\\\">This local page stays available for up to five minutes so SFA can fetch the profile after you open or download it.''',
'''Quick remote import (disable Auto Update in SFA after importing)</a></p><p><a href=\\\"android-bpsr-relay.json\\\" download>Recommended: Download JSON, then use SFA Import from file</a></p><p class=\\\"small\\\">This temporary link expires after five minutes and closes when the relay starts. For a permanent one-time setup use a local file; QR imports are remote profiles and must have Auto Update disabled in SFA.''')

print("All fail-closed source patches applied.")
