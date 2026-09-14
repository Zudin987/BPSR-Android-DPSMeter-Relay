$ErrorActionPreference = 'Stop'

$path = 'src\BpsrRelayManager\MainForm.cs'
$text = [IO.File]::ReadAllText($path)

function Replace-Once([string]$old, [string]$new) {
    if (-not $script:text.Contains($old)) {
        throw ('Expected UI source text not found: ' + $old.Substring(0, [Math]::Min(120, $old.Length)))
    }
    $script:text = $script:text.Replace($old, $new)
}

Replace-Once '        private readonly Color _muted = Color.FromArgb(100, 116, 139);' '        private readonly Color _muted = Color.FromArgb(71, 85, 105);'
Replace-Once '        private readonly Color _border = Color.FromArgb(218, 225, 235);' '        private readonly Color _border = Color.FromArgb(203, 213, 225);'
Replace-Once '        private readonly Color _primary = Color.FromArgb(37, 99, 235);' "        private readonly Color _primary = Color.FromArgb(37, 99, 235);`r`n        private readonly Color _primarySoft = Color.FromArgb(239, 246, 255);`r`n        private readonly Color _successSoft = Color.FromArgb(240, 253, 244);`r`n        private readonly Color _warningSoft = Color.FromArgb(255, 247, 237);`r`n        private readonly Color _dangerSoft = Color.FromArgb(254, 242, 242);"
Replace-Once '        private readonly Color _neutral = Color.FromArgb(71, 85, 105);' '        private readonly Color _neutral = Color.FromArgb(51, 65, 85);'

Replace-Once '        private Label _nextAction;' "        private Label _nextAction;`r`n        private Label _overallState;`r`n        private Label _adapterInfo;`r`n        private ToolTip _toolTip;"
Replace-Once '        private bool _hiddenToTray;' ''
Replace-Once '                _timer.Interval = 5000;' '                _timer.Interval = 3000;'
Replace-Once '            Text = "BPSR Android Relay";' '            Text = "BPSR Relay Manager";'
Replace-Once '            Label title = MakeLabel("BPSR Android Relay", 24, 16, 650, 31, 17f, true, _text);' '            Label title = MakeLabel("BPSR Relay Manager", 24, 16, 650, 31, 17f, true, _text);'
Replace-Once '            Controls.Add(MakeLabel("Native Windows manager - use your phone with a compatible DPS meter", 27, 49, 650, 22, 9.25f, false, _muted));' '            Controls.Add(MakeLabel("Native Windows relay for Android BPSR + compatible PC DPS meters", 27, 49, 650, 22, 9.25f, false, _muted));'
Replace-Once '            Controls.Add(version);' "            Controls.Add(version);`r`n            _overallState = MakeLabel(\"CHECKING\", 744, 49, 181, 25, 9.25f, true, _neutral);`r`n            _overallState.TextAlign = ContentAlignment.MiddleCenter;`r`n            _overallState.BackColor = _surfaceSoft;`r`n            _overallState.BorderStyle = BorderStyle.FixedSingle;`r`n            Controls.Add(_overallState);`r`n`r`n            _toolTip = new ToolTip();`r`n            _toolTip.AutoPopDelay = 9000;`r`n            _toolTip.InitialDelay = 350;`r`n            _toolTip.ReshowDelay = 100;`r`n            _toolTip.ShowAlways = true;"

Replace-Once '            _ip = new ComboBox(); _ip.Location = new Point(16, 35); _ip.Size = new Size(218, 26); _ip.DropDownStyle = ComboBoxStyle.DropDownList; _ip.SelectedIndexChanged += delegate { if (!_selfTest) UpdateStatus(); }; address.Controls.Add(_ip);' "            _ip = new ComboBox(); _ip.Location = new Point(16, 35); _ip.Size = new Size(218, 26); _ip.DropDownStyle = ComboBoxStyle.DropDownList; _ip.SelectedIndexChanged += delegate { if (!_selfTest) UpdateStatus(); }; address.Controls.Add(_ip);`r`n            _toolTip.SetToolTip(_ip, \"LAN IPv4 address Android will connect to. Usually leave the first auto-selected address.\");"
Replace-Once '            address.Controls.Add(MakeLabel("Usually leave this as-is.\r\nSame home network/router as your phone.", 250, 30, 280, 34, 9f, false, _muted)); setup.Controls.Add(address);' '            _adapterInfo = MakeLabel("Auto-selected LAN adapter.\r\nPhone must use the same router.", 250, 30, 280, 34, 9f, false, _muted); address.Controls.Add(_adapterInfo); setup.Controls.Add(address);'

Replace-Once '            _prepare = UiButton("Prepare Relay", 382, 32, 148, 30, true, false); _prepare.Click += delegate { PrepareRelayGuided(); }; step1.Controls.Add(_prepare); setup.Controls.Add(step1);' "            _prepare = UiButton(\"Prepare Relay\", 382, 32, 148, 30, false, false); _prepare.Click += delegate { PrepareRelayGuided(); }; step1.Controls.Add(_prepare); _toolTip.SetToolTip(_prepare, \"Download/verify the relay runtime and generate the current phone profile.\"); setup.Controls.Add(step1);"
Replace-Once '            _firewall = UiButton("Allow Firewall", 382, 32, 148, 30, false, false); _firewall.Click += delegate { AllowFirewallGuided(); }; step2.Controls.Add(_firewall); setup.Controls.Add(step2);' "            _firewall = UiButton(\"Allow Firewall\", 382, 32, 148, 30, false, false); _firewall.Click += delegate { AllowFirewallGuided(); }; step2.Controls.Add(_firewall); _toolTip.SetToolTip(_firewall, \"Windows will ask for Administrator approval. This only opens the relay to your trusted Private LAN.\"); setup.Controls.Add(step2);"
Replace-Once '            _phoneSetup = UiButton("Start Phone Setup", 16, 62, 180, 30, true, false); _phoneSetup.Click += delegate { StartPhoneSetupGuided(); }; step3.Controls.Add(_phoneSetup);' "            _phoneSetup = UiButton(\"Start Phone Setup\", 16, 62, 180, 30, false, false); _phoneSetup.Click += delegate { StartPhoneSetupGuided(); }; step3.Controls.Add(_phoneSetup); _toolTip.SetToolTip(_phoneSetup, \"Temporarily serve the current SFA profile to your phone and open the local QR flow.\");"
Replace-Once '            _qr = UiButton("Show SFA QR", 204, 62, 150, 30, false, false); _qr.Click += delegate { ShowQrGuided(); }; step3.Controls.Add(_qr);' "            _qr = UiButton(\"Show SFA QR\", 204, 62, 150, 30, false, false); _qr.Click += delegate { ShowQrGuided(); }; step3.Controls.Add(_qr); _toolTip.SetToolTip(_qr, \"Open the locally generated QR page for the active phone setup session.\");"
Replace-Once '            _copyLink = UiButton("Copy SFA Link", 362, 62, 168, 30, false, false); _copyLink.Click += delegate { CopySfaLink(); }; step3.Controls.Add(_copyLink); setup.Controls.Add(step3);' "            _copyLink = UiButton(\"Copy SFA Link\", 362, 62, 168, 30, false, false); _copyLink.Click += delegate { CopySfaLink(); }; step3.Controls.Add(_copyLink); _toolTip.SetToolTip(_copyLink, \"Copy the current local SFA import link instead of scanning the QR.\"); setup.Controls.Add(step3);"

Replace-Once '            _check = UiButton("Run Check", 16, 57, 105, 27, false, false); _check.Click += delegate { RunCheck(); }; step5.Controls.Add(_check);' "            _check = UiButton(\"Run Check\", 16, 55, 105, 30, false, false); _check.Click += delegate { RunCheck(); }; step5.Controls.Add(_check); _toolTip.SetToolTip(_check, \"Run a quick readiness check without starting the relay.\");"
Replace-Once '            _start = UiButton("Start Relay", 129, 57, 134, 27, true, false); _start.Click += delegate { StartRelayGuided(); }; step5.Controls.Add(_start);' "            _start = UiButton(\"Start Relay\", 129, 55, 134, 30, false, false); _start.Click += delegate { StartRelayGuided(); }; step5.Controls.Add(_start); _toolTip.SetToolTip(_start, \"Start the phone-facing relay and StarSEA process target.\");"
Replace-Once '            _stop = UiButton("Stop Relay", 271, 57, 108, 27, false, true); _stop.Click += delegate { StopRelayGuided(); }; step5.Controls.Add(_stop);' "            _stop = UiButton(\"Stop Relay\", 271, 55, 108, 30, false, true); _stop.Click += delegate { StopRelayGuided(); }; step5.Controls.Add(_stop); _toolTip.SetToolTip(_stop, \"Stop the active relay. This can interrupt BPSR if the phone is currently using it.\");"
Replace-Once '            _trayButton = UiButton("Minimize to Tray", 387, 57, 143, 27, false, false); _trayButton.Click += delegate { MinimizeToTray(); }; step5.Controls.Add(_trayButton); setup.Controls.Add(step5);' "            _trayButton = UiButton(\"Minimize to Tray\", 387, 55, 143, 30, false, false); _trayButton.Click += delegate { MinimizeToTray(); }; step5.Controls.Add(_trayButton); _toolTip.SetToolTip(_trayButton, \"Hide this window while keeping the manager available from the system tray.\"); setup.Controls.Add(step5);"
Replace-Once '            Panel next = Card(0, 202, 316, 108); AddCardTitle(next, "What to do next", 10); _nextAction = MakeLabel("Checking your setup...", 16, 43, 284, 52, 9.25f, false, _neutral); next.Controls.Add(_nextAction); statusPanel.Controls.Add(next);' '            Panel next = Card(0, 202, 316, 108); AddCardTitle(next, "What to do next", 10); _nextAction = MakeLabel("Checking your setup...", 16, 41, 284, 56, 9.5f, true, _neutral); next.Controls.Add(_nextAction); statusPanel.Controls.Add(next);'

Replace-Once '            _notifyIcon = new NotifyIcon(); _notifyIcon.Text = "BPSR Android Relay"; _notifyIcon.Icon = SystemIcons.Application; _notifyIcon.Visible = !_selfTest;' '            _notifyIcon = new NotifyIcon(); _notifyIcon.Text = "BPSR Relay Manager - Relay stopped"; _notifyIcon.Icon = SystemIcons.Application; _notifyIcon.Visible = !_selfTest;'

Replace-Once '            if (_selfTest) return;' "            if (_selfTest) return;`r`n            string selectedIp = (_ip.Text ?? string.Empty).Trim();`r`n            UpdateAdapterSummary(selectedIp);"
Replace-Once '                SetStatus(_relayState, "Running", _primary); SetStatus(_runtimeState, "Ready", _success); SetStatus(_profileState, "Ready", _success); SetStatus(_firewallState, "Ready at start", _success); _nextAction.Text = "Relay is running. Open BPSR on your phone and play."; SetButtonStates(true, true, true, true, false); UpdateTray(true); return;' '                SetStatus(_relayState, "Running", _success); SetStatus(_runtimeState, "Ready", _success); SetStatus(_profileState, "Ready", _success); SetStatus(_firewallState, "Ready", _success); _nextAction.Text = "Relay is running. Start SFA on your phone if needed, then open BPSR and play."; SetButtonStates(true, true, true, true, false); SetOverallState("RELAY RUNNING", _success, _successSoft); SetRecommendedAction(null); UpdateTray(true); return;'
Replace-Once '            string ip = (_ip.Text ?? string.Empty).Trim();' '            string ip = selectedIp;'
Replace-Once '            SetStatus(_relayState, hasForeign ? (foreign.Count == 1 ? foreign[0].Name + ".exe" : foreign.Count + " old relays") : "Stopped", hasForeign ? _danger : _neutral);' '            SetStatus(_relayState, hasForeign ? (foreign.Count == 1 ? "Old relay found" : foreign.Count + " old relays") : "Stopped", hasForeign ? _danger : _neutral);'
Replace-Once '            SetButtonStates(false, runtime, profile, firewall, hasForeign); UpdateTray(false);' "            Button recommended;`r`n            if (hasForeign) { SetOverallState(\"ACTION REQUIRED\", _danger, _dangerSoft); recommended = _prepare; }`r`n            else if (!runtime || !profile) { SetOverallState(\"SETUP NEEDED\", _warning, _warningSoft); recommended = _prepare; }`r`n            else if (!firewall) { SetOverallState(\"SETUP NEEDED\", _warning, _warningSoft); recommended = _firewall; }`r`n            else if (!confirmed) { SetOverallState(\"FINISH PHONE SETUP\", _warning, _warningSoft); recommended = _profileServer != null && _profileServer.Running ? _qr : _phoneSetup; }`r`n            else { SetOverallState(\"READY TO START\", _primary, _primarySoft); recommended = _start; }`r`n            SetButtonStates(false, runtime, profile, firewall, hasForeign); SetRecommendedAction(recommended); UpdateTray(false);"

Replace-Once '            if (_trayStatus == null) return; _trayStatus.Text = running ? "Relay: Running" : "Relay: Stopped"; _trayStart.Enabled = !running; _trayStop.Enabled = running;' '            if (_trayStatus == null) return; _trayStatus.Text = running ? "Relay: Running" : "Relay: Stopped"; _trayStart.Enabled = !running; _trayStop.Enabled = running; if (_notifyIcon != null) _notifyIcon.Text = running ? "BPSR Relay Manager - Relay running" : "BPSR Relay Manager - Relay stopped";'

Replace-Once '        private void SetStatus(Label label, string text, Color color) { label.Text = text; label.ForeColor = color; }' @'
        private void SetStatus(Label label, string text, Color color)
        {
            label.Text = "\u25CF " + text;
            label.ForeColor = color;
            if (_toolTip != null) _toolTip.SetToolTip(label, text);
        }

        private void SetOverallState(string text, Color foreground, Color background)
        {
            if (_overallState == null) return;
            _overallState.Text = text;
            _overallState.ForeColor = foreground;
            _overallState.BackColor = background;
            _overallState.BorderStyle = BorderStyle.FixedSingle;
        }

        private void UpdateAdapterSummary(string ip)
        {
            if (_adapterInfo == null) return;
            if (string.IsNullOrWhiteSpace(ip) || !_engine.IsLocalIp(ip))
            {
                _adapterInfo.Text = "No active LAN adapter found.\r\nConnect Wi-Fi/Ethernet, then retry.";
                _adapterInfo.ForeColor = _danger;
                return;
            }
            string name = _engine.GetAdapterName(ip);
            if (string.IsNullOrWhiteSpace(name) || string.Equals(name, "unknown", StringComparison.OrdinalIgnoreCase)) name = "Selected LAN adapter";
            _adapterInfo.Text = name + "\r\nPhone must use the same router.";
            _adapterInfo.ForeColor = _neutral;
            if (_toolTip != null) _toolTip.SetToolTip(_ip, ip + " - " + name + ". Phone must be on the same trusted router.");
        }

        private void SetRecommendedAction(Button recommended)
        {
            Button[] flow = new Button[] { _prepare, _firewall, _phoneSetup, _qr, _start };
            foreach (Button button in flow) if (button != null) StyleButton(button, button == recommended, false);
        }

        private void StyleButton(Button button, bool primary, bool danger)
        {
            if (button == null) return;
            button.BackColor = primary ? _primary : _surface;
            button.ForeColor = primary ? Color.White : (danger ? _danger : _text);
            button.FlatAppearance.BorderColor = primary ? _primary : (danger ? Color.FromArgb(244, 190, 190) : _border);
            button.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(29, 78, 216) : (danger ? _dangerSoft : _surfaceSoft);
            button.FlatAppearance.MouseDownBackColor = primary ? Color.FromArgb(30, 64, 175) : (danger ? Color.FromArgb(254, 226, 226) : Color.FromArgb(241, 245, 249));
        }
'@

Replace-Once '            ShowInTaskbar = false; Hide(); _hiddenToTray = true;' '            ShowInTaskbar = false; Hide();'
Replace-Once '            if (IsDisposed) return; ShowInTaskbar = true; Show(); WindowState = FormWindowState.Normal; BringToFront(); Activate(); _hiddenToTray = false;' '            if (IsDisposed) return; ShowInTaskbar = true; Show(); WindowState = FormWindowState.Normal; BringToFront(); Activate();'
Replace-Once '            if (_notifyIcon == null || _notifyIcon.ContextMenuStrip == null) throw new InvalidOperationException("Native tray integration is missing.");' "            if (_notifyIcon == null || _notifyIcon.ContextMenuStrip == null) throw new InvalidOperationException(\"Native tray integration is missing.\");`r`n            if (_overallState == null || _adapterInfo == null || _toolTip == null) throw new InvalidOperationException(\"Native visibility/UX guidance controls are missing.\");"
Replace-Once '                if (_notifyIcon != null) { _notifyIcon.Visible = false; _notifyIcon.Dispose(); _notifyIcon = null; }' "                if (_notifyIcon != null) { _notifyIcon.Visible = false; _notifyIcon.Dispose(); _notifyIcon = null; }`r`n                if (_toolTip != null) { _toolTip.Dispose(); _toolTip = null; }"
Replace-Once '            parent.Controls.Add(MakeLabel(title, 16, y, 135, 23, 9.25f, false, _muted)); Label value = MakeLabel("Checking...", 148, y, parent.Width - 164, 23, 9.5f, true, _neutral); value.TextAlign = ContentAlignment.MiddleRight; parent.Controls.Add(value); return value;' '            parent.Controls.Add(MakeLabel(title, 16, y, 108, 23, 9.25f, false, _muted)); Label value = MakeLabel("Checking...", 124, y, parent.Width - 140, 23, 9.25f, true, _neutral); value.TextAlign = ContentAlignment.MiddleRight; parent.Controls.Add(value); return value;'
Replace-Once '            Label label = new Label(); label.Text = text; label.Location = new Point(x, y); label.Size = new Size(width, height); label.ForeColor = color; label.Font = new Font(semibold ? "Segoe UI Semibold" : "Segoe UI", size); label.AutoEllipsis = true; label.UseMnemonic = false; return label;' '            Label label = new Label(); label.Text = text; label.Location = new Point(x, y); label.Size = new Size(width, height); label.ForeColor = color; label.Font = new Font(semibold ? "Segoe UI Semibold" : "Segoe UI", size); label.AutoEllipsis = true; label.UseMnemonic = false; label.AccessibleName = text; return label;'
Replace-Once '            Button button = new Button(); button.Text = text; button.Location = new Point(x, y); button.Size = new Size(width, height); button.FlatStyle = FlatStyle.Flat; button.UseVisualStyleBackColor = false; button.BackColor = primary ? _primary : _surface; button.ForeColor = primary ? Color.White : (danger ? _danger : _text); button.FlatAppearance.BorderSize = 1; button.FlatAppearance.BorderColor = primary ? _primary : (danger ? Color.FromArgb(244, 190, 190) : _border); button.Font = new Font("Segoe UI Semibold", 9.25f); button.Cursor = Cursors.Hand; return button;' '            Button button = new Button(); button.Text = text; button.Location = new Point(x, y); button.Size = new Size(width, height); button.FlatStyle = FlatStyle.Flat; button.UseVisualStyleBackColor = false; button.FlatAppearance.BorderSize = 1; button.Font = new Font("Segoe UI Semibold", 9.25f); button.Cursor = Cursors.Hand; button.AccessibleName = text; StyleButton(button, primary, danger); return button;'

[IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))

$versionPath = 'src\BpsrRelayManager\VersionInfo.cs'
$version = [IO.File]::ReadAllText($versionPath)
if (-not $version.Contains('public const string Version = "1.1.0";')) { throw 'Expected v1.1.0 version source not found.' }
$version = $version.Replace('public const string Version = "1.1.0";', 'public const string Version = "1.1.1";')
[IO.File]::WriteAllText($versionPath, $version, (New-Object Text.UTF8Encoding($false)))

$releasePath = '.github\workflows\release.yml'
$release = [IO.File]::ReadAllText($releasePath)
$release = $release.Replace('1.1.0', '1.1.1')
[IO.File]::WriteAllText($releasePath, $release, (New-Object Text.UTF8Encoding($false)))

git config user.name 'MrEz'
git config user.email '39240221+Zudin987@users.noreply.github.com'
git rm '.github/workflows/apply-v111-ui-ux.yml'
git rm 'scripts/ApplyV111UiPatch.ps1'
git add $path $versionPath $releasePath
git commit -m 'Improve native UI visibility and guided workflow'
git push origin HEAD:ui/v111-visibility-ux
