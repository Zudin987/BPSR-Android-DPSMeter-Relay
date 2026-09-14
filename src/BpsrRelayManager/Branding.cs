using System;
using System.Drawing;
using System.Reflection;
using System.Windows.Forms;

namespace BpsrRelayManager
{
    internal static class Branding
    {
        private static Icon _appIcon;

        public static void Apply(MainForm form)
        {
            if (form == null) throw new ArgumentNullException("form");

            Icon icon = GetAppIcon();
            form.Icon = icon;

            FieldInfo field = typeof(MainForm).GetField("_notifyIcon", BindingFlags.Instance | BindingFlags.NonPublic);
            if (field == null) throw new InvalidOperationException("Native tray icon field is missing.");

            NotifyIcon notifyIcon = field.GetValue(form) as NotifyIcon;
            if (notifyIcon == null) throw new InvalidOperationException("Native tray icon is not initialized.");
            notifyIcon.Icon = icon;
        }

        private static Icon GetAppIcon()
        {
            if (_appIcon != null) return _appIcon;

            Icon extracted = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            if (extracted == null) throw new InvalidOperationException("Embedded BPSR Relay Manager application icon could not be loaded.");
            _appIcon = extracted;
            return _appIcon;
        }
    }
}
