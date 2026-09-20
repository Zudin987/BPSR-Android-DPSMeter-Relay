using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading.Tasks;
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
        private readonly Color _muted = Color.FromArgb(71, 85, 105);
        private readonly Color _border = Color.FromArgb(203, 213, 225);
        private readonly Color _primary = Color.FromArgb(37, 99, 235);
        private readonly Color _primarySoft = Color.FromArgb(239, 246, 255);
        private readonly Color _successSoft = Color.FromArgb(240, 253, 244);
        private readonly Color _warningSoft = Color.FromArgb(255, 247, 237);
        private readonly Color _dangerSoft = Color.FromArgb(254, 242, 242);
        private readonly Color _success = Color.FromArgb(21, 128, 61);
        private readonly Color _warning = Color.FromArgb(180, 83, 9);
        private readonly Color _danger = Color.FromArgb(185, 28, 28);
        private readonly Color _neutral = Color.FromArgb(51, 65, 85);

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
        private Label _overallState;
        private Label _adapterInfo;
        private ToolTip _toolTip;
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
        private bool _trayNoticeShown;
        private bool _busy;

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
            Text = "BPSR Relay Manager";
            ClientSize = new Size(964, 690);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            MinimizeBox = true;
            AutoScroll = true;
            BackColor = _background;
            Font = new Font("Segoe UI", 9.25f);
            AutoScaleMode = AutoScaleMode.Dpi;
            FormClosing += OnFormClosing;
        }

        private void BuildUi()
        {
            Label title = MakeLabel("BPSR Relay Manager", 24, 16, 650, 31, 17f, true, _text);
            Controls.Add(title);
            Controls.Add(MakeLabel("Play BPSR on Android with your compatible PC DPS meter", 27, 49, 650, 22, 9.25f, false, _muted));
            Label version = MakeLabel("v" + _engine.ManagerVersion, 805, 22, 120, 24, 10f, true, _muted);
            version.TextAlign = ContentAlignment.MiddleRight;
            Controls.Add(version);
            _overallState = MakeLabel("CHECKING", 744, 49, 181, 25, 9.25f, true, _neutral);
            _overallState.TextAlign = ContentAlignment.MiddleCenter;
            _overallState.BackColor = _surfaceSoft;
            _overallState.BorderStyle = BorderStyle.FixedSingle;
            Controls.Add(_overallState);

            _toolTip = new ToolTip();
            _toolTip.AutoPopDelay = 9000;
            _toolTip.InitialDelay = 350;
            _toolTip.ReshowDelay = 100;
            _toolTip.ShowAlways = true;

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
            _toolTip.SetToolTip(_ip, "LAN IPv4 address Android will connect to. Usually leave the first auto-selected address.");
            _adapterInfo = MakeLabel("Auto-selected LAN adapter.\r\nPhone must use the same router.", 250, 30, 280, 34, 9f, false, _muted); address.Controls.Add(_adapterInfo); setup.Controls.Add(address);

            Panel step1 = Card(0, 80, 548, 70); AddCardTitle(step1, "1. Prepare Relay", 10); step1.Controls.Add(MakeLabel("Prepare the relay and phone profile.", 16, 36, 350, 24, 9f, false, _muted));
            _prepare = UiButton("Prepare Relay", 382, 32, 148, 30, false, false); _prepare.Click += delegate { PrepareRelayGuided(); }; step1.Controls.Add(_prepare); _toolTip.SetToolTip(_prepare, "Download/verify the relay runtime and generate the current phone profile."); setup.Controls.Add(step1);

            Panel step2 = Card(0, 160, 548, 70); AddCardTitle(step2, "2. Allow Firewall", 10); step2.Controls.Add(MakeLabel("Approve Windows access on your private LAN.", 16, 36, 350, 24, 9f, false, _muted));
            _firewall = UiButton("Allow Firewall", 382, 32, 148, 30, false, false); _firewall.Click += delegate { AllowFirewallGuided(); }; step2.Controls.Add(_firewall); _toolTip.SetToolTip(_firewall, "Windows will ask for Administrator approval. This only opens the relay to your trusted Private LAN."); setup.Controls.Add(step2);

            Panel step3 = Card(0, 240, 548, 102); AddCardTitle(step3, "3. Android Setup", 9); step3.Controls.Add(MakeLabel("Import the profile in SFA on your phone.", 16, 34, 500, 23, 9f, false, _muted));
            _phoneSetup = UiButton("Start Phone Setup", 16, 62, 180, 30, false, false); _phoneSetup.Click += delegate { StartPhoneSetupGuided(); }; step3.Controls.Add(_phoneSetup); _toolTip.SetToolTip(_phoneSetup, "Temporarily serve the current SFA profile to your phone and open the local QR flow.");
            _qr = UiButton("Show SFA QR", 204, 62, 150, 30, false, false); _qr.Click += delegate { ShowQrGuided(); }; step3.Controls.Add(_qr); _toolTip.SetToolTip(_qr, "Open the locally generated QR page for the active phone setup session.");
            _copyLink = UiButton("Copy SFA Link", 362, 62, 168, 30, false, false); _copyLink.Click += delegate { CopySfaLink(); }; step3.Controls.Add(_copyLink); _toolTip.SetToolTip(_copyLink, "Copy the current local SFA import link instead of scanning the QR."); setup.Controls.Add(step3);

            Panel step4 = Card(0, 352, 548, 70); AddCardTitle(step4, "4. DPS Meter", 10); step4.Controls.Add(MakeLabel("Target StarSEA only. Never BPSRMobileFront.", 16, 37, 330, 22, 9.5f, true, _text));
            Button copyNotes = UiButton("Copy Setup Notes", 382, 32, 148, 30, false, false); copyNotes.Click += delegate { CopyDpsNotes(); }; step4.Controls.Add(copyNotes); setup.Controls.Add(step4);

            Panel step5 = Card(0, 432, 548, 90); AddCardTitle(step5, "5. Start & Play", 9); step5.Controls.Add(MakeLabel("Start the relay, then open SFA and BPSR on your phone.", 16, 34, 500, 23, 9f, false, _muted));
            _check = UiButton("Run Check", 16, 55, 105, 30, false, false); _check.Click += delegate { RunCheck(); }; step5.Controls.Add(_check); _toolTip.SetToolTip(_check, "Run a quick readiness check without starting the relay.");
            _start = UiButton("Start Relay", 129, 55, 134, 30, false, false); _start.Click += delegate { StartRelayGuided(); }; step5.Controls.Add(_start); _toolTip.SetToolTip(_start, "Start the phone-facing relay and StarSEA process target.");
            _stop = UiButton("Stop Relay", 271, 55, 108, 30, false, true); _stop.Click += delegate { StopRelayGuided(); }; step5.Controls.Add(_stop); _toolTip.SetToolTip(_stop, "Stop the active relay. This can interrupt BPSR if the phone is currently using it.");
            _trayButton = UiButton("Minimize to Tray", 387, 55, 143, 30, false, false); _trayButton.Click += delegate { MinimizeToTray(); }; step5.Controls.Add(_trayButton); _toolTip.SetToolTip(_trayButton, "Hide this window while keeping the manager available from the system tray."); setup.Controls.Add(step5);

            Panel statusPanel = new Panel(); statusPanel.Location = new Point(578, 14); statusPanel.Size = new Size(316, 522); statusPanel.BackColor = _background; _homeTab.Controls.Add(statusPanel);
            Panel status = Card(0, 0, 316, 190); AddCardTitle(status, "Status", 10); _relayState = StatusRow(status, "Relay", 44); _runtimeState = StatusRow(status, "PC setup", 78); _profileState = StatusRow(status, "Phone profile", 112); _firewallState = StatusRow(status, "Firewall", 146); statusPanel.Controls.Add(status);
            Panel next = Card(0, 202, 316, 108); AddCardTitle(next, "What to do next", 10); _nextAction = MakeLabel("Checking your setup...", 16, 41, 284, 56, 9.5f, true, _neutral); next.Controls.Add(_nextAction); statusPanel.Controls.Add(next);
            Panel daily = Card(0, 322, 316, 100); AddCardTitle(daily, "Daily use", 10); daily.Controls.Add(MakeLabel("1. PC: Start Relay\r\n2. Phone: Start SFA, then open BPSR", 16, 43, 284, 52, 9.25f, false, _neutral)); statusPanel.Controls.Add(daily);
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
            _notifyIcon = new NotifyIcon(); _notifyIcon.Text = "BPSR Relay Manager - Relay stopped"; _notifyIcon.Icon = SystemIcons.Application; _notifyIcon.Visible = !_selfTest;
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

        private async void PrepareRelayGuided()
        {
            if (_busy) return;
            try
            {
                string ip = SelectedIp();
                BeginSetupAction(_prepare, "Preparing...", "Preparing the relay and phone profile. The first download may take a moment.");
                StopProfileServer();
                bool retry = false;
                try { await Task.Run(delegate { _engine.PrepareRelay(ip); }); }
                catch (Exception ex)
                {
                    if (ex.Message.IndexOf("duplicate", StringComparison.OrdinalIgnoreCase) >= 0 || ex.Message.IndexOf("Foreign", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        if (!CloseOldRelaysPrompt()) return;
                        retry = true;
                    }
                    else throw;
                }
                if (retry) await Task.Run(delegate { _engine.PrepareRelay(ip); });
            }
            catch (Exception ex) { ShowFriendlyError("Could not prepare relay", ex); }
            finally { EndSetupAction(_prepare, "Prepare Relay"); }
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

        private async void AllowFirewallGuided()
        {
            if (_busy) return;
            try
            {
                string ip = SelectedIp();
                BeginSetupAction(_firewall, "Allowing...", "Approve the Windows Administrator prompt to allow your phone connection.");
                await Task.Run(delegate { _engine.AllowFirewall(ip); });
            }
            catch (Win32Exception ex)
            {
                if (ex.NativeErrorCode == 1223) _engine.Log("Administrator prompt cancelled. Click Allow Firewall when ready.");
                else ShowFriendlyError("Could not allow connection", ex);
            }
            catch (Exception ex) { ShowFriendlyError("Could not allow connection", ex); }
            finally { EndSetupAction(_firewall, "Allow Firewall"); }
        }

        private void BeginSetupAction(Button button, string caption, string guidance)
        {
            _busy = true;
            button.Text = caption;
            _tabs.Enabled = false;
            _notifyIcon.ContextMenuStrip.Enabled = false;
            UseWaitCursor = true;
            _nextAction.Text = guidance;
            SetOverallState("SETUP IN PROGRESS", _primary, _primarySoft);
        }

        private void EndSetupAction(Button button, string caption)
        {
            _busy = false;
            button.Text = caption;
            _tabs.Enabled = true;
            _notifyIcon.ContextMenuStrip.Enabled = true;
            UseWaitCursor = false;
            UpdateStatus();
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
                _engine.Log("Opened locally generated QR. Remote profile auto-update must be disabled in SFA after import; alternatively import the downloaded JSON as a local profile.");
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

        private async void StartRelayGuided()
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
        }

        private Form CreatePhoneSetupPrompt(bool downloaded)
        {
            Form prompt = new Form();
            prompt.Text = "Finish phone setup";
            prompt.ClientSize = new Size(520, 214);
            prompt.FormBorderStyle = FormBorderStyle.FixedDialog;
            prompt.StartPosition = FormStartPosition.CenterParent;
            prompt.MaximizeBox = false;
            prompt.MinimizeBox = false;
            prompt.ShowInTaskbar = false;
            prompt.BackColor = _background;
            prompt.Font = Font;
            prompt.AutoScaleMode = AutoScaleMode.Dpi;
            prompt.Icon = Icon;
            prompt.Controls.Add(MakeLabel("Is this phone profile imported in SFA?", 20, 18, 480, 28, 12f, true, _text));
            string explanation = downloaded ? "The profile was downloaded. Check that you imported it in SFA." : "Open Phone Setup to import the current BPSR Relay profile in SFA.";
            prompt.Controls.Add(MakeLabel(explanation, 20, 58, 480, 42, 9.25f, false, _neutral));
            prompt.Controls.Add(MakeLabel("Choose Already Imported only after checking the current profile on your phone. The relay will then start.", 20, 104, 480, 44, 9.25f, false, _muted));
            Button setup = UiButton("Open Phone Setup", 20, 164, 176, 32, true, false);
            setup.DialogResult = DialogResult.Yes;
            Button imported = UiButton("Already Imported", 206, 164, 176, 32, false, false);
            imported.DialogResult = DialogResult.No;
            Button cancel = UiButton("Cancel", 392, 164, 108, 32, false, false);
            cancel.DialogResult = DialogResult.Cancel;
            prompt.Controls.Add(setup); prompt.Controls.Add(imported); prompt.Controls.Add(cancel);
            prompt.AcceptButton = setup;
            prompt.CancelButton = cancel;
            return prompt;
        }

        private async void StopRelayGuided()
        {
            if (_busy || !_engine.IsRelayRunning()) return;
            if (MessageBox.Show("Stop the relay now?\r\n\r\nIf BPSR is using this relay, stopping it can interrupt the phone's game connection.", "Stop relay?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            BeginSetupAction(_stop, "Stopping...", "Stopping both relay stages safely...");
            try { await Task.Run(delegate { _engine.StopRelay(); }); }
            catch (Exception ex) { ShowFriendlyError("Could not stop relay", ex); }
            finally { EndSetupAction(_stop, "Stop Relay"); }
        }

        private async void RestorePreviousGuided()
        {
            if (_busy) return;
            if (MessageBox.Show("Restore the previous verified sing-box runtime?\r\n\r\nThis is a troubleshooting action.", "Restore previous runtime?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            BeginSetupAction(_rollback, "Restoring...", "Restoring and verifying the previous runtime...");
            try { await Task.Run(delegate { _engine.RestorePreviousRuntime(); }); }
            catch (Exception ex) { ShowFriendlyError("Could not restore previous version", ex); }
            finally { EndSetupAction(_rollback, "Restore Previous"); }
        }

        private void RunCheck()
        {
            try
            {
                List<CheckResult> checks = _engine.GetPreflightChecks(SelectedIp(), _profileServer != null && _profileServer.Running);
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
            if (_selfTest || _busy) return;
            string selectedIp = (_ip.Text ?? string.Empty).Trim();
            UpdateAdapterSummary(selectedIp);
            bool running = _engine.IsRelayRunning();
            if (running)
            {
                SetStatus(_relayState, "Running", _success); SetStatus(_runtimeState, "Ready", _success); SetStatus(_profileState, _engine.PhoneProfileConfirmed() ? "Saved (phone not probed)" : "Not confirmed", _engine.PhoneProfileConfirmed() ? _success : _warning); SetStatus(_firewallState, "Ready", _success); _nextAction.Text = "Relay is running. Start SFA on your phone if needed, then open BPSR and play."; SetButtonStates(true, true, true, true, false); SetOverallState("RELAY RUNNING", _success, _successSoft); SetRecommendedAction(null); UpdateTray(true); return;
            }
            string ip = selectedIp;
            List<RelayProcessInfo> foreign = _engine.GetForeignRelayProcesses(); bool hasForeign = foreign.Count > 0;
            SetStatus(_relayState, hasForeign ? (foreign.Count == 1 ? "Old relay found" : foreign.Count + " old relays") : "Stopped", hasForeign ? _danger : _neutral);
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
            Button recommended;
            if (hasForeign) { SetOverallState("ACTION REQUIRED", _danger, _dangerSoft); recommended = _prepare; }
            else if (!runtime || !profile) { SetOverallState("SETUP NEEDED", _warning, _warningSoft); recommended = _prepare; }
            else if (!firewall) { SetOverallState("SETUP NEEDED", _warning, _warningSoft); recommended = _firewall; }
            else if (!confirmed) { SetOverallState("FINISH PHONE SETUP", _warning, _warningSoft); recommended = _profileServer != null && _profileServer.Running ? _qr : _phoneSetup; }
            else { SetOverallState("READY TO START", _primary, _primarySoft); recommended = _start; }
            SetButtonStates(false, runtime, profile, firewall, hasForeign); SetRecommendedAction(recommended); UpdateTray(false);
            if (_profileServer != null && !_profileServer.Running) { _profileServer.Dispose(); _profileServer = null; }
        }

        private void SetButtonStates(bool running, bool runtime, bool profile, bool firewall, bool foreign)
        {
            _prepare.Enabled = !running; _firewall.Enabled = !running && runtime && profile && !foreign; _phoneSetup.Enabled = !running && profile && firewall && !foreign; _qr.Enabled = !running && _profileServer != null && _profileServer.Running; _copyLink.Enabled = _qr.Enabled; _check.Enabled = !running; _start.Enabled = !running && runtime && profile && firewall && !foreign; _stop.Enabled = running; _detailsStop.Enabled = running; _rollback.Enabled = !running;
        }

        private void UpdateTray(bool running)
        {
            if (_trayStatus == null) return; _trayStatus.Text = running ? "Relay: Running" : "Relay: Stopped"; _trayStart.Enabled = !running; _trayStop.Enabled = running; if (_notifyIcon != null) _notifyIcon.Text = running ? "BPSR Relay Manager - Relay running" : "BPSR Relay Manager - Relay stopped";
        }

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

        public void MinimizeToTray()
        {
            ShowInTaskbar = false; Hide();
            if (!_trayNoticeShown && _notifyIcon != null)
            {
                _trayNoticeShown = true; _notifyIcon.BalloonTipTitle = "BPSR Android Relay"; _notifyIcon.BalloonTipText = "Still running in the system tray. Click the tray icon to reopen it."; _notifyIcon.ShowBalloonTip(2500);
            }
        }

        public void RestoreFromTray()
        {
            if (IsDisposed) return; ShowInTaskbar = true; Show(); WindowState = FormWindowState.Normal; BringToFront(); Activate();
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (_busy && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; return; }
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
            if (_overallState == null || _adapterInfo == null || _toolTip == null) throw new InvalidOperationException("Native visibility/UX guidance controls are missing.");
            foreach (TabPage page in _tabs.TabPages) if (page.Width <= 0 || page.Height <= 0) throw new InvalidOperationException("Native UI layout is invalid.");
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (_timer != null) { _timer.Stop(); _timer.Dispose(); _timer = null; }
                StopProfileServer();
                if (_notifyIcon != null) { _notifyIcon.Visible = false; _notifyIcon.Dispose(); _notifyIcon = null; }
                if (_toolTip != null) { _toolTip.Dispose(); _toolTip = null; }
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
            parent.Controls.Add(MakeLabel(title, 16, y, 108, 23, 9.25f, false, _muted)); Label value = MakeLabel("Checking...", 124, y, parent.Width - 140, 23, 9.25f, true, _neutral); value.TextAlign = ContentAlignment.MiddleRight; parent.Controls.Add(value); return value;
        }

        private Label MakeLabel(string text, int x, int y, int width, int height, float size, bool semibold, Color color)
        {
            Label label = new Label(); label.Text = text; label.Location = new Point(x, y); label.Size = new Size(width, height); label.ForeColor = color; label.Font = new Font(semibold ? "Segoe UI Semibold" : "Segoe UI", size); label.AutoEllipsis = true; label.UseMnemonic = false; label.AccessibleName = text; return label;
        }

        private Button UiButton(string text, int x, int y, int width, int height, bool primary, bool danger)
        {
            Button button = new Button(); button.Text = text; button.Location = new Point(x, y); button.Size = new Size(width, height); button.FlatStyle = FlatStyle.Flat; button.UseVisualStyleBackColor = false; button.FlatAppearance.BorderSize = 1; button.Font = new Font("Segoe UI Semibold", 9.25f); button.Cursor = Cursors.Hand; button.AccessibleName = text; StyleButton(button, primary, danger); return button;
        }
    }
}
