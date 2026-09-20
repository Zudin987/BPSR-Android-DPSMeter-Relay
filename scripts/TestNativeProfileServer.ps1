param(
    [Parameter(Mandatory = $true)][string]$ManagerExe
)

$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path -LiteralPath $ManagerExe).Path
$assembly = [System.Reflection.Assembly]::LoadFrom($exe)
$type = $assembly.GetType('BpsrRelayManager.ProfileServer', $true)
$binding = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::NonPublic
$ctor = @($type.GetConstructors($binding))[0]
$start = $type.GetMethod('Start', $binding)
$stop = $type.GetMethod('Stop', $binding)
$running = $type.GetProperty('Running', $binding)
$urlProperty = $type.GetProperty('ProfileUrl', $binding)

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

try {
    $arguments = [object[]]@('127.0.0.1', $port, $token, $path, 'test-profile-id', $null, $null)
    $server = $ctor.Invoke($arguments)
    [void]$start.Invoke($server, $null)
    $url = [string]$urlProperty.GetValue($server, $null)
    if (-not [bool]$running.GetValue($server, $null)) { throw 'Native setup server did not start.' }

    # A browser may fetch the profile and SFA may fetch it again. Both must work.
    $web = New-Object System.Net.WebClient
    try {
        $first = $web.DownloadString($url)
        if ($first -ne $profile) { throw 'First profile download returned incorrect bytes.' }
        if (-not [bool]$running.GetValue($server, $null)) { throw 'First download prematurely stopped the server.' }
        $second = $web.DownloadString($url)
        if ($second -ne $profile) { throw 'Second SFA profile download failed or changed the payload.' }
        if (-not [bool]$running.GetValue($server, $null)) { throw 'Second download prematurely stopped the server.' }

        $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
        $request.Method = 'HEAD'
        using namespace System.Net
    }
    finally { $web.Dispose() }
}
finally {
    if ($server -ne $null) { [void]$stop.Invoke($server, $null) }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
