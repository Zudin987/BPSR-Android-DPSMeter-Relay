param(
    [Parameter(Mandatory = $true)][string]$SingBoxExe
)

$ErrorActionPreference = 'Stop'

function Get-FreeTcpPort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return [int]$listener.LocalEndpoint.Port
    }
    finally { $listener.Stop() }
}

if (-not (Test-Path -LiteralPath $SingBoxExe -PathType Leaf)) {
    throw 'sing-box executable was not found.'
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverScript = Join-Path $scriptDir 'ServeProfile.ps1'
if (-not (Test-Path -LiteralPath $serverScript -PathType Leaf)) {
    throw 'ServeProfile.ps1 was not found.'
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('bpsr-relay-smoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

$ports = New-Object System.Collections.Generic.HashSet[int]
while ($ports.Count -lt 3) { [void]$ports.Add((Get-FreeTcpPort)) }
$portList = @($ports)
$httpPort = $portList[0]
$frontPort = $portList[1]
$backPort = $portList[2]
$token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$frontUsername = 'bpsr'
$frontPassword = 'front-test-password'
$internalUsername = 'internal'
$internalPassword = 'internal-test-password'
$profile = Join-Path $temp 'android-bpsr-relay.json'
$frontConfig = Join-Path $temp 'front.json'
$backConfig = Join-Path $temp 'back.json'

$httpProcess = $null
$frontProcess = $null
$backProcess = $null

try {
    [System.IO.File]::WriteAllText($profile, '{"relaySmokeTest":"ok"}', (New-Object System.Text.UTF8Encoding($false)))

    $front = [ordered]@{
        log = [ordered]@{ disabled = $true; level = 'error' }
        inbounds = @(
            [ordered]@{
                type = 'socks'
                tag = 'phone-in'
                listen = '127.0.0.1'
                listen_port = $frontPort
                users = @(
                    [ordered]@{ username = $frontUsername; password = $frontPassword }
                )
            }
        )
        outbounds = @(
            [ordered]@{
                type = 'socks'
                tag = 'to-starsea'
                server = '127.0.0.1'
                server_port = $backPort
                version = '5'
                username = $internalUsername
                password = $internalPassword
            }
        )
        route = [ordered]@{ final = 'to-starsea' }
    }

    $back = [ordered]@{
        log = [ordered]@{ disabled = $true; level = 'error' }
        inbounds = @(
            [ordered]@{
                type = 'socks'
                tag = 'internal-in'
                listen = '127.0.0.1'
                listen_port = $backPort
                users = @(
                    [ordered]@{ username = $internalUsername; password = $internalPassword }
                )
            }
        )
        outbounds = @([ordered]@{ type = 'direct'; tag = 'direct' })
        route = [ordered]@{ final = 'direct' }
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($frontConfig, ($front | ConvertTo-Json -Depth 20), $utf8)
    [System.IO.File]::WriteAllText($backConfig, ($back | ConvertTo-Json -Depth 20), $utf8)

    & $SingBoxExe check -c $frontConfig
    if ($LASTEXITCODE -ne 0) { throw 'Front SOCKS relay smoke config failed sing-box check.' }
    & $SingBoxExe check -c $backConfig
    if ($LASTEXITCODE -ne 0) { throw 'StarSEA SOCKS relay smoke config failed sing-box check.' }

    $httpArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $serverScript + '"' +
                ' -BindIp 127.0.0.1 -Port ' + $httpPort +
                ' -Token ' + $token +
                ' -ProfilePath "' + $profile + '" -LifetimeSeconds 60'
    $httpProcess = Start-Process powershell.exe -ArgumentList $httpArgs -WindowStyle Hidden -PassThru
    $backProcess = Start-Process -FilePath $SingBoxExe -ArgumentList ('run -c "' + $backConfig + '"') -WindowStyle Hidden -PassThru
    $frontProcess = Start-Process -FilePath $SingBoxExe -ArgumentList ('run -c "' + $frontConfig + '"') -WindowStyle Hidden -PassThru

    Start-Sleep -Milliseconds 800
    foreach ($process in @($httpProcess, $backProcess, $frontProcess)) {
        $process.Refresh()
        if ($process.HasExited) { throw ('Smoke-test process exited early: PID ' + $process.Id) }
    }

    $curl = Get-Command curl.exe -ErrorAction Stop
    $url = 'http://127.0.0.1:' + $httpPort + '/' + $token + '/android-bpsr-relay.json'
    $result = & $curl.Source --fail --silent --show-error --max-time 10 --proxy-user ($frontUsername + ':' + $frontPassword) --socks5-hostname ('127.0.0.1:' + $frontPort) $url
    if ($LASTEXITCODE -ne 0) { throw ('curl v4-compatible relay request failed with exit code ' + $LASTEXITCODE + '.') }
    $body = ($result | Out-String)
    if ($body -notmatch 'relaySmokeTest' -or $body -notmatch 'ok') {
        throw 'V4-compatible relay smoke test returned unexpected content.'
    }

    $httpProcess.WaitForExit(5000) | Out-Null
    $httpProcess.Refresh()
    if (-not $httpProcess.HasExited) { throw 'HTTP endpoint did not exit after the smoke-test download.' }

    Write-Host 'V4-COMPAT RELAY SMOKE PASS: SOCKS client -> BPSRMobileFront -> localhost StarSEA -> direct HTTP target.'
}
finally {
    foreach ($process in @($frontProcess, $backProcess, $httpProcess)) {
        if ($process) {
            try {
                $process.Refresh()
                if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            }
            catch {}
        }
    }
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
