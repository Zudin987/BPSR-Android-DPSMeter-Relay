$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $root 'src\BpsrRelayManager'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Replace-ExactlyOnce {
    param([string]$Text, [string]$Before, [string]$After, [string]$Label)
    $first = $Text.IndexOf($Before, [StringComparison]::Ordinal)
    if ($first -lt 0 -or $Text.IndexOf($Before, $first + $Before.Length, [StringComparison]::Ordinal) -ge 0) {
        throw ('Expected exactly one occurrence of ' + $Label)
    }
    return $Text.Substring(0, $first) + $After + $Text.Substring($first + $Before.Length)
}

function Replace-Section {
    param([string]$Text, [string]$Start, [string]$Next, [string]$Replacement)
    $from = $Text.IndexOf($Start, [StringComparison]::Ordinal)
    if ($from -lt 0 -or $Text.IndexOf($Start, $from + $Start.Length, [StringComparison]::Ordinal) -ge 0) { throw ('Section start missing/ambiguous: ' + $Start) }
    $to = $Text.IndexOf($Next, $from + $Start.Length, [StringComparison]::Ordinal)
    if ($to -lt 0) { throw ('Section end missing: ' + $Next) }
    return $Text.Substring(0, $from) + $Replacement + $Text.Substring($to)
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
                StopProfileServer();
                BeginSetupAction(_start, "Starting...", "Starting StarSEA and the phone relay. Please wait.");
                began = true;
                await Task.Run(delegate { _engine.StartRelay(ip); });
            }
            catch (Exception ex) { ShowFriendlyError("Could not start relay", ex); }
            finally
            {
                if (began) EndSetupAction(_start, "Start Relay");
                else UpdateStatus();
            }
        }

'@
$ui = Replace-Section $ui '        private void StopRelayGuided()' '        private void RestorePreviousGuided()' @'
        private async void StopRelayGuided()
        {
            if (_busy || !_engine.IsRelayRunning()) return;
            if (MessageBox.Show("Stop the relay now?\r\n\r\nIf BPSR is using this relay, stopping it can interrupt the phone's game connection.", "Stop relay?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            BeginSetupAction(_stop, "Stopping...", "Stopping the relay and cleaning up both owned processes.");
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
$ui = Replace-ExactlyOnce $ui 'if (_busy && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; return; }' 'if (_busy) { e.Cancel = true; _forceExit = false; return; }' 'busy close guard'
$ui = Replace-ExactlyOnce $ui 'ToolStripMenuItem stopExit = new ToolStripMenuItem("Stop Relay && Exit"); stopExit.Click += delegate { try { _engine.StopRelay(); } catch { } _forceExit = true; Close(); }; menu.Items.Add(stopExit);' @'
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
'@ 'tray stop and exit'
[System.IO.File]::WriteAllText($uiPath, $ui, $utf8)

$enginePath = Join-Path $sourceDir 'RelayEngine.cs'
$engine = [System.IO.File]::ReadAllText($enginePath).Replace("`r`n", "`n")
$engine = Replace-ExactlyOnce $engine 'private string _listenerDetail = "not running";' @'
private string _listenerDetail = "not running";
        private DateTime _runtimeHashCheckedUtc = DateTime.MinValue;
        private DateTime _runtimeLastWriteUtc = DateTime.MinValue;
        private long _runtimeSize = -1;
        private bool _runtimeHealthy;
'@ 'runtime integrity cache fields'
$engine = Replace-Section $engine '        public bool RuntimeReady()' '        public string InstalledRuntimeVersion()' @'
        public bool RuntimeReady()
        {
            try
            {
                if (!File.Exists(_singBoxExe) || !File.Exists(_runtimeHashFile)) return false;
                FileInfo info = new FileInfo(_singBoxExe);
                DateTime now = DateTime.UtcNow;
                // Cache successful integrity checks briefly, but invalidate on file change.
                // Starting the actual relay separately verifies all three executable copies.
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
$engine = Replace-ExactlyOnce $engine '            AddCheck(checks, "Android profile", GetProfilePcIp() == ip, "Current profile matches " + ip, "Run Prepare Relay to refresh the profile.");' @'
            AddCheck(checks, "Android profile", GetProfilePcIp() == ip, "Current profile matches " + ip, "Run Prepare Relay to refresh the profile.");
            AddCheck(checks, "Phone import", PhoneProfileConfirmed(), "Current SFA profile manually confirmed.", "Import the current profile in SFA and confirm it in Start Relay; downloading alone does not complete phone setup.");
'@ 'phone readiness preflight'
$engine = Replace-ExactlyOnce $engine '            AssertFrontPortFree(ip);' @'
            AssertFrontPortFree(ip);
            // Verify the copies which will actually execute; RuntimeReady verifies only the
            // master binary, and those copies may have changed since Prepare Relay.
            if (!File.Exists(_frontExe) || !File.Exists(_starExe) ||
                !string.Equals(Sha256File(_singBoxExe), Sha256File(_frontExe), StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Sha256File(_singBoxExe), Sha256File(_starExe), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Relay executables failed integrity verification. Run Prepare Relay to repair them.");
'@ 'actual runtime copy validation'
# Stop a surviving project-owned process after one of the pair exits. Do not loop on restart.
$engine = Replace-ExactlyOnce $engine @'
                _lastListenerHealthy = false;
                _listenerDetail = "tracked relay process exited or changed";
                return false;
'@ @'
                StopRelay();
                _lastListenerHealthy = false;
                _listenerDetail = "relay process exited; surviving owned process cleaned up";
                Log("Relay process unexpectedly exited. Stopped the remaining verified relay process. Use Start Relay to reconnect.");
                return false;
'@ 'partial process exit cleanup'
[System.IO.File]::WriteAllText($enginePath, $engine, $utf8)

# The workflow exists only to apply these exact guarded edits to the native files.
# It must NOT be part of the reviewed PR or the eventual released repository.
$temporaryWorkflow = Join-Path $root '.github\workflows\apply-audit-once.yml'
if (-not (Test-Path -LiteralPath $temporaryWorkflow)) { throw 'Temporary patch workflow is missing.' }
Remove-Item -LiteralPath $temporaryWorkflow -Force
Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force
Write-Host 'AUDIT REFACTOR APPLIED: guarded C# replacements complete; temporary automation removed.'
