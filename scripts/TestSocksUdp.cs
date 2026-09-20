// Developer-only integration test: exercises a real SOCKS5 UDP ASSOCIATE through
// BPSRMobileFront -> StarSEA using an ephemeral localhost UDP echo target.
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public static class SocksUdpSmoke
{
    private static byte[] ReadExact(NetworkStream stream, int count)
    {
        byte[] result = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            int read = stream.Read(result, offset, count - offset);
            if (read <= 0) throw new IOException("SOCKS5 server closed the handshake unexpectedly.");
            offset += read;
        }
        return result;
    }

    private static void Write(NetworkStream stream, byte[] data)
    {
        stream.Write(data, 0, data.Length);
        stream.Flush();
    }

    public static double Run(int frontPort, string username, string password)
    {
        if (frontPort <= 0 || frontPort > 65535) throw new ArgumentException("Invalid front port.");
        byte[] user = Encoding.UTF8.GetBytes(username);
        byte[] pass = Encoding.UTF8.GetBytes(password);
        if (user.Length == 0 || user.Length > 255 || pass.Length == 0 || pass.Length > 255)
            throw new ArgumentException("Invalid SOCKS5 credentials.");

        using (UdpClient echo = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0)))
        using (UdpClient udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0)))
        using (TcpClient control = new TcpClient())
        {
            echo.Client.ReceiveTimeout = 3000;
            udp.Client.ReceiveTimeout = 4000;
            int echoPort = ((IPEndPoint)echo.Client.LocalEndPoint).Port;
            int localUdpPort = ((IPEndPoint)udp.Client.LocalEndPoint).Port;
            Exception echoError = null;
            Thread worker = new Thread(delegate()
            {
                try
                {
                    IPEndPoint peer = new IPEndPoint(IPAddress.Any, 0);
                    byte[] data = echo.Receive(ref peer);
                    echo.Send(data, data.Length, peer);
                }
                catch (Exception ex) { echoError = ex; }
            });
            worker.IsBackground = true;
            worker.Start();

            control.ReceiveTimeout = 4000;
            control.SendTimeout = 4000;
            control.Connect(IPAddress.Loopback, frontPort);
            NetworkStream stream = control.GetStream();
            Write(stream, new byte[] { 5, 1, 2 }); // Username/password method only.
            byte[] selection = ReadExact(stream, 2);
            if (selection[0] != 5 || selection[1] != 2)
                throw new IOException("Front SOCKS5 did not select username/password authentication.");
            byte[] auth = new byte[3 + user.Length + pass.Length];
            auth[0] = 1;
            auth[1] = (byte)user.Length;
            Buffer.BlockCopy(user, 0, auth, 2, user.Length);
            auth[2 + user.Length] = (byte)pass.Length;
            Buffer.BlockCopy(pass, 0, auth, 3 + user.Length, pass.Length);
            Write(stream, auth);
            byte[] authReply = ReadExact(stream, 2);
            if (authReply[0] != 1 || authReply[1] != 0)
                throw new IOException("Front SOCKS5 rejected valid UDP test credentials.");

            Write(stream, new byte[] { 5, 3, 0, 1, 127, 0, 0, 1, (byte)(localUdpPort >> 8), (byte)localUdpPort });
            byte[] response = ReadExact(stream, 4);
            if (response[0] != 5 || response[1] != 0 || response[2] != 0)
                throw new IOException("Front SOCKS5 rejected UDP ASSOCIATE (reply " + response[1] + ").");
            IPAddress relayIp;
            if (response[3] == 1) relayIp = new IPAddress(ReadExact(stream, 4));
            else if (response[3] == 4) relayIp = new IPAddress(ReadExact(stream, 16));
            else if (response[3] == 3)
            {
                int length = ReadExact(stream, 1)[0];
                string host = Encoding.ASCII.GetString(ReadExact(stream, length));
                IPAddress[] ips = Dns.GetHostAddresses(host);
                if (ips.Length == 0) throw new IOException("Could not resolve SOCKS UDP relay address.");
                relayIp = ips[0];
            }
            else throw new IOException("Unexpected SOCKS UDP relay address type.");
            byte[] portBytes = ReadExact(stream, 2);
            int relayPort = (portBytes[0] << 8) | portBytes[1];
            if (relayPort <= 0) throw new IOException("SOCKS UDP relay returned an invalid port.");
            if (relayIp.Equals(IPAddress.Any) || relayIp.Equals(IPAddress.IPv6Any)) relayIp = IPAddress.Loopback;

            byte[] payload = Encoding.ASCII.GetBytes("bpsr-two-stage-udp-smoke");
            byte[] request = new byte[10 + payload.Length];
            request[3] = 1; // SOCKS UDP header: RSV(2), FRAG(1), ATYP(1).
            byte[] address = IPAddress.Loopback.GetAddressBytes();
            Buffer.BlockCopy(address, 0, request, 4, 4);
            request[8] = (byte)(echoPort >> 8);
            request[9] = (byte)echoPort;
            Buffer.BlockCopy(payload, 0, request, 10, payload.Length);
            IPEndPoint relay = new IPEndPoint(relayIp, relayPort);
            Stopwatch timer = Stopwatch.StartNew();
            udp.Send(request, request.Length, relay);
            IPEndPoint from = new IPEndPoint(IPAddress.Any, 0);
            byte[] reply = udp.Receive(ref from);
            timer.Stop();
            if (reply.Length < 10 + payload.Length || reply[2] != 0 || reply[3] != 1)
                throw new IOException("Invalid SOCKS5 UDP response header.");
            for (int i = 0; i < payload.Length; i++)
                if (reply[reply.Length - payload.Length + i] != payload[i])
                    throw new IOException("UDP payload changed or did not traverse both relay processes.");
            if (!worker.Join(1500)) throw new IOException("UDP echo server never received the forwarded datagram.");
            if (echoError != null) throw new IOException("UDP echo target failed.", echoError);
            return timer.Elapsed.TotalMilliseconds;
        }
    }
}
