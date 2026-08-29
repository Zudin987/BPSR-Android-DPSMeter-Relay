param(
    [Parameter(Mandatory = $true)][string]$SingBoxExe
)

$ErrorActionPreference = 'Stop'

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

$httpPort = 11991
$ssPort = 11992
$socksPort = 11993
$token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$key = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes('0123456789abcdef'))
$profile = Join-Path $temp 'android-bpsr-relay.json'
$serverConfig = Join-Path $temp 'server.json'
$clientConfig = Join-Path $temp 'client.json'

$httpProcess = $null
$serverProcess = $null
$clientProcess = $null

try {
    [System.IO.File]::WriteAllText($profile, '{"relaySmokeTest":"ok"}', (New-Object System.Text.UTF8Encoding($false)))

    $server = [ordered]@{
        log = [ordered]@{ disabled = $true; level = 'error' }
        inbounds = @(
            [ordered]@{
                type = 'shadowsocks'
                tag = 'encrypted-in'
                listen = '127.0.0.1'
                listen_port = $ssPort
                network = 'tcp'
                method = '2022-blake3-aes-128-gcm'
                password = $key
            }
        )
        outbounds = @([ordered]@{ type = 'direct'; tag = 'direct' })
        route = [ordered]@{ final = 'direct' }
    }

    $client = [ordered]@{
        log = [ordered]@{ disabled = $true; level = 'error' }
        inbounds = @(
            [ordered]@{
                type = 'socks'
                tag = 'test-socks'
                listen = '127.0.0.1'
                listen_port = $socksPort
            }
        )
        outbounds = @(
            [ordered]@{
                type = 'shadowsocks'
                tag = 'encrypted-out'
                server = '127.0.0.1'
                server_port = $ssPort
                network = 'tcp'
                method = '2022-blake3-aes-128-gcm'
                password = $key
            }
        )
        route = [ordered]@{ final = 'encrypted-out' }
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($serverConfig, ($server | ConvertTo-Json -Depth 20), $utf8)
    [System.IO.File]::WriteAllText($clientConfig, ($client | ConvertTo-Json -Depth 20), $utf8)

    & $SingBoxExe check -c $serverConfig
    if ($LASTEXITCODE -ne 0) { throw 'Encrypted relay server smoke config failed sing-box check.' }
    & $SingBoxExe check -c $clientConfig
    if ($LASTEXITCODE -ne 0) { throw 'Encrypted relay client smoke config failed sing-box check.' }

    $httpArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $serverScript + '"' +
                ' -BindIp 127.0.0.1 -Port ' + $httpPort +
                ' -Token ' + $token +
                ' -ProfilePath "' + $profile + '" -LifetimeSeconds 60'
    $httpProcess = Start-Process powershell.exe -ArgumentList $httpArgs -WindowStyle Hidden -PassThru

    $serverProcess = Start-Process -FilePath $SingBoxExe -ArgumentList ('run -c "' + $serverConfig + '"') -WindowStyle Hidden -PassThru
    $clientProcess = Start-Process -FilePath $SingBoxExe -ArgumentList ('run -c "' + $clientConfig + '"') -WindowStyle Hidden -PassThru

    Start-Sleep -Milliseconds 800
    foreach ($process in @($httpProcess, $serverProcess, $clientProcess)) {
        $process.Refresh()
        if ($process.HasExited) { throw ('Smoke-test process exited early: PID ' + $process.Id) }
    }

    $curl = Get-Command curl.exe -ErrorAction Stop
    $url = 'http://127.0.0.1:' + $httpPort + '/' + $token + '/android-bpsr-relay.json'
    $result = & $curl.Source --fail --silent --show-error --max-time 10 --socks5-hostname ('127.0.0.1:' + $socksPort) $url
    if ($LASTEXITCODE -ne 0) { throw ('curl encrypted relay request failed with exit code ' + $LASTEXITCODE + '.') }
    $body = ($result | Out-String)
    if ($body -notmatch 'relaySmokeTest' -or $body -notmatch 'ok') {
        throw 'Encrypted relay smoke test returned unexpected content.'
    }

    $httpProcess.WaitForExit(5000) | Out-Null
    $httpProcess.Refresh()
    if (-not $httpProcess.HasExited) { throw 'HTTP endpoint did not exit after the smoke-test download.' }

    Write-Host 'ENCRYPTED RELAY SMOKE PASS: SOCKS client -> Shadowsocks -> direct HTTP target.'
}
finally {
    foreach ($process in @($clientProcess, $serverProcess, $httpProcess)) {
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
