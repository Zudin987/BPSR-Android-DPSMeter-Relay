$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $root 'src\BpsrRelayManager'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Replace-Once([string]$text, [string]$before, [string]$after, [string]$label) {
    $i = $text.IndexOf($before, [StringComparison]::Ordinal)
    if ($i -lt 0 -or $text.IndexOf($before, $i + $before.Length, [StringComparison]::Ordinal) -ge 0) { throw ('Missing or ambiguous ' + $label) }
    return $text.Substring(0, $i) + $after + $text.Substring($i + $before.Length)
}
function Replace-Section([string]$text, [string]$start, [string]$next, [string]$replacement) {
    $i = $text.IndexOf($start, [StringComparison]::Ordinal)
    if ($i -lt 0 -or $text.IndexOf($start, $i + $start.Length, [StringComparison]::Ordinal) -ge 0) { throw ('Missing or ambiguous ' + $start) }
    $j = $text.IndexOf($next, $i + $start.Length, [StringComparison]::Ordinal)
    if ($j -lt 0) { throw ('Missing section boundary ' + $next) }
    return $text.Substring(0, $i) + $replacement.TrimEnd() + "`n`n" + $text.Substring($j)
}

$uiPath = Join-Path $sourceDir 'MainForm.cs'
$ui = [System.IO.File]::ReadAllText($uiPath).Replace("`r`n", "`n")
$ui = Replace-Section $ui '        private void StartRelayGuided()' '        private Form CreatePhoneSetupPrompt' @'
        private async void StartRelayGuided()
        {
            if (_busy) return;
            bool began = false;
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
                if (_profileServer != null && _profileServer.Running &&
                    MessageBox.Show("Phone Setup is still available. Finished importing the current profile in SFA? Starting now will close the setup link.", "Finish phone setup", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
                StopProfileServer();
                BeginSetupAction(_start, "Starting...", "Starting StarSEA and the phone relay. Please wait.");
                began = true;
                await Task.Run(delegate { _engine.StartRelay(ip); });
            }
            catch (Exception ex) { ShowFriendlyError("Could not start relay", ex); }
            finally { if (began) EndSetupAction(_start, "Start Relay"); else UpdateStatus(); }
        }
'@
$ui = Replace-Section $ui '        private void StopRelayGuided()' '        private void RestorePreviousGuided()' @'
        private async void StopRelayGuided()
        {
            if (_busy || !_engine.IsRelayRunning()) return;
            if (MessageBox.Show("Stop the relay now?\r\n\r\nIf BPSR is using this relay, stopping it can interrupt the phone's game connection.", "Stop relay?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            BeginSetupAction(_stop, "Stopping...", "Stopping and cleaning up the relay processes.");
            try { await Task.Run(delegate { _engine.StopRelay(); }); }
            catch (Exception ex) { ShowFriendlyError("Could not stop relay", ex); }
            finally { EndSetupAction(_stop, "Stop Relay"); }
        }
'@
$ui = Replace-Section $ui '        private void RestorePreviousGuided()' '        private void RunCheck()' @'
        private async void RestorePreviousGuided()
        {
            if (_busy) return;
            if (MessageBox.Show("Restore the previous verified sing-box runtime?\r\n\r\nThis is a troubleshooting action.", "Restore previous runtime?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            BeginSetupAction(_rollback, "Restoring...", "Restoring the previous verified runtime.");
            try { await Task.Run(delegate { _engine.RestorePreviousRuntime(); }); }
            catch (Exception ex) { ShowFriendlyError("Could not restore previous version", ex); }
            finally { EndSetupAction(_rollback, "Restore Previous"); }
        }
'@
$ui = Replace-Once $ui 'if (_busy && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; return; }' 'if (_busy) { e.Cancel = true; _forceExit = false; return; }' 'close-while-busy guard'
$ui = Replace-Once $ui 'ToolStripMenuItem stopExit = new ToolStripMenuItem("Stop Relay && Exit"); stopExit.Click += delegate { try { _engine.StopRelay(); } catch { } _forceExit = true; Close(); }; menu.Items.Add(stopExit);' @'
ToolStripMenuItem stopExit = new ToolStripMenuItem("Stop Relay && Exit");
            stopExit.Click += async delegate
            {
                if (_busy) return;
                BeginSetupAction(_stop, "Stopping...", "Stopping relay before exit.");
                bool stopped = false;
                try { await Task.Run(delegate { _engine.StopRelay(); }); stopped = true; }
                catch (Exception ex) { ShowFriendlyError("Could not stop relay", ex); }
                finally { EndSetupAction(_stop, "Stop Relay"); }
                if (stopped) { _forceExit = true; Close(); }
            };
            menu.Items.Add(stopExit);
'@ 'tray stop-exit handler'
[System.IO.File]::WriteAllText($uiPath, $ui, $utf8)

$enginePath = Join-Path $sourceDir 'RelayEngine.cs'
$engine = [System.IO.File]::ReadAllText($enginePath).Replace("`r`n", "`n")
$engine = Replace-Once $engine 'private string _listenerDetail = "not running";' @'
private string _listenerDetail = "not running";
        private DateTime _runtimeHashCheckedUtc = DateTime.MinValue;
        private DateTime _runtimeLastWriteUtc = DateTime.MinValue;
        private long _runtimeSize = -1;
        private bool _runtimeHealthy;
'@ 'runtime cache fields'
$engine = Replace-Section $engine '        public bool RuntimeReady()' '        public string InstalledRuntimeVersion()' @'
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
'@
$engine = Replace-Once $engine '            AddCheck(checks, "Android profile", GetProfilePcIp() == ip, "Current profile matches " + ip, "Run Prepare Relay to refresh the profile.");' @'
            AddCheck(checks, "Android profile", GetProfilePcIp() == ip, "Current profile matches " + ip, "Run Prepare Relay to refresh the profile.");
            AddCheck(checks, "Phone import", PhoneProfileConfirmed(), "Current SFA profile manually confirmed.", "Import the current profile in SFA and confirm it in Start Relay; a download alone is insufficient.");
'@ 'phone readiness preflight'
$engine = Replace-Once $engine @'
            AssertFrontPortFree(ip);
            RelayCredentials creds = GetOrCreateCredentials();
'@ @'
            AssertFrontPortFree(ip);
            // Verify the executable copies that will actually be launched, not only the master.
            if (!File.Exists(_frontExe) || !File.Exists(_starExe) ||
                !string.Equals(Sha256File(_singBoxExe), Sha256File(_frontExe), StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Sha256File(_singBoxExe), Sha256File(_starExe), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Relay executable integrity check failed. Run Prepare Relay to repair the copies.");
            RelayCredentials creds = GetOrCreateCredentials();
'@ 'launch integrity guard'
$engine = Replace-Once $engine @'
                _lastListenerHealthy = false;
                _listenerDetail = "tracked relay process exited or changed";
                return false;
'@ @'
                // A dead half must not leave the surviving process orphaned or reported healthy.
                StopRelay();
                _lastListenerHealthy = false;
                _listenerDetail = "relay process exited; remaining owned process cleaned up";
                Log("Relay process unexpectedly exited; remaining verified process stopped. Start Relay to reconnect.");
                return false;
'@ 'partial-process cleanup'
[System.IO.File]::WriteAllText($enginePath, $engine, $utf8)

$workflow = Join-Path $root '.github\workflows\apply-audit-once.yml'
if (-not (Test-Path -LiteralPath $workflow)) { throw 'Expected temporary workflow is missing.' }
Remove-Item -LiteralPath $workflow -Force
Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force
Write-Host 'AUDIT PATCH APPLIED: both native sources updated; temporary automation removed.'
