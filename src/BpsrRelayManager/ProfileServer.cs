using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace BpsrRelayManager
{
    internal sealed class ProfileServer : IDisposable
    {
        private readonly string _bindIp;
        private readonly int _port;
        private readonly string _token;
        private readonly string _profilePath;
        private readonly string _profileId;
        private readonly Action _onDownloaded;
        private readonly Action<string> _log;
        private TcpListener _listener;
        private Thread _thread;
        private volatile bool _stop;
        private volatile bool _running;
        private DateTime _deadline;

        public ProfileServer(string bindIp, int port, string token, string profilePath, string profileId, Action onDownloaded, Action<string> log)
        {
            _bindIp = bindIp;
            _port = port;
            _token = token;
            _profilePath = profilePath;
            _profileId = profileId;
            _onDownloaded = onDownloaded;
            _log = log;
        }

        public bool Running { get { return _running; } }
        public string BaseUrl { get { return "http://" + _bindIp + ":" + _port + "/" + _token + "/"; } }
        public string ProfileUrl { get { return BaseUrl + "android-bpsr-relay.json"; } }
        public string SfaImportUrl { get { return "sing-box://import-remote-profile?url=" + Uri.EscapeDataString(ProfileUrl) + "#" + Uri.EscapeDataString("BPSR Relay"); } }

        public void Start()
        {
            if (_running) return;
            IPAddress ip = IPAddress.Parse(_bindIp);
            _listener = new TcpListener(ip, _port);
            _listener.Server.NoDelay = true;
            _listener.Start(8);
            _deadline = DateTime.UtcNow.AddMinutes(5);
            _stop = false;
            _running = true;
            _thread = new Thread(ServerLoop);
            _thread.IsBackground = true;
            _thread.Name = "BPSR Relay phone setup server";
            _thread.Start();
            if (_log != null) _log("Temporary SFA setup started for up to 300 seconds.");
        }

        public void Stop()
        {
            _stop = true;
            try { if (_listener != null) _listener.Stop(); } catch { }
            _running = false;
        }

        private void ServerLoop()
        {
            bool served = false;
            try
            {
                while (!_stop && !served && DateTime.UtcNow < _deadline)
                {
                    TcpClient client = null;
                    try
                    {
                        if (!_listener.Pending()) { Thread.Sleep(100); continue; }
                        client = _listener.AcceptTcpClient();
                        client.NoDelay = true;
                        client.ReceiveTimeout = 3000;
                        client.SendTimeout = 3000;
                        using (NetworkStream stream = client.GetStream())
                        {
                            string request = ReadRequest(stream);
                            string[] lines = request.Split(new string[] { "\r\n" }, StringSplitOptions.None);
                            string first = lines.Length > 0 ? lines[0] : string.Empty;
                            string[] parts = first.Split(' ');
                            if (parts.Length < 3 || (parts[0] != "GET" && parts[0] != "HEAD"))
                            {
                                WriteResponse(stream, 400, "Bad Request", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Bad request"), false);
                                continue;
                            }
                            bool headOnly = parts[0] == "HEAD";
                            string path = parts[1];
                            int q = path.IndexOf('?');
                            if (q >= 0) path = path.Substring(0, q);
                            string basePath = "/" + _token + "/";
                            string download = basePath + "android-bpsr-relay.json";
                            if (path == basePath)
                            {
                                string html = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>BPSR Relay Setup</title><style>body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;max-width:620px;margin:48px auto;padding:0 20px;line-height:1.5;background:#111;color:#eee}.card{background:#1c1c1c;border:1px solid #333;border-radius:14px;padding:24px}a.button{display:inline-block;margin-top:14px;padding:12px 18px;border-radius:9px;background:#eee;color:#111;text-decoration:none;font-weight:700}.small{color:#aaa;font-size:.92rem}</style></head><body><div class=\"card\"><h2>BPSR Android DPSMeter Relay</h2><p>Your BPSR profile is ready.</p><p><a class=\"button\" href=\"" + WebUtility.HtmlEncode(SfaImportUrl) + "\">Open in SFA</a></p><p><a href=\"android-bpsr-relay.json\" download>Download SFA profile</a></p><p class=\"small\">This local page expires after setup and is not used while gaming.</p></div></body></html>";
                                WriteResponse(stream, 200, "OK", "text/html; charset=utf-8", Encoding.UTF8.GetBytes(html), headOnly);
                            }
                            else if (path == download)
                            {
                                byte[] body = File.ReadAllBytes(_profilePath);
                                WriteResponse(stream, 200, "OK", "application/json; charset=utf-8", body, headOnly);
                                if (!headOnly)
                                {
                                    served = true;
                                    try { if (_onDownloaded != null && !string.IsNullOrWhiteSpace(_profileId)) _onDownloaded(); } catch { }
                                }
                            }
                            else WriteResponse(stream, 404, "Not Found", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Not found"), headOnly);
                        }
                    }
                    catch { }
                    finally { if (client != null) try { client.Close(); } catch { } }
                }
            }
            finally
            {
                try { if (_listener != null) _listener.Stop(); } catch { }
                _running = false;
                if (_log != null) _log(served ? "Phone profile downloaded; temporary setup server stopped." : "Phone setup link ended/expired.");
            }
        }

        private static string ReadRequest(NetworkStream stream)
        {
            MemoryStream data = new MemoryStream();
            byte[] buffer = new byte[4096];
            while (data.Length < 16384)
            {
                int read = stream.Read(buffer, 0, buffer.Length);
                if (read <= 0) break;
                data.Write(buffer, 0, read);
                string text = Encoding.ASCII.GetString(data.ToArray());
                if (text.IndexOf("\r\n\r\n", StringComparison.Ordinal) >= 0) return text;
            }
            return Encoding.ASCII.GetString(data.ToArray());
        }

        private static void WriteResponse(NetworkStream stream, int status, string statusText, string contentType, byte[] body, bool headOnly)
        {
            string headers = "HTTP/1.1 " + status + " " + statusText + "\r\nContent-Type: " + contentType + "\r\nContent-Length: " + body.Length + "\r\nCache-Control: no-store, no-cache, must-revalidate\r\nPragma: no-cache\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n";
            byte[] headerBytes = Encoding.ASCII.GetBytes(headers);
            stream.Write(headerBytes, 0, headerBytes.Length);
            if (!headOnly && body.Length > 0) stream.Write(body, 0, body.Length);
            stream.Flush();
        }

        public void Dispose() { Stop(); }
    }
}
