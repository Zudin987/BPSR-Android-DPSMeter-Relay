param(
    [Parameter(Mandatory = $true)][string]$BindIp,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$ProfilePath,
    [int]$LifetimeSeconds = 300
)

$ErrorActionPreference = 'Stop'

function Write-HttpResponse {
    param(
        [Parameter(Mandatory = $true)][System.Net.Sockets.NetworkStream]$Stream,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][string]$StatusText,
        [Parameter(Mandatory = $true)][string]$ContentType,
        [Parameter(Mandatory = $true)][byte[]]$Body,
        [switch]$HeadOnly
    )

    $header = 'HTTP/1.1 ' + $StatusCode + ' ' + $StatusText + "`r`n" +
              'Content-Type: ' + $ContentType + "`r`n" +
              'Content-Length: ' + $Body.Length + "`r`n" +
              "Cache-Control: no-store, no-cache, must-revalidate`r`n" +
              "Pragma: no-cache`r`n" +
              "X-Content-Type-Options: nosniff`r`n" +
              "Connection: close`r`n`r`n"

    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if (-not $HeadOnly -and $Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }
    $Stream.Flush()
}

if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
    throw 'Profile file does not exist.'
}

$address = $null
if (-not [System.Net.IPAddress]::TryParse($BindIp, [ref]$address)) {
    throw 'BindIp is not a valid IP address.'
}
if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'Only IPv4 profile sharing is supported.'
}
if ($Token -notmatch '^[a-f0-9]{32}$') {
    throw 'Invalid share token.'
}
if ($LifetimeSeconds -lt 30 -or $LifetimeSeconds -gt 900) {
    throw 'LifetimeSeconds must be between 30 and 900.'
}

$listener = New-Object System.Net.Sockets.TcpListener($address, $Port)
$listener.Server.NoDelay = $true
$listener.Start(8)
$deadline = [DateTime]::UtcNow.AddSeconds($LifetimeSeconds)
$servedProfile = $false

try {
    while ([DateTime]::UtcNow -lt $deadline -and -not $servedProfile) {
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 100
            continue
        }

        $client = $listener.AcceptTcpClient()
        try {
            $client.NoDelay = $true
            $client.ReceiveTimeout = 3000
            $client.SendTimeout = 3000
            $stream = $client.GetStream()

            $buffer = New-Object byte[] 4096
            $requestBytes = New-Object System.IO.MemoryStream
            $requestText = ''

            while ($requestBytes.Length -lt 16384) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $requestBytes.Write($buffer, 0, $read)
                $requestText = [System.Text.Encoding]::ASCII.GetString($requestBytes.ToArray())
                if ($requestText.Contains("`r`n`r`n")) { break }
            }

            $firstLine = ($requestText -split "`r`n")[0]
            if ($firstLine -notmatch '^(GET|HEAD)\s+([^\s]+)\s+HTTP/1\.[01]$') {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Bad request')
                Write-HttpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request' -ContentType 'text/plain; charset=utf-8' -Body $body
                continue
            }

            $method = $Matches[1]
            $path = $Matches[2]
            if ($path.Contains('?')) { $path = $path.Substring(0, $path.IndexOf('?')) }
            $basePath = '/' + $Token + '/'
            $downloadRoute = $basePath + 'android-bpsr-relay.json'
            $profileUrl = 'http://' + $BindIp + ':' + $Port + $downloadRoute
            $sfaImportUrl = 'sing-box://import-remote-profile?url=' + [Uri]::EscapeDataString($profileUrl) + '#' + [Uri]::EscapeDataString('BPSR Relay')
            $headOnly = ($method -eq 'HEAD')

            if ($path -eq $basePath) {
                $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BPSR Relay Setup</title>
<style>
body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;max-width:620px;margin:48px auto;padding:0 20px;line-height:1.5;background:#111;color:#eee}
.card{background:#1c1c1c;border:1px solid #333;border-radius:14px;padding:24px}
a.button{display:inline-block;margin-top:14px;padding:12px 18px;border-radius:9px;background:#eee;color:#111;text-decoration:none;font-weight:700}
.small{color:#aaa;font-size:.92rem}
code{background:#292929;padding:2px 6px;border-radius:5px}
</style>
</head>
<body>
<div class="card">
<h2>BPSR Android DPSMeter Relay</h2>
<p>Your BPSR profile is ready.</p>
<p><a class="button" href="$sfaImportUrl">Open in SFA</a></p>
<p class="small">Recommended: tap <strong>Open in SFA</strong>, then confirm BPSR Relay.</p>
<p><a href="android-bpsr-relay.json" download>Download SFA profile</a></p>
<p class="small">File download is the backup method. This page expires after setup and is not used while gaming.</p>
</div>
</body>
</html>
"@
                $body = [System.Text.Encoding]::UTF8.GetBytes($html)
                Write-HttpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'text/html; charset=utf-8' -Body $body -HeadOnly:$headOnly
            }
            elseif ($path -eq $downloadRoute) {
                $body = [System.IO.File]::ReadAllBytes($ProfilePath)
                Write-HttpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body -HeadOnly:$headOnly
                if (-not $headOnly) { $servedProfile = $true }
            }
            else {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Not found')
                Write-HttpResponse -Stream $stream -StatusCode 404 -StatusText 'Not Found' -ContentType 'text/plain; charset=utf-8' -Body $body -HeadOnly:$headOnly
            }
        }
        catch {
            # The server is intentionally best-effort and short lived. A malformed/aborted
            # LAN request must not keep the process alive or crash the relay manager.
        }
        finally {
            if ($client) { $client.Close() }
        }
    }
}
finally {
    $listener.Stop()
}
