using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace BpsrRelayManager
{
    internal sealed class MainForm : Form
    {
        private readonly RelayEngine _engine;
        private readonly bool _selfTest;
        private readonly Color _background = Color.FromArgb(244, 247, 251);
        private readonly Color _surface = Color.White;
        private readonly Color _surfaceSoft = Color.FromArgb(248, 250, 252);
        private readonly Color _text = Color.FromArgb(15, 23, 42);
        private readonly Color _muted = Color.FromArgb(100, 116, 139);
        private readonly Color _border = Color.FromArgb(218, 225, 235);
        private readonly Color _primary = Color.FromArgb(37, 99, 235);
        private readonly Color _success = Color.FromArgb(21, 128, 61);
        private readonly Color _warning = Color.FromArgb(180, 83, 9);
        private readonly Color _danger = Color.FromArgb(185, 28, 28);
        private readonly Color _neutral = Color.FromArgb(71, 85, 105);

        private ComboBox _ip;
        private Button _prepare;
        private Button _firewall;
        private Button _phoneSetup;
        private Button _qr;
        private Button _copyLink;
        private Button _check;
        private Button _start;
        private Button _stop;
        private Button _trayButton;
        private Button _detailsStop;
        private Button _rollback;
        private Label _relayState;
        private Label _runtimeState;
        private Label _profileState;
        private Label _firewallState;
        private Label _nextAction;
        private TextBox _log;
        private TabControl _tabs;
        private TabPage _homeTab;
        private TabPage _detailsTab;
        private TabPage _helpTab;
        private Timer _timer;
        private NotifyIcon _notifyIcon;
        private ToolStripMenuItem _trayStatus;
        private ToolStripMenuItem _trayStart;
        private ToolStripMenuItem _trayStop;
        private ProfileServer _profileServer;
        private bool _forceExit;
        private bool _hiddenToTray;
        private bool _trayNoticeShown;

        public MainForm(RelayEngine engine, bool selfTest)
        {
            _engine = engine;
            _selfTest = selfTest;
            InitializeForm();
            BuildUi();
            BuildTray();
            _engine.SetLogger(AppendLog);
            LoadAddresses();
            if (!_selfTest)
            {
                _timer = new Timer();
                _timer.Interval = 5000;
                _timer.Tick += delegate { UpdateStatus(); };
                _timer.Start();
                UpdateStatus();
                _engine.Log("Ready - native manager " + _engine.ManagerVersion + ".");
                _engine.Log("DPS meter target: StarSEA.");
                _engine.Log("Tested relay core: sing-box " + _engine.TestedSingBoxVersion + ".");
            }
        }

        private void InitializeForm()
        {
            Text = "BPSR Android Relay";
            ClientSize = new Size(964, 690);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            MinimizeBox = true;
            BackColor = _background;
            Font = new Font("Segoe UI", 9.25f);
            AutoScaleMode = AutoScaleMode.Dpi;
            FormClosing += OnFormClosing;
        }

        private void BuildUi()
        {
            Label title = MakeLabel("BPSR Android Relay", 24, 16, 650, 31, 17f, true, _text);
            Controls.Add(title);
            Controls.Add(MakeLabel("Native Windows manager - use your phone with a compatible DPS meter", 27, 49, 650, 22, 9.25f, false, _muted));
            Label version = MakeLabel("v" + _engine.ManagerVersion, 805, 22, 120, 24, 10f, true, _muted);
            version.TextAlign = ContentAlignment.MiddleRight;
            Controls.Add(version);

            _tabs = new TabControl();
            _tabs.Location = new Point(24, 84);
            _tabs.Size = new Size(916, 578);
            _tabs.Font = new Font("Segoe UI Semibold", 9.5f);
            _homeTab = new TabPage("Home"); _homeTab.BackColor = _background;
            _detailsTab = new TabPage("Details"); _detailsTab.BackColor = _background;
            _helpTab = new TabPage("Help"); _helpTab.BackColor = _background;
            _tabs.TabPages.Add(_homeTab); _tabs.TabPages.Add(_detailsTab); _tabs.TabPages.Add(_helpTab);
            Controls.Add(_tabs);
            BuildHome();
            BuildDetails();
            BuildHelp();
        }

        private void BuildHome()
        {
            Panel setup = new Panel(); setup.Location = new Point(14, 14); setup.Size = new Size(548, 522); setup.BackColor = _background; _homeTab.Controls.Add(setup);
            Panel address = Card(0, 0, 548, 70); AddCardTitle(address, "This PC", 7);
            _ip = new ComboBox(); _ip.Location = new Point(16, 35); _ip.Size = new Size(218, 26); _ip.DropDownStyle = ComboBoxStyle.DropDownList; _ip.SelectedIndexChanged += delegate { if (!_selfTest) UpdateStatus(); }; address.Controls.Add(_ip);
            address.Controls.Add(MakeLabel("Usually leave this as-is.\r\nSame home network/router as your phone.", 250, 30, 280, 34, 9f, false, _muted)); setup.Controls.Add(address);

            Panel step1 = Card(0, 80, 548, 70); AddCardTitle(step1, "1. Prepare Relay", 10); step1.Controls.Add(MakeLabel("Download/verify the relay runtime and create the compatibility profile.", 16, 36, 350, 24, 9f, false, _muted));
            _prepare = UiButton("Prepare Relay", 382, 32, 148, 30, true, false); _prepare.Click += delegate { PrepareRelayGuided(); }; step1.Controls.Add(_prepare); setup.Controls.Add(step1);

            Panel step2 = Card(0, 160, 548, 70); AddCardTitle(step2, "2. Allow Firewall", 10); step2.Controls.Add(MakeLabel("Allow your phone to reach this PC on the trusted Private LAN.", 16, 36, 350, 24, 9f, false, _muted));
            _firewall = UiButton("Allow Firewall", 382, 32, 148, 30, false, false); _firewall.Click += delegate { AllowFirewallGuided(); }; step2.Controls.Add(_firewall); setup.Controls.Add(step2);

            Panel step3 = Card(0, 240, 548, 102); AddCardTitle(step3, "3. Android Setup", 9); step3.Controls.Add(MakeLabel("Scan/import the current profile in SFA. The temporary setup server stops automatically.", 16, 34, 500, 23, 9f, false, _muted));
            _phoneSetup = UiButton("Start Phone Setup", 16, 62, 180, 30, true, false); _phoneSetup.Click += delegate { StartPhoneSetupGuided(); }; step3.Controls.Add(_phoneSetup);
            _qr = UiButton("Show SFA QR", 204, 62, 150, 30, false, false); _qr.Click += delegate { ShowQrGuided(); }; step3.Controls.Add(_qr);
            _copyLink = UiButton("Copy SFA Link", 362, 62, 168, 30, false, false); _copyLink.Click += delegate { CopySfaLink(); }; step3.Controls.Add(_copyLink); setup.Controls.Add(step3);

            Panel step4 = Card(0, 352, 548, 70); AddCardTitle(step4, "4. DPS Meter", 10); step4.Controls.Add(MakeLabel("Target StarSEA only. Never BPSRMobileFront.", 16, 37, 330, 22, 9.5f, true, _text));
            Button copyNotes = UiButton("Copy Setup Notes", 382, 32, 148, 30, false, false); copyNotes.Click += delegate { CopyDpsNotes(); }; step4.Controls.Add(copyNotes); setup.Controls.Add(step4);

            Panel step5 = Card(0, 432, 548, 90); AddCardTitle(step5, "5. Start & Play", 9); step5.Controls.Add(MakeLabel("Run Check if needed. Start Relay guides you if phone setup is unfinished.", 16, 34, 500, 23, 9f, false, _muted));
            _check = UiButton("Run Check", 16, 57, 105, 27, false, false); _check.Click += delegate { RunCheck(); }; step5.Controls.Add(_check);
            _start = UiButton("Start Relay", 129, 57, 134, 27, true, false); _start.Click += delegate { StartRelayGuided(); }; step5.Controls.Add(_start);
            _stop = UiButton("Stop Relay", 271, 57, 108, 27, false, true); _stop.Click += delegate { StopRelayGuided(); }; step5.Controls.Add(_stop);
            _trayButton = UiButton("Minimize to Tray", 387, 57, 143, 27, false, false); _trayButton.Click += delegate { MinimizeToTray(); }; step5.Controls.Add(_trayButton); setup.Controls.Add(step5);

            Panel statusPanel = new Panel(); statusPanel.Location = new Point(578, 14); statusPanel.Size = new Size(316, 522); statusPanel.BackColor = _background; _homeTab.Controls.Add(statusPanel);
            Panel status = Card(0, 0, 316, 190); AddCardTitle(status, "Status", 10); _relayState = StatusRow(status, "Relay", 44); _runtimeState = StatusRow(status, "PC setup", 78); _profileState = StatusRow(status, "Phone profile", 112); _firewallState = StatusRow(status, "Firewall", 146); statusPanel.Controls.Add(status);
            Panel next = Card(0, 202, 316, 108); AddCardTitle(next, "What to do next", 10); _nextAction = MakeLabel("Checking your setup...", 16, 43, 284, 52, 9.25f, false, _neutral); next.Controls.Add(_nextAction); statusPanel.Controls.Add(next);
            Panel daily = Card(0, 322, 316, 100); AddCardTitle(daily, "Daily use", 10); daily.Controls.Add(MakeLabel("After first setup:\r\nPC Start Relay  ->  Phone Start SFA  ->  Open BPSR", 16, 43, 284, 52, 9.25f, false, _neutral)); statusPanel.Controls.Add(daily);
            Panel target = Card(0, 434, 316, 88); target.Controls.Add(MakeLabel("DPS meter target", 16, 11, 200, 20, 9f, false, _muted)); target.Controls.Add(MakeLabel("StarSEA", 16, 38, 284, 30, 15f, true, _text)); statusPanel.Controls.Add(target);
        }

        private void BuildDetails()
        {
            _detailsTab.Controls.Add(MakeLabel("Details & Troubleshooting", 22, 18, 500, 28, 14f, true, _text));
            _detailsTab.Controls.Add(MakeLabel("The native manager handles setup and tray lifecycle directly. You normally do not need this page.", 24, 48, 700, 22, 9f, false, _muted));
            Panel tools = Card(22, 76, 850, 74); tools.Controls.Add(MakeLabel("Tools", 14, 8, 80, 20, 9.5f, true, _muted));
            Button diag = UiButton("Copy Report", 14, 32, 120, 31, false, false); diag.Click += delegate { CopyDiagnostics(); }; tools.Controls.Add(diag);
            Button dps = UiButton("Copy DPS Notes", 142, 32, 130, 31, false, false); dps.Click += delegate { CopyDpsNotes(); }; tools.Controls.Add(dps);
            _detailsStop = UiButton("Stop Relay", 280, 32, 108, 31, false, true); _detailsStop.Click += delegate { StopRelayGuided(); }; tools.Controls.Add(_detailsStop);
            _rollback = UiButton("Restore Previous", 396, 32, 150, 31, false, false); _rollback.Click += delegate { RestorePreviousGuided(); }; tools.Controls.Add(_rollback);
            Button folder = UiButton("Open Profile Folder", 554, 32, 150, 31, false, false); folder.Click += delegate { try { Process.Start(_engine.OutputDirectory); } catch (Exception ex) { ShowFriendlyError("Could not open folder", ex); } }; tools.Controls.Add(folder); _detailsTab.Controls.Add(tools);
            Panel logs = Card(22, 162, 850, 332); logs.Controls.Add(MakeLabel("Logs", 14, 11, 100, 22, 10f, true, _text));
            _log = new TextBox(); _log.Location = new Point(14, 39); _log.Size = new Size(820, 278); _log.Multiline = true; _log.ReadOnly = true; _log.ScrollBars = ScrollBars.Vertical; _log.Font = new Font("Consolas", 9f); _log.BackColor = _surfaceSoft; _log.BorderStyle = BorderStyle.FixedSingle; logs.Controls.Add(_log); _detailsTab.Controls.Add(logs);
            _detailsTab.Controls.Add(MakeLabel("No profile password or relay credential is included when you copy the report.", 24, 506, 800, 22, 9f, false, _muted));
        }

        private void BuildHelp()
        {
            _helpTab.Controls.Add(MakeLabel("First-time setup", 22, 18, 500, 28, 14f, true, _text));
            Panel android = Card(22, 58, 850, 226); AddCardTitle(android, "Android + SFA", 10);
            string left = "1. Keep PC and phone on the same trusted router.\r\n2. Choose this PC's LAN address.\r\n3. Click Prepare Relay.\r\n4. Click Allow Firewall.\r\n5. Click Start Phone Setup.\r\n6. In SFA tap + > Scan QR Code.";
            string right = "7. Import BPSR Relay.\r\n8. Use Per-app proxy / Proxy selected apps.\r\n9. Select BPSR only.\r\n10. Set your DPS meter target to StarSEA.\r\n11. Do not target BPSRMobileFront.\r\n12. PC: Start Relay.\r\n13. Phone: Start SFA. Allow VPN permission.\r\n14. Open BPSR.";
            android.Controls.Add(MakeLabel(left, 16, 43, 390, 166, 9.25f, false, _neutral)); android.Controls.Add(MakeLabel(right, 426, 43, 405, 166, 9.25f, false, _neutral)); _helpTab.Controls.Add(android);
            Panel daily = Card(22, 296, 850, 80); AddCardTitle(daily, "Next time", 10); daily.Controls.Add(MakeLabel("Normally: Start Relay on PC -> Start SFA on phone -> Open BPSR. Use Minimize to Tray if you want the manager out of the taskbar.", 16, 40, 814, 28, 9.25f, false, _neutral)); _helpTab.Controls.Add(daily);
            Panel meter = Card(22, 388, 850, 80); AddCardTitle(meter, "DPS meter", 10); meter.Controls.Add(MakeLabel("Universal capture/process target: StarSEA. BPSRMobileFront is only the phone-facing relay process.", 16, 40, 814, 28, 9.25f, false, _neutral)); _helpTab.Controls.Add(meter);
            Panel problem = Card(22, 480, 850, 58); problem.Controls.Add(MakeLabel("If the phone cannot connect, re-check Private network + firewall. If the meter has no data, verify StarSEA is the target.", 16, 18, 814, 24, 9.25f, false, _neutral)); _helpTab.Controls.Add(problem);
        }

        private void BuildTray()
        {
            _notifyIcon = new NotifyIcon(); _notifyIcon.Text = "BPSR Android Relay"; _notifyIcon.Icon = SystemIcons.Application; _notifyIcon.Visible = !_selfTest;
            ContextMenuStrip menu = new ContextMenuStrip();
            ToolStripMenuItem open = new ToolStripMenuItem("Open BPSR Relay Manager"); open.Click += delegate { RestoreFromTray(); }; menu.Items.Add(open);
            menu.Items.Add(new ToolStripSeparator());
            _trayStatus = new ToolStripMenuItem("Relay: Stopped"); _trayStatus.Enabled = false; menu.Items.Add(_trayStatus);
            _trayStart = new ToolStripMenuItem("Start Relay"); _trayStart.Click += delegate { StartRelayGuided(); }; menu.Items.Add(_trayStart);
            _trayStop = new ToolStripMenuItem("Stop Relay"); _trayStop.Click += delegate { StopRelayGuided(); }; menu.Items.Add(_trayStop);
            menu.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem exit = new ToolStripMenuItem("Exit Manager"); exit.Click += delegate { _forceExit = true; Close(); }; menu.Items.Add(exit);
            ToolStripMenuItem stopExit = new ToolStripMenuItem("Stop Relay && Exit"); stopExit.Click += delegate { try { _engine.StopRelay(); } catch { } _forceExit = true; Close(); }; menu.Items.Add(stopExit);
            _notifyIcon.ContextMenuStrip = menu;
            _notifyIcon.MouseClick += delegate(object sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) RestoreFromTray(); };
            _notifyIcon.DoubleClick += delegate { RestoreFromTray(); };
        }

        private void LoadAddresses()
        {
            List<LanAddress> items = _engine.GetLanAddresses();
            foreach (LanAddress item in items) if (!_ip.Items.Contains(item.Address)) _ip.Items.Add(item.Address);
            string profile = _engine.GetProfilePcIp();
            if (!string.IsNullOrWhiteSpace(profile) && _ip.Items.Contains(profile)) _ip.SelectedItem = profile;
            else if (_ip.Items.Count > 0) _ip.SelectedIndex = 0;
            else _ip.DropDownStyle = ComboBoxStyle.DropDown;
        }

        private string SelectedIp()
        {
            string value = (_ip.Text ?? string.Empty).Trim();
            if (!_engine.IsLocalIp(value)) throw new InvalidOperationException("Choose the current PC Wi-Fi/Ethernet LAN address.");
            return value;
        }

        private void PrepareRelayGuided()
        {
            try
            {
                _prepare.Enabled = false; _prepare.Text = "Preparing..."; Application.DoEvents();
                string ip = SelectedIp();
                try { _engine.PrepareRelay(ip); }
                catch (Exception ex)
                {
                    if (ex.Message.IndexOf("duplicate", StringComparison.OrdinalIgnoreCase) >= 0 || ex.Message.IndexOf("Foreign", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        if (!CloseOldRelaysPrompt()) return;
                        _engine.PrepareRelay(ip);
                    }
                    else throw;
                }
            }
            catch (Exception ex) { ShowFriendlyError("Could not prepare relay", ex); }
            finally { _prepare.Text = "Prepare Relay"; UpdateStatus(); }
        }

        private bool CloseOldRelaysPrompt()
        {
            List<RelayProcessInfo> items = _engine.GetForeignRelayProcesses();
            if (items.Count == 0) return true;
            StringBuilder summary = new StringBuilder();
            foreach (RelayProcessInfo item in items) summary.AppendLine(item.Name + ".exe (PID " + item.Id + ")" + (item.ProjectOwned ? string.Empty : " - not owned by this relay folder"));
            DialogResult result = MessageBox.Show("Old/duplicate relay found:\r\n\r\n" + summary + "\r\nClose project-owned old relay processes now?", "Old relay found", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (result != DialogResult.Yes) return false;
            foreach (RelayProcessInfo item in items) _engine.CloseForeignProjectRelay(item);
            List<RelayProcessInfo> remaining = _engine.GetForeignRelayProcesses();
            if (remaining.Count > 0) { MessageBox.Show("A same-named process is still running and could not be safely identified as this project's relay. Close it manually or restart Windows.", "Could not close old relay", MessageBoxButtons.OK, MessageBoxIcon.Warning); return false; }
            return true;
        }

        private void AllowFirewallGuided()
        {
            try { _engine.AllowFirewall(SelectedIp()); }
            catch (Exception ex) { ShowFriendlyError("Could not allow connection", ex); }
            finally { UpdateStatus(); }
        }

        private void StartPhoneSetupGuided()
        {
            try
            {
                StopProfileServer();
                _profileServer = _engine.CreateProfileServer(SelectedIp());
                ShowQrGuided();
            }
            catch (Exception ex) { ShowFriendlyError("Could not start phone setup", ex); }
            finally { UpdateStatus(); }
        }

        private void ShowQrGuided()
        {
            try
            {
                if (_profileServer == null || !_profileServer.Running) throw new InvalidOperationException("Start Phone Setup first.");
                string path = _engine.CreateQrHtml(_profileServer.SfaImportUrl);
                Process.Start(path);
                _engine.Log("Opened locally generated SFA-ready QR. No QR payload was sent to an external service.");
            }
            catch (Exception ex) { ShowFriendlyError("Could not show SFA QR", ex); }
        }

        private void CopySfaLink()
        {
            try
            {
                if (_profileServer == null || !_profileServer.Running) throw new InvalidOperationException("Start Phone Setup first.");
                Clipboard.SetText(_profileServer.SfaImportUrl);
                _engine.Log("SFA import link copied.");
            }
            catch (Exception ex) { ShowFriendlyError("Could not copy SFA link", ex); }
        }

        private void StartRelayGuided()
        {
            try
            {
                string ip = SelectedIp();
                if (!_engine.PhoneProfileConfirmed())
                {
                    bool downloaded = _engine.PhoneProfileDownloaded();
                    string text = downloaded ? "The current profile was downloaded, but Windows cannot verify that SFA imported it.\r\n\r\nYes: open Phone Setup again.\r\nNo: I checked SFA and this exact profile is imported; remember it and start.\r\nCancel: do nothing." : "This PC cannot confirm that the current BPSR Relay profile is imported in SFA.\r\n\r\nYes: open Phone Setup now.\r\nNo: I already imported this exact current profile; remember it and start.\r\nCancel: do nothing.";
                    DialogResult choice = MessageBox.Show(text, "Finish phone setup first", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Information);
                    if (choice == DialogResult.Yes) { StartPhoneSetupGuided(); return; }
                    if (choice == DialogResult.No) _engine.MarkPhoneProfileConfirmed("user-confirmed-manual-import"); else return;
                }
                StopProfileServer();
                _engine.StartRelay(ip);
            }
            catch (Exception ex) { ShowFriendlyError("Could not start relay", ex); }
            finally { UpdateStatus(); }
        }

        private void StopRelayGuided()
        {
            if (!_engine.IsRelayRunning()) return;
            if (MessageBox.Show("Stop the relay now?\r\n\r\nIf BPSR is using this relay, stopping it can interrupt the phone's game connection.", "Stop relay?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            try { _engine.StopRelay(); }
            catch (Exception ex) { ShowFriendlyError("Could not stop relay", ex); }
            finally { UpdateStatus(); }
        }

        private void RestorePreviousGuided()
        {
            if (MessageBox.Show("Restore the previous verified sing-box runtime?\r\n\r\nThis is a troubleshooting action.", "Restore previous runtime?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            try { _engine.RestorePreviousRuntime(); }
            catch (Exception ex) { ShowFriendlyError("Could not restore previous version", ex); }
            finally { UpdateStatus(); }
        }

        private void RunCheck()
        {
            try
            {
                List<CheckResult> checks = _engine.GetPreflightChecks(SelectedIp());
                StringBuilder text = new StringBuilder(); int failures = 0;
                foreach (CheckResult check in checks) { text.AppendLine("[" + check.State + "] " + check.Name + " - " + check.Detail); if (check.State == "FAIL") failures++; _engine.Log("[" + check.State + "] " + check.Name + " - " + check.Detail); }
                MessageBox.Show(failures == 0 ? "Everything important looks ready.\r\n\r\nYou can click Start Relay." : text.ToString(), failures == 0 ? "Ready to use" : "One thing needs attention", MessageBoxButtons.OK, failures == 0 ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
            }
            catch (Exception ex) { ShowFriendlyError("Check could not finish", ex); }
        }

        private void CopyDpsNotes()
        {
            try { Clipboard.SetText(_engine.GetDpsNotes(SelectedIp())); _engine.Log("Copied DPS-meter StarSEA capture notes to clipboard."); }
            catch (Exception ex) { ShowFriendlyError("Could not copy notes", ex); }
        }

        private void CopyDiagnostics()
        {
            try { Clipboard.SetText(_engine.GetDiagnostics(SelectedIp())); _engine.Log("Copied privacy-safe diagnostics to clipboard."); }
            catch (Exception ex) { ShowFriendlyError("Could not copy report", ex); }
        }

        private void ShowFriendlyError(string title, Exception ex)
        {
            _engine.Log("ERROR: " + ex.Message);
            string raw = ex.Message ?? string.Empty;
            string message;
            if (raw.IndexOf("duplicate", StringComparison.OrdinalIgnoreCase) >= 0 || raw.IndexOf("Foreign", StringComparison.OrdinalIgnoreCase) >= 0) message = "An old relay is still running.\r\n\r\nClose it or restart your PC, then try again.";
            else if (raw.IndexOf("port", StringComparison.OrdinalIgnoreCase) >= 0 || raw.IndexOf("listener", StringComparison.OrdinalIgnoreCase) >= 0) message = "Another app is using the relay connection.\r\n\r\nClose the old relay or restart your PC, then try again.";
            else if (raw.IndexOf("profile", StringComparison.OrdinalIgnoreCase) >= 0 || raw.IndexOf("Prepare", StringComparison.OrdinalIgnoreCase) >= 0) message = "Your phone profile or PC setup is not ready.\r\n\r\nClick Prepare Relay, then try again.";
            else if (raw.IndexOf("firewall", StringComparison.OrdinalIgnoreCase) >= 0 || raw.IndexOf("Private", StringComparison.OrdinalIgnoreCase) >= 0 || raw.IndexOf("Administrator", StringComparison.OrdinalIgnoreCase) >= 0) message = "Windows could not allow the phone connection.\r\n\r\nClick Allow Firewall and approve the Administrator prompt on your trusted home/private network.";
            else message = "Something went wrong.\r\n\r\nOpen Details and check Logs for more information.\r\n\r\n" + raw;
            MessageBox.Show(message, title, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        private void UpdateStatus()
        {
            if (_selfTest) return;
            bool running = _engine.IsRelayRunning();
            if (running)
            {
                SetStatus(_relayState, "Running", _primary); SetStatus(_runtimeState, "Ready", _success); SetStatus(_profileState, "Ready", _success); SetStatus(_firewallState, "Ready at start", _success); _nextAction.Text = "Relay is running. Open BPSR on your phone and play."; SetButtonStates(true, true, true, true, false); UpdateTray(true); return;
            }
            string ip = (_ip.Text ?? string.Empty).Trim();
            List<RelayProcessInfo> foreign = _engine.GetForeignRelayProcesses(); bool hasForeign = foreign.Count > 0;
            SetStatus(_relayState, hasForeign ? (foreign.Count == 1 ? foreign[0].Name + ".exe" : foreign.Count + " old relays") : "Stopped", hasForeign ? _danger : _neutral);
            bool runtime = _engine.RuntimeReady(); SetStatus(_runtimeState, runtime ? "Ready" : "Needs setup", runtime ? _success : _warning);
            bool profile = !string.IsNullOrWhiteSpace(ip) && _engine.GetProfilePcIp() == ip && _engine.IsLocalIp(ip); bool confirmed = profile && _engine.PhoneProfileConfirmed(); bool downloaded = profile && _engine.PhoneProfileDownloaded();
            SetStatus(_profileState, !profile ? (string.IsNullOrWhiteSpace(_engine.GetProfilePcIp()) ? "Missing" : "Needs update") : (confirmed ? "Ready" : (downloaded ? "Downloaded - confirm" : "Import needed")), !profile ? _warning : (confirmed ? _success : _warning));
            bool firewall = profile && _engine.FirewallReady(ip); string category = profile ? _engine.GetNetworkCategory(ip) : "Unknown"; SetStatus(_firewallState, firewall ? "Ready" : (category == "Public" ? "Network is Public" : "Not set"), firewall ? _success : (category == "Public" ? _danger : _warning));
            if (hasForeign) _nextAction.Text = "Found an old/duplicate relay. Click Prepare Relay to clean it safely.";
            else if (!runtime) _nextAction.Text = "Click Prepare Relay to set up this PC.";
            else if (!profile) _nextAction.Text = "Click Prepare Relay to refresh the phone profile.";
            else if (!firewall) _nextAction.Text = "Click Allow Firewall so your phone can connect on the trusted Private LAN.";
            else if (!confirmed) _nextAction.Text = _profileServer != null && _profileServer.Running ? "Phone setup is open. Scan the QR and import BPSR Relay in SFA." : "Click Start Phone Setup and import the current profile in SFA.";
            else _nextAction.Text = "Setup is ready. Click Start Relay.";
            SetButtonStates(false, runtime, profile, firewall, hasForeign); UpdateTray(false);
            if (_profileServer != null && !_profileServer.Running) { _profileServer.Dispose(); _profileServer = null; }
        }

        private void SetButtonStates(bool running, bool runtime, bool profile, bool firewall, bool foreign)
        {
            _prepare.Enabled = !running; _firewall.Enabled = !running && runtime && profile && !foreign; _phoneSetup.Enabled = !running && profile && firewall && !foreign; _qr.Enabled = !running && _profileServer != null && _profileServer.Running; _copyLink.Enabled = _qr.Enabled; _check.Enabled = !running; _start.Enabled = !running && runtime && profile && firewall && !foreign; _stop.Enabled = running; _detailsStop.Enabled = running; _rollback.Enabled = !running;
        }

        private void UpdateTray(bool running)
        {
            if (_trayStatus == null) return; _trayStatus.Text = running ? "Relay: Running" : "Relay: Stopped"; _trayStart.Enabled = !running; _trayStop.Enabled = running;
        }

        private void SetStatus(Label label, string text, Color color) { label.Text = text; label.ForeColor = color; }

        public void MinimizeToTray()
        {
            ShowInTaskbar = false; Hide(); _hiddenToTray = true;
            if (!_trayNoticeShown && _notifyIcon != null)
            {
                _trayNoticeShown = true; _notifyIcon.BalloonTipTitle = "BPSR Android Relay"; _notifyIcon.BalloonTipText = "Still running in the system tray. Click the tray icon to reopen it."; _notifyIcon.ShowBalloonTip(2500);
            }
        }

        public void RestoreFromTray()
        {
            if (IsDisposed) return; ShowInTaskbar = true; Show(); WindowState = FormWindowState.Normal; BringToFront(); Activate(); _hiddenToTray = false;
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (_forceExit) { StopProfileServer(); return; }
            if (_engine.IsRelayRunning())
            {
                DialogResult result = MessageBox.Show("The relay is still running.\r\n\r\nYes: close this window and KEEP the relay running.\r\nNo: STOP the relay, then close.\r\nCancel: keep this window open.", "Relay is still running", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Information);
                if (result == DialogResult.Cancel) { e.Cancel = true; return; }
                if (result == DialogResult.No) { try { _engine.StopRelay(); } catch (Exception ex) { ShowFriendlyError("Could not stop relay", ex); e.Cancel = true; return; } }
            }
            else if (_profileServer != null && _profileServer.Running)
            {
                if (MessageBox.Show("Phone Setup is still open. Closing the manager will end the temporary setup link.\r\n\r\nClose anyway?", "Phone Setup is active", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) { e.Cancel = true; return; }
            }
            StopProfileServer();
        }

        private void StopProfileServer() { if (_profileServer != null) { try { _profileServer.Dispose(); } catch { } _profileServer = null; } }

        private void AppendLog(string line)
        {
            if (_log == null || _log.IsDisposed) return;
            if (_log.InvokeRequired) { try { _log.BeginInvoke((MethodInvoker)delegate { AppendLog(line); }); } catch { } return; }
            _log.AppendText(line + Environment.NewLine); _log.SelectionStart = _log.TextLength; _log.ScrollToCaret();
        }

        public void RunUiSelfTest()
        {
            if (_tabs == null || _tabs.TabPages.Count != 3) throw new InvalidOperationException("Native UI must contain Home, Details and Help tabs.");
            if (_homeTab.Text != "Home" || _detailsTab.Text != "Details" || _helpTab.Text != "Help") throw new InvalidOperationException("Native UI tab names changed unexpectedly.");
            if (_prepare.Text != "Prepare Relay" || _start.Text != "Start Relay" || _trayButton.Text != "Minimize to Tray") throw new InvalidOperationException("Primary native UI actions are missing.");
            if (_phoneSetup.Text != "Start Phone Setup" || _qr.Text != "Show SFA QR" || _copyLink.Text != "Copy SFA Link") throw new InvalidOperationException("Native SFA setup actions are missing.");
            if (_notifyIcon == null || _notifyIcon.ContextMenuStrip == null) throw new InvalidOperationException("Native tray integration is missing.");
            foreach (TabPage page in _tabs.TabPages) if (page.Width <= 0 || page.Height <= 0) throw new InvalidOperationException("Native UI layout is invalid.");
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (_timer != null) { _timer.Stop(); _timer.Dispose(); _timer = null; }
                StopProfileServer();
                if (_notifyIcon != null) { _notifyIcon.Visible = false; _notifyIcon.Dispose(); _notifyIcon = null; }
            }
            base.Dispose(disposing);
        }

        private Panel Card(int x, int y, int width, int height)
        {
            Panel panel = new Panel(); panel.Location = new Point(x, y); panel.Size = new Size(width, height); panel.BackColor = _surface; panel.BorderStyle = BorderStyle.FixedSingle; return panel;
        }

        private void AddCardTitle(Control parent, string text, int y) { parent.Controls.Add(MakeLabel(text, 16, y, parent.Width - 32, 22, 10f, true, _text)); }

        private Label StatusRow(Control parent, string title, int y)
        {
            parent.Controls.Add(MakeLabel(title, 16, y, 135, 23, 9.25f, false, _muted)); Label value = MakeLabel("Checking...", 148, y, parent.Width - 164, 23, 9.5f, true, _neutral); value.TextAlign = ContentAlignment.MiddleRight; parent.Controls.Add(value); return value;
        }

        private Label MakeLabel(string text, int x, int y, int width, int height, float size, bool semibold, Color color)
        {
            Label label = new Label(); label.Text = text; label.Location = new Point(x, y); label.Size = new Size(width, height); label.ForeColor = color; label.Font = new Font(semibold ? "Segoe UI Semibold" : "Segoe UI", size); label.AutoEllipsis = true; label.UseMnemonic = false; return label;
        }

        private Button UiButton(string text, int x, int y, int width, int height, bool primary, bool danger)
        {
            Button button = new Button(); button.Text = text; button.Location = new Point(x, y); button.Size = new Size(width, height); button.FlatStyle = FlatStyle.Flat; button.UseVisualStyleBackColor = false; button.BackColor = primary ? _primary : _surface; button.ForeColor = primary ? Color.White : (danger ? _danger : _text); button.FlatAppearance.BorderSize = 1; button.FlatAppearance.BorderColor = primary ? _primary : (danger ? Color.FromArgb(244, 190, 190) : _border); button.Font = new Font("Segoe UI Semibold", 9.25f); button.Cursor = Cursors.Hand; return button;
        }
    }
}
