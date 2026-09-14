$ErrorActionPreference = 'Stop'

$manager = Join-Path $PSScriptRoot 'BPSRRelayManager.ps1'
$script:trayNotifyIcon = $null
$script:trayContextMenu = $null
$script:trayPollTimer = $null
$script:trayHiddenByUser = $false
$script:trayOwnedIcon = $null
$script:trayNoticeShown = $false
$script:trayExitRequested = $false
$script:trayStatusItem = $null
$script:trayStartItem = $null
$script:trayStopItem = $null

function Get-BpsrRelayManagerForm {
    foreach ($openForm in [System.Windows.Forms.Application]::OpenForms) {
        if ($openForm -and -not $openForm.IsDisposed -and $openForm.Text -eq 'BPSR Android Relay') {
            return $openForm
        }
    }
    return $null
}

function Show-BpsrRelayManagerWindow {
    $window = Get-BpsrRelayManagerForm
    if (-not $window) { return }

    if ($window.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $window.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    $window.ShowInTaskbar = $true
    $window.Visible = $true
    $window.BringToFront()
    [void]$window.Activate()
    $script:trayHiddenByUser = $false
}

function Hide-BpsrRelayManagerWindow {
    $window = Get-BpsrRelayManagerForm
    if (-not $window) { return }

    $window.ShowInTaskbar = $false
    $window.Hide()
    $script:trayHiddenByUser = $true
}

function Test-BpsrRelayRunningForTray {
    if (-not (Get-Command Get-RelayTrackedRunning -ErrorAction SilentlyContinue)) {
        return $false
    }
    try { return [bool](Get-RelayTrackedRunning) }
    catch { return $false }
}

function Update-BpsrRelayTrayMenu {
    if (-not $script:trayStatusItem) { return }

    if (-not (Get-Command Get-RelayTrackedRunning -ErrorAction SilentlyContinue)) {
        $script:trayStatusItem.Text = 'Relay: Manager starting...'
        $script:trayStartItem.Enabled = $false
        $script:trayStopItem.Enabled = $false
        return
    }

    $running = Test-BpsrRelayRunningForTray
    if ($running) {
        $script:trayStatusItem.Text = 'Relay: Running'
        $script:trayStartItem.Enabled = $false
        $script:trayStopItem.Enabled = $true
        if ($script:trayNotifyIcon) { $script:trayNotifyIcon.Text = 'BPSR Android Relay - Running' }
    }
    else {
        $script:trayStatusItem.Text = 'Relay: Stopped'
        $script:trayStartItem.Enabled = $true
        $script:trayStopItem.Enabled = $false
        if ($script:trayNotifyIcon) { $script:trayNotifyIcon.Text = 'BPSR Android Relay - Stopped' }
    }
}

function Invoke-BpsrTrayStartRelay {
    if (-not (Get-Command Invoke-StartRelayGuided -ErrorAction SilentlyContinue)) { return }
    try {
        Invoke-StartRelayGuided
        Update-BpsrRelayTrayMenu
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Could not start relay',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Invoke-BpsrTrayStopRelay {
    if (-not (Get-Command Invoke-StopRelayGuided -ErrorAction SilentlyContinue)) { return }
    try {
        Invoke-StopRelayGuided
        Update-BpsrRelayTrayMenu
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Could not stop relay',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Exit-BpsrRelayTrayManager {
    param([switch]$StopRelay)

    if ($StopRelay -and (Test-BpsrRelayRunningForTray)) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Stop the relay and exit the manager?`r`n`r`nIf BPSR is using the relay, this can interrupt the phone's game connection.",
            'Stop relay and exit?',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        try { Stop-Relay }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                'Could not stop relay',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }
    }

    $script:trayExitRequested = $true
    $window = Get-BpsrRelayManagerForm
    if ($window -and -not $window.IsDisposed) {
        # Dispose directly so the old FormClosing keep/stop prompt is bypassed.
        # The explicit tray commands already define whether the relay is kept or stopped.
        $window.Dispose()
    }
    else {
        [System.Windows.Forms.Application]::ExitThread()
    }
}

function Initialize-BpsrRelayTray {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if (-not ('BpsrRelayTray.SingleInstance' -as [type])) {
        Add-Type -ReferencedAssemblies 'System.Windows.Forms.dll','System.Drawing.dll' -TypeDefinition @'
using System;
using System.Threading;
using System.Windows.Forms;

namespace BpsrRelayTray
{
    public sealed class ManagerMessageFilter : IMessageFilter
    {
        private const int WM_CLOSE = 0x0010;
        private const int WM_SYSCOMMAND = 0x0112;
        private const long SC_MINIMIZE = 0xF020L;
        private const string TargetTitle = "BPSR Android Relay";

        public static bool ExitRequested = false;
        public static bool HiddenByUser = false;

        public bool PreFilterMessage(ref Message message)
        {
            if (ExitRequested)
            {
                return false;
            }

            bool isClose = message.Msg == WM_CLOSE;
            bool isMinimize = message.Msg == WM_SYSCOMMAND &&
                (message.WParam.ToInt64() & 0xFFF0L) == SC_MINIMIZE;
            if (!isClose && !isMinimize)
            {
                return false;
            }

            Form form = Control.FromHandle(message.HWnd) as Form;
            if (form == null || !String.Equals(form.Text, TargetTitle, StringComparison.Ordinal))
            {
                return false;
            }

            form.ShowInTaskbar = false;
            form.Hide();
            HiddenByUser = true;
            return true;
        }
    }

    public static class SingleInstance
    {
        private const string MutexName = "Local\\Zudin987.BPSRAndroidRelayManager.Instance";
        private const string EventName = "Local\\Zudin987.BPSRAndroidRelayManager.Restore";
        private static Mutex mutex;
        private static EventWaitHandle restoreEvent;
        private static bool ownsMutex;

        public static bool Acquire()
        {
            bool createdNew;
            mutex = new Mutex(true, MutexName, out createdNew);
            if (!createdNew)
            {
                try
                {
                    using (EventWaitHandle signal = EventWaitHandle.OpenExisting(EventName))
                    {
                        signal.Set();
                    }
                }
                catch
                {
                    // The first instance may still be starting. It still owns the mutex,
                    // so do not open a duplicate manager/tray instance.
                }

                mutex.Dispose();
                mutex = null;
                return false;
            }

            ownsMutex = true;
            bool createdEvent;
            restoreEvent = new EventWaitHandle(false, EventResetMode.AutoReset, EventName, out createdEvent);
            return true;
        }

        public static bool ConsumeRestoreRequest()
        {
            return restoreEvent != null && restoreEvent.WaitOne(0);
        }

        public static void Release()
        {
            if (restoreEvent != null)
            {
                restoreEvent.Dispose();
                restoreEvent = null;
            }

            if (mutex != null)
            {
                if (ownsMutex)
                {
                    try { mutex.ReleaseMutex(); }
                    catch { }
                }
                mutex.Dispose();
                mutex = null;
            }
            ownsMutex = false;
        }
    }
}
'@
    }

    if (-not [BpsrRelayTray.SingleInstance]::Acquire()) {
        return $false
    }

    $script:trayHiddenByUser = $false

    $script:trayContextMenu = New-Object System.Windows.Forms.ContextMenuStrip

    $openItem = $script:trayContextMenu.Items.Add('Open BPSR Relay Manager')
    $openItem.Font = New-Object System.Drawing.Font($openItem.Font, [System.Drawing.FontStyle]::Bold)
    $openItem.Add_Click({ Show-BpsrRelayManagerWindow })

    $script:trayStatusItem = $script:trayContextMenu.Items.Add('Relay: Manager starting...')
    $script:trayStatusItem.Enabled = $false
    [void]$script:trayContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $script:trayStartItem = $script:trayContextMenu.Items.Add('Start Relay')
    $script:trayStartItem.Enabled = $false
    $script:trayStartItem.Add_Click({ Invoke-BpsrTrayStartRelay })

    $script:trayStopItem = $script:trayContextMenu.Items.Add('Stop Relay')
    $script:trayStopItem.Enabled = $false
    $script:trayStopItem.Add_Click({ Invoke-BpsrTrayStopRelay })

    [void]$script:trayContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $exitItem = $script:trayContextMenu.Items.Add('Exit Manager')
    $exitItem.Add_Click({ Exit-BpsrRelayTrayManager })

    $stopExitItem = $script:trayContextMenu.Items.Add('Stop Relay && Exit')
    $stopExitItem.Add_Click({ Exit-BpsrRelayTrayManager -StopRelay })

    $script:trayContextMenu.Add_Opening({ Update-BpsrRelayTrayMenu })

    $script:trayNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $launcherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'BPSR Relay Manager.exe'
    if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
        try { $script:trayOwnedIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($launcherPath) }
        catch { $script:trayOwnedIcon = $null }
    }
    if ($script:trayOwnedIcon) {
        $script:trayNotifyIcon.Icon = $script:trayOwnedIcon
    }
    else {
        $script:trayNotifyIcon.Icon = [System.Drawing.SystemIcons]::Application
    }
    $script:trayNotifyIcon.Text = 'BPSR Android Relay'
    $script:trayNotifyIcon.ContextMenuStrip = $script:trayContextMenu
    $script:trayNotifyIcon.Visible = $true
    $script:trayNotifyIcon.Add_MouseClick({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            Show-BpsrRelayManagerWindow
        }
    })
    $script:trayNotifyIcon.Add_DoubleClick({ Show-BpsrRelayManagerWindow })

    $script:trayPollTimer = New-Object System.Windows.Forms.Timer
    $script:trayPollTimer.Interval = 350
    $script:trayPollTimer.Add_Tick({
        try {
            if ([BpsrRelayTray.SingleInstance]::ConsumeRestoreRequest()) {
                Show-BpsrRelayManagerWindow
            }

            if ($script:trayHiddenByUser -and -not $script:trayNoticeShown) {
                $script:trayNoticeShown = $true
                $script:trayNotifyIcon.BalloonTipTitle = 'BPSR Android Relay'
                $script:trayNotifyIcon.BalloonTipText = 'Still running in the system tray. Click the tray icon to reopen it.'
                $script:trayNotifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
                $script:trayNotifyIcon.ShowBalloonTip(2500)
            }
        }
        catch {
            # Tray polling must never interfere with the relay or manager UI.
        }
    })
    $script:trayPollTimer.Start()
    return $true
}

function Stop-BpsrRelayTray {
    if ($script:trayPollTimer) {
        try { $script:trayPollTimer.Stop() } catch {}
        try { $script:trayPollTimer.Dispose() } catch {}
        $script:trayPollTimer = $null
    }

    if ($script:trayNotifyIcon) {
        try { $script:trayNotifyIcon.Visible = $false } catch {}
        try { $script:trayNotifyIcon.Dispose() } catch {}
        $script:trayNotifyIcon = $null
    }

    if ($script:trayContextMenu) {
        try { $script:trayContextMenu.Dispose() } catch {}
        $script:trayContextMenu = $null
    }

    if ($script:trayOwnedIcon) {
        try { $script:trayOwnedIcon.Dispose() } catch {}
        $script:trayOwnedIcon = $null
    }

    if ('BpsrRelayTray.SingleInstance' -as [type]) {
        try { [BpsrRelayTray.SingleInstance]::Release() } catch {}
    }
}

try {
    if (-not (Test-Path -LiteralPath $manager -PathType Leaf)) {
        throw 'BPSRRelayManager.ps1 was not found next to the launcher.'
    }

    if (-not (Initialize-BpsrRelayTray)) {
        return
    }

    try {
        # Dot-source the manager so tray actions can safely call its existing
        # Start/Stop/status functions without duplicating relay logic.
        . $manager
    }
    finally {
        Stop-BpsrRelayTray
    }
}
catch {
    $message = $_.Exception.Message
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'BPSR Relay Manager could not start',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
        Write-Host ('BPSR Relay Manager could not start: ' + $message)
    }
    exit 1
}
