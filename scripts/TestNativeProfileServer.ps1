param(
    [Parameter(Mandatory = $true)][string]$ManagerExe
)

$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path -LiteralPath $ManagerExe).Path
$assembly = [System.Reflection.Assembly]::LoadFrom($exe)
$type = $assembly.GetType('BpsrRelayManager.ProfileServer', $true)
$binding = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::NonPublic
$start = $type.GetMethod('Start', $binding)
$stop = $type.GetMethod('Stop', $binding)
$running = $type.GetProperty('Running', $binding)
$urlProperty = $type.GetProperty('ProfileUrl', $binding)

# C# builds a CLR object[] directly: PowerShell reflection arguments otherwise sometimes
# contain PSObject wrappers that cannot be converted to the internal string parameters.
Add-Type -TypeDefinition @'
using System;
using System.Reflection;
public static class NativeProfileFactory
{
    public static object Create(Type type, string ip, int port, string token, string path)
    {
        var flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance;
        var ctor = type.GetConstructor(flags, null, new Type[] {
            typeof(string), typeof(int), typeof(string), typeof(string), typeof(string),
            typeof(Action), typeof(Action<string>) }, null);
        if (ctor == null) throw new InvalidOperationException("Native profile server constructor changed.");
        return ctor.Invoke(new object[] { ip, port, token, path, "test-profile-id", null, null });
    }
}
'@

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('bpsr-native-profile-test-' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($temp)
$path = Join-Path $temp 'android-bpsr-relay.json'
$profile = '{"test":"native-server-repeat-import"}'
[System.IO.File]::WriteAllText($path, $profile, (New-Object System.Text.UTF8Encoding($false)))
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = [int]$listener.LocalEndpoint.Port
$listener.Stop()
$token = [Guid]::NewGuid().ToString('N')
$server = $null
$stopped = $false

try {
    $server = [NativeProfileFactory]::Create($type, '127.0.0.1', [int]$port, [string]$token, [string]$path)
    [void]$start.Invoke($server, $null)
    $url = [string]$urlProperty.GetValue($server, $null)
    if (-not [bool]$running.GetValue($server, $null)) { throw 'Native setup server did not start.' }

    $web = New-Object System.Net.WebClient
    try {
        foreach ($attempt in 1..2) {
            $body = $web.DownloadString($url)
            if ($body -ne $profile) { throw ('Native profile GET ' + $attempt + ' returned incorrect content.') }
            if (-not [bool]$running.GetValue($server, $null)) { throw ('Native setup server stopped after GET ' + $attempt + '.') }
        }
        $head = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
        $head.Method = 'HEAD'
        $response = $head.GetResponse()
        try { if ([int]$response.StatusCode -ne 200) { throw 'Native profile HEAD did not succeed.' } }
        finally { $response.Close() }
        if (-not [bool]$running.GetValue($server, $null)) { throw 'HEAD prematurely stopped phone setup.' }

        $invalid = $url.Replace('/' + $token + '/', '/wrong-token/')
        $rejected = $false
        try { [void]$web.DownloadString($invalid) }
        catch [System.Net.WebException] {
            $response = $_.Exception.Response
            if ($response -ne $null) {
                try { $rejected = ([int]$response.StatusCode -eq 404) }
                finally { $response.Close() }
            }
        }
        if (-not $rejected) { throw 'Invalid token was not rejected with HTTP 404.' }
        if (-not [bool]$running.GetValue($server, $null)) { throw 'Invalid request terminated the setup server.' }
    }
    finally { $web.Dispose() }

    [void]$stop.Invoke($server, $null)
    $stopped = $true
    if ([bool]$running.GetValue($server, $null)) { throw 'Native setup server did not transition to stopped.' }
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
    try { $probe.Start() }
    finally { $probe.Stop() }
    Write-Host 'NATIVE PROFILE SERVER PASS: repeated GET, HEAD, rejected token, retained session and clean stop.'
}
finally {
    if ($server -ne $null -and -not $stopped) { [void]$stop.Invoke($server, $null) }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
