param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ManagerVersion = '1.0.1'
$TestedSingBoxVersion = 'v1.13.19'
$FrontPort = 10808
$InternalPortStart = 18080
$InternalPortEnd = 18180
$FirewallRuleName = 'BPSR Android DPSMeter Relay'
$ShareLifetimeSeconds = 300
$MaxLogBytes = 2097152

$Root = Split-Path -Parent $PSScriptRoot
$Runtime = Join-Path $Root '.runtime'
$OutputDir = Join-Path $Root 'output'
$ConfigDir = Join-Path $Runtime 'config'
$RollbackDir = Join-Path $Runtime 'rollback'
$PidFile = Join-Path $Runtime 'pids.json'
$CredentialsFile = Join-Path $Runtime 'relay-credentials.json'
$VersionFile = Join-Path $Runtime 'sing-box-version.txt'
$RuntimeHashFile = Join-Path $Runtime 'sing-box-sha256.txt'
$SingBoxExe = Join-Path $Runtime 'sing-box.exe'
$FrontExe = Join-Path $Runtime 'BPSRMobileFront.exe'
$StarExe = Join-Path $Runtime 'StarSEA.exe'
$FrontConfig = Join-Path $ConfigDir 'pc-relay-front.json'
$StarConfig = Join-Path $ConfigDir 'pc-relay-back.json'
$AndroidConfig = Join-Path $OutputDir 'android-bpsr-relay.json'
$ProfileMeta = Join-Path $OutputDir 'profile-meta.json'
$FirewallScript = Join-Path $Runtime 'allow-firewall.ps1'
$ServerScript = Join-Path $PSScriptRoot 'ServeProfile.ps1'
$LogFile = Join-Path $Runtime 'manager.log'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:txtLog = $null
$script:lblRelayState = $null
$script:lblProfileState = $null
$script:lblRuntimeState = $null
$script:cmbIp = $null
$script:shareProcess = $null
$script:shareUrl = ''
$script:trackedStarPid = 0
$script:trackedStarStartUtc = ''
$script:trackedFrontPid = 0
$script:trackedFrontStartUtc = ''
$script:trackedRelayIdentityLoaded = $false

function Ensure-Directories {
    foreach ($dir in @($Runtime, $OutputDir, $ConfigDir, $RollbackDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Write-JsonFile {
    param([string]$Path, $Value, [int]$Depth = 20)
    Write-Utf8NoBom -Path $Path -Text ($Value | ConvertTo-Json -Depth $Depth)
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Rotate-LogIfNeeded {
    Ensure-Directories
    try {
        if (-not (Test-Path -LiteralPath $LogFile -PathType Leaf)) { return }
        $info = Get-Item -LiteralPath $LogFile -ErrorAction Stop
        if ($info.Length -lt $MaxLogBytes) { return }
        $backup = $LogFile + '.1'
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $LogFile -Destination $backup -Force
    }
    catch {}
}

function Add-Log {
    param([string]$Message)
    Ensure-Directories
    Rotate-LogIfNeeded
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Message
    try { [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, $Utf8NoBom) } catch {}
    if ($script:txtLog) {
        $script:txtLog.AppendText($line + [Environment]::NewLine)
        $script:txtLog.SelectionStart = $script:txtLog.TextLength
        $script:txtLog.ScrollToCaret()
    }
}

function Show-FriendlyError {
    param([string]$Title, [System.Exception]$Exception)
    Add-Log ('ERROR: ' + $Exception.Message)
    if ($SelfTest) { throw $Exception }
    [System.Windows.Forms.MessageBox]::Show(
        $Exception.Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Quote-Argument {
    param([string]$Value)
    return '"' + $Value + '"'
}

function New-RandomBytes {
    param([int]$Length)
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return $bytes
}

function New-RandomBase64 {
    param([int]$Length)
    return [Convert]::ToBase64String((New-RandomBytes -Length $Length))
}

function New-ShareToken {
    return ([BitConverter]::ToString((New-RandomBytes -Length 16))).Replace('-', '').ToLowerInvariant()
}

function Get-SingBoxArchitecture {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($arch) {
        '^AMD64$' { return 'amd64' }
        '^ARM64$' { return 'arm64' }
        default { throw ('Unsupported Windows architecture: ' + $arch + '. Only x64 and ARM64 are supported.') }
    }
}

function Get-LanIPv4Candidates {
    $items = @()
    try {
        $configs = @(Get-NetIPConfiguration -ErrorAction Stop)
        foreach ($cfg in $configs) {
            foreach ($ipv4 in @($cfg.IPv4Address)) {
                if (-not $ipv4 -or [string]::IsNullOrWhiteSpace([string]$ipv4.IPAddress)) { continue }
                $ip = [string]$ipv4.IPAddress
                if ($ip -eq '127.0.0.1' -or $ip -like '169.254.*') { continue }

                $alias = [string]$cfg.InterfaceAlias
                $score = 0
                if ($cfg.IPv4DefaultGateway) { $score += 100 }
                if ($alias -match 'Wi-?Fi|Ethernet') { $score += 30 }
                if ($ip -match '^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.') { $score += 20 }
                if ($alias -match 'vEthernet|Virtual|VMware|VirtualBox|WSL|Tailscale|WireGuard|Loopback') { $score -= 100 }

                $items += [PSCustomObject]@{
                    IP = $ip
                    Interface = $alias
                    InterfaceIndex = [int]$cfg.InterfaceIndex
                    HasGateway = [bool]$cfg.IPv4DefaultGateway
                    Score = $score
                }
            }
        }
    }
    catch {
        Add-Log 'Could not enumerate adapters automatically. You can type the PC LAN IPv4 manually.'
    }

    return @($items | Sort-Object Score -Descending)
}

function Test-IPv4Address {
    param([string]$Address)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-LocalIpAssigned {
    param([string]$Address)
    if (-not (Test-IPv4Address $Address)) { return $false }
    return @((Get-LanIPv4Candidates) | Where-Object { $_.IP -eq $Address }).Count -gt 0
}

function Get-SelectedIp {
    if (-not $script:cmbIp) { throw 'No IP selector is available.' }
    $value = ([string]$script:cmbIp.Text).Trim()
    if (-not (Test-IPv4Address $value)) {
        throw 'Choose or type a valid PC LAN IPv4 address, for example 192.168.1.20.'
    }
    if ($value -eq '127.0.0.1' -or $value -like '169.254.*') {
        throw 'Choose the PC Wi-Fi/Ethernet LAN IPv4 that the phone can reach.'
    }
    if (-not (Test-LocalIpAssigned $value)) {
        throw ('The selected address ' + $value + ' is not currently assigned to this PC.')
    }
    return $value
}

function Get-InterfaceForIp {
    param([string]$Address)
    return @((Get-LanIPv4Candidates) | Where-Object { $_.IP -eq $Address } | Select-Object -First 1)[0]
}

function Get-NetworkCategoryForIp {
    param([string]$Address)
    try {
        $item = Get-InterfaceForIp -Address $Address
        if (-not $item) { return 'Unknown' }
        $profile = Get-NetConnectionProfile -InterfaceIndex $item.InterfaceIndex -ErrorAction Stop
        return [string]$profile.NetworkCategory
    }
    catch { return 'Unknown' }
}

function Get-InstalledVersion {
    if (-not (Test-Path -LiteralPath $VersionFile)) { return '' }
    return (Get-Content -LiteralPath $VersionFile -Raw).Trim()
}

function Test-RuntimeIntegrity {
    if (-not (Test-Path -LiteralPath $SingBoxExe -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $RuntimeHashFile -PathType Leaf)) { return $false }
    try {
        $expected = (Get-Content -LiteralPath $RuntimeHashFile -Raw).Trim().ToLowerInvariant()
        if ($expected -notmatch '^[a-f0-9]{64}$') { return $false }
        $actual = (Get-FileHash -LiteralPath $SingBoxExe -Algorithm SHA256).Hash.ToLowerInvariant()
        return $actual -eq $expected
    }
    catch { return $false }
}

function Save-RollbackRuntime {
    if (-not (Test-Path -LiteralPath $SingBoxExe -PathType Leaf)) { return }
    $version = Get-InstalledVersion
    if ([string]::IsNullOrWhiteSpace($version)) { return }
    if (-not (Test-RuntimeIntegrity)) {
        Add-Log ('Not saving ' + $version + ' as rollback because its stored integrity check failed.')
        return
    }

    Copy-Item -LiteralPath $SingBoxExe -Destination (Join-Path $RollbackDir 'sing-box.exe') -Force
    Copy-Item -LiteralPath $RuntimeHashFile -Destination (Join-Path $RollbackDir 'sha256.txt') -Force
    Write-Utf8NoBom -Path (Join-Path $RollbackDir 'version.txt') -Text $version
    Add-Log ('Saved previous verified sing-box runtime ' + $version + ' for rollback.')
}

function Get-PinnedSingBoxAsset {
    param([string]$Version, [string]$Architecture)

    if ($Version -ne 'v1.13.19') {
        throw ('No pinned download metadata is available for sing-box ' + $Version + '.')
    }

    switch ($Architecture) {
        'amd64' {
            $name = 'sing-box-1.13.19-windows-amd64.zip'
            $sha256 = 'e011a4def2f5e2b143ed54adb2b1a20a6be407806ab4442f3667f1dd817a2c8d'
        }
        'arm64' {
            $name = 'sing-box-1.13.19-windows-arm64.zip'
            $sha256 = 'dbb6c4803f94a997fcc4a1cce313eff65a901abc197731b55109ea4fbd412c88'
        }
        default {
            throw ('No pinned download metadata is available for Windows/' + $Architecture + '.')
        }
    }

    return [PSCustomObject]@{
        Name = $name
        Sha256 = $sha256
        Url = 'https://github.com/SagerNet/sing-box/releases/download/v1.13.19/' + $name
    }
}

function Install-SingBoxVersion {
    param([string]$Version)

    Ensure-Directories
    $arch = Get-SingBoxArchitecture
    Add-Log ('Downloading tested sing-box ' + $Version + ' for Windows/' + $arch + '...')

    $asset = Get-PinnedSingBoxAsset -Version $Version -Architecture $arch
    $assetName = [string]$asset.Name
    $expectedZipHash = ([string]$asset.Sha256).ToLowerInvariant()
    if ($expectedZipHash -notmatch '^[a-f0-9]{64}$') {
        throw 'Pinned sing-box SHA256 metadata is invalid.'
    }

    $temp = Join-Path $Runtime 'download-temp'
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    try {
        $zipPath = Join-Path $temp $assetName
        Invoke-WebRequest -Uri ([string]$asset.Url) -OutFile $zipPath -UseBasicParsing -Headers @{ 'User-Agent' = 'BPSR-Android-DPSMeter-Relay' }
        $actualZipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualZipHash -ne $expectedZipHash) {
            throw 'SHA256 verification failed for the official sing-box archive.'
        }
        Add-Log 'Pinned official sing-box archive SHA256 verification passed.'

        $extract = Join-Path $temp 'extracted'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force
        $found = Get-ChildItem -LiteralPath $extract -Filter 'sing-box.exe' -File -Recurse | Select-Object -First 1
        if (-not $found) { throw 'The official archive did not contain sing-box.exe.' }

        $currentVersion = Get-InstalledVersion
        if ((Test-Path -LiteralPath $SingBoxExe) -and $currentVersion -ne $Version) {
            Save-RollbackRuntime
        }

        $newExeHash = (Get-FileHash -LiteralPath $found.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        Copy-Item -LiteralPath $found.FullName -Destination $SingBoxExe -Force
        Write-Utf8NoBom -Path $VersionFile -Text $Version
        Write-Utf8NoBom -Path $RuntimeHashFile -Text $newExeHash
        Add-Log ('Installed tested sing-box ' + $Version + '.')
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Ensure-TestedSingBox {
    $version = Get-InstalledVersion
    if ($version -eq $TestedSingBoxVersion -and (Test-RuntimeIntegrity)) {
        Add-Log ('Tested sing-box ' + $version + ' is already installed and verified.')
        return
    }
    Install-SingBoxVersion -Version $TestedSingBoxVersion
}


function Get-OrCreateCredentials {
    Ensure-Directories
    if (Test-Path -LiteralPath $CredentialsFile) {
        try {
            $existing = Read-JsonFile -Path $CredentialsFile
            if ($existing -and
                [string]$existing.mode -eq 'v4-compatible-socks5' -and
                [string]$existing.frontUsername -eq 'bpsr' -and
                [string]$existing.frontPassword -match '^[a-f0-9]{32}$' -and
                [string]$existing.internalUsername -eq 'internal' -and
                [string]$existing.internalPassword -match '^[a-f0-9]{32}$') {
                return $existing
            }
            Add-Log 'Existing relay credentials use another transport; generating fresh v4-compatible SOCKS5 credentials.'
        }
        catch {
            Add-Log 'Existing relay credentials were unreadable; generating fresh v4-compatible SOCKS5 credentials.'
        }
    }

    $credentials = [ordered]@{
        mode = 'v4-compatible-socks5'
        frontUsername = 'bpsr'
        frontPassword = [guid]::NewGuid().ToString('N')
        internalUsername = 'internal'
        internalPassword = [guid]::NewGuid().ToString('N')
        createdUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonFile -Path $CredentialsFile -Value $credentials
    Add-Log 'Generated persistent v4-compatible SOCKS5 credentials.'
    return (Read-JsonFile -Path $CredentialsFile)
}

function Get-FreeInternalPort {
    foreach ($candidatePort in $InternalPortStart..$InternalPortEnd) {
        if ((Get-ListeningConnections -Port $candidatePort).Count -eq 0 -and
            (Get-ListeningUdpEndpoints -Port $candidatePort).Count -eq 0) {
            return [int]$candidatePort
        }
    }
    throw ('Could not find a free TCP+UDP localhost bridge port between ' + $InternalPortStart + ' and ' + $InternalPortEnd + '.')
}

function Write-RelayConfigs {
    param([string]$PcIp, $Credentials)

    Ensure-Directories
    $internalPort = Get-FreeInternalPort

    # v1.0.0 restores the transport shape from the user's original Clean v4 pack:
    # Android -> BPSRMobileFront -> localhost -> StarSEA -> game server.
    $front = [ordered]@{
        log = [ordered]@{ disabled = $true; level = 'error' }
        inbounds = @(
            [ordered]@{
                type = 'socks'
                tag = 'phone-in'
                listen = $PcIp
                listen_port = $FrontPort
                users = @(
                    [ordered]@{
                        username = [string]$Credentials.frontUsername
                        password = [string]$Credentials.frontPassword
                    }
                )
            }
        )
        outbounds = @(
            [ordered]@{
                type = 'socks'
                tag = 'to-starsea'
                server = '127.0.0.1'
                server_port = $internalPort
                version = '5'
                username = [string]$Credentials.internalUsername
                password = [string]$Credentials.internalPassword
            }
        )
        route = [ordered]@{
            final = 'to-starsea'
        }
    }

    $star = [ordered]@{
        log = [ordered]@{ disabled = $true; level = 'error' }
        inbounds = @(
            [ordered]@{
                type = 'socks'
                tag = 'internal-in'
                listen = '127.0.0.1'
                listen_port = $internalPort
                users = @(
                    [ordered]@{
                        username = [string]$Credentials.internalUsername
                        password = [string]$Credentials.internalPassword
                    }
                )
            }
        )
        outbounds = @(
            [ordered]@{ type = 'direct'; tag = 'direct' }
        )
        route = [ordered]@{
            auto_detect_interface = $true
            final = 'direct'
        }
    }

    $android = [ordered]@{
        log = [ordered]@{ disabled = $true; level = 'error' }
        dns = [ordered]@{
            servers = @([ordered]@{ type = 'local'; tag = 'local' })
            strategy = 'ipv4_only'
            final = 'local'
        }
        inbounds = @(
            [ordered]@{
                type = 'tun'
                tag = 'tun-in'
                address = @('172.19.0.1/30')
                auto_route = $true
                route_exclude_address = @($PcIp + '/32')
                stack = 'system'
            }
        )
        outbounds = @(
            [ordered]@{
                type = 'socks'
                tag = 'bpsr-pc'
                server = $PcIp
                server_port = $FrontPort
                version = '5'
                username = [string]$Credentials.frontUsername
                password = [string]$Credentials.frontPassword
            }
        )
        route = [ordered]@{
            rules = @(
                [ordered]@{
                    port = 53
                    action = 'hijack-dns'
                }
            )
            final = 'bpsr-pc'
        }
    }

    Write-JsonFile -Path $FrontConfig -Value $front
    Write-JsonFile -Path $StarConfig -Value $star
    Write-JsonFile -Path $AndroidConfig -Value $android
    Write-JsonFile -Path $ProfileMeta -Value ([ordered]@{
        managerVersion = $ManagerVersion
        pcIp = $PcIp
        relayPort = $FrontPort
        internalPort = $internalPort
        ingress = 'v4-compatible-socks5'
        testedSingBoxVersion = $TestedSingBoxVersion
        generatedUtc = [DateTime]::UtcNow.ToString('o')
    })

    $importText = @"
BPSR Android DPSMeter Relay

IMPORTANT FOR v1.0.1:
If upgrading from an older test build, remove its old BPSR Relay profile and import this newly generated profile.
v1.0.1 keeps the field-tested Clean v4 routing shape unchanged.

PC LAN IPv4 in this profile: $PcIp
Phone relay port: $FrontPort

SFA:
- Use per-app mode / Proxy selected apps.
- Select BPSR only.
- Start SFA before opening BPSR.

DPS meter:
- Universal capture target: StarSEA
- Do NOT target BPSRMobileFront.
- If your meter asks for a physical adapter, select the PC Wi-Fi/Ethernet adapter.
- ZDPS example: Game Capture Preference = Custom; Custom BPSR Executable Name: StarSEA

Transport:
- Phone -> PC uses authenticated SOCKS5 on your trusted Private LAN.
- BPSRMobileFront forwards only to localhost StarSEA.
- StarSEA is the only process that connects onward to the game server.
- Do not port-forward relay port $FrontPort.
"@
    Write-Utf8NoBom -Path (Join-Path $OutputDir 'IMPORT-THIS-PROFILE.txt') -Text $importText
    Add-Log ('Generated v4-compatible Android SFA profile for PC ' + $PcIp + '. Re-import is required only when the profile/IP changes or when upgrading from an incompatible test profile.')
}

function Get-ProfilePcIp {
    try {
        $profile = Read-JsonFile -Path $AndroidConfig
        if (-not $profile) { return '' }
        $outbound = @($profile.outbounds | Where-Object { $_.tag -eq 'bpsr-pc' } | Select-Object -First 1)[0]
        if (-not $outbound) { return '' }
        if ([string]$outbound.type -ne 'socks' -or [int]$outbound.server_port -ne $FrontPort) { return '' }
        if ([string]$profile.route.final -ne 'bpsr-pc') { return '' }
        return [string]$outbound.server
    }
    catch { return '' }
}


function Assert-Topology {
    param([string]$PcIp)

    $front = Read-JsonFile -Path $FrontConfig
    $star = Read-JsonFile -Path $StarConfig
    $android = Read-JsonFile -Path $AndroidConfig
    if (-not $front -or -not $star -or -not $android) {
        throw 'Generated relay configuration files are missing or unreadable.'
    }

    $frontIn = @($front.inbounds)
    $frontOut = @($front.outbounds)
    if ($frontIn.Count -ne 1 -or [string]$frontIn[0].type -ne 'socks') {
        throw 'Topology check failed: BPSRMobileFront must have exactly one SOCKS5 phone-facing inbound.'
    }
    if ([string]$frontIn[0].listen -ne $PcIp -or [int]$frontIn[0].listen_port -ne $FrontPort) {
        throw 'Topology check failed: BPSRMobileFront is not bound only to the selected LAN IP/relay port.'
    }
    if ($frontOut.Count -ne 1 -or [string]$frontOut[0].type -ne 'socks' -or [string]$frontOut[0].server -ne '127.0.0.1') {
        throw 'Topology check failed: BPSRMobileFront must forward only to localhost StarSEA.'
    }
    if ([string]$front.route.final -ne 'to-starsea') {
        throw 'Topology check failed: BPSRMobileFront final route is not the localhost StarSEA bridge.'
    }

    $internalPort = [int]$frontOut[0].server_port
    if ($internalPort -lt $InternalPortStart -or $internalPort -gt $InternalPortEnd) {
        throw 'Topology check failed: localhost bridge port is outside the expected private range.'
    }

    $starIn = @($star.inbounds)
    $starOut = @($star.outbounds)
    if ($starIn.Count -ne 1 -or [string]$starIn[0].type -ne 'socks') {
        throw 'Topology check failed: StarSEA must have exactly one localhost SOCKS5 inbound.'
    }
    if ([string]$starIn[0].listen -ne '127.0.0.1' -or [int]$starIn[0].listen_port -ne $internalPort) {
        throw 'Topology check failed: StarSEA localhost bridge does not match BPSRMobileFront.'
    }
    if ($starOut.Count -ne 1 -or [string]$starOut[0].type -ne 'direct' -or [string]$star.route.final -ne 'direct') {
        throw 'Topology check failed: StarSEA must have exactly one direct Internet outbound path.'
    }

    $frontUser = @($frontIn[0].users | Select-Object -First 1)[0]
    $androidTun = @($android.inbounds | Where-Object { $_.tag -eq 'tun-in' } | Select-Object -First 1)[0]
    $androidProxy = @($android.outbounds | Where-Object { $_.tag -eq 'bpsr-pc' } | Select-Object -First 1)[0]
    if (-not $androidTun -or -not $androidProxy) {
        throw 'Topology check failed: Android TUN/proxy entries are missing.'
    }
    if ([string]$androidProxy.type -ne 'socks' -or
        [string]$androidProxy.server -ne $PcIp -or
        [int]$androidProxy.server_port -ne $FrontPort -or
        [string]$androidProxy.version -ne '5') {
        throw 'Topology check failed: Android is not using the v4-compatible PC SOCKS5 relay.'
    }
    if ([string]$androidProxy.username -ne [string]$frontUser.username -or
        [string]$androidProxy.password -ne [string]$frontUser.password) {
        throw 'Topology check failed: Android and BPSRMobileFront credentials do not match.'
    }

    $internalUser = @($starIn[0].users | Select-Object -First 1)[0]
    if ([string]$frontOut[0].username -ne [string]$internalUser.username -or
        [string]$frontOut[0].password -ne [string]$internalUser.password) {
        throw 'Topology check failed: BPSRMobileFront and StarSEA localhost credentials do not match.'
    }

    if (@($android.route.rules | Where-Object { $_.action -eq 'sniff' }).Count -ne 0) {
        throw 'Topology check failed: protocol sniffing must remain disabled on the latency path.'
    }
    if ($androidTun.PSObject.Properties['strict_route']) {
        throw 'Topology check failed: strict_route must stay absent because SFA Android does not implement it.'
    }
    if (-not (@($androidTun.route_exclude_address) -contains ($PcIp + '/32'))) {
        throw 'Topology check failed: the PC relay IP must be excluded from the Android TUN route to prevent a VPN loop.'
    }
    if ([string]$android.route.final -ne 'bpsr-pc') {
        throw 'Topology check failed: selected SFA app traffic must use the PC relay, matching the original Clean v4 profile.'
    }
    if (@($android.outbounds).Count -ne 1) {
        throw 'Topology check failed: Android must have one explicit SOCKS5 outbound so there is no second relay path.'
    }

    $allText = (Get-Content -LiteralPath $FrontConfig -Raw) + "`n" +
               (Get-Content -LiteralPath $StarConfig -Raw) + "`n" +
               (Get-Content -LiteralPath $AndroidConfig -Raw)
    if ($allText -match '"type"\s*:\s*"shadowsocks"|BPSRRelayIngress|"multiplex"') {
        throw 'Topology check failed: an RC.14 encrypted/legacy/multiplex path unexpectedly remains.'
    }
}

function Test-SingBoxConfig {
    param([string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $SingBoxExe)) { throw 'sing-box runtime is missing.' }
    $output = & $SingBoxExe check -c $ConfigPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('sing-box rejected ' + [System.IO.Path]::GetFileName($ConfigPath) + ': ' + (($output | Out-String).Trim()))
    }
}

function Validate-GeneratedConfigs {
    param([string]$PcIp)
    Assert-Topology -PcIp $PcIp
    Test-SingBoxConfig -ConfigPath $FrontConfig
    Test-SingBoxConfig -ConfigPath $StarConfig
    Test-SingBoxConfig -ConfigPath $AndroidConfig
    Add-Log 'Config validation passed: original Clean v4-compatible two-stage SOCKS5 topology, no sniffing, one StarSEA game-server path.'
}

function Ensure-InternalBridgePortAvailable {
    param([string]$PcIp)

    $front = Read-JsonFile -Path $FrontConfig
    $star = Read-JsonFile -Path $StarConfig
    if (-not $front -or -not $star) { throw 'PC relay configs are missing. Click Prepare Relay first.' }

    $frontOut = @($front.outbounds | Select-Object -First 1)[0]
    $starIn = @($star.inbounds | Select-Object -First 1)[0]
    if (-not $frontOut -or -not $starIn) { throw 'PC relay configs are incomplete. Click Prepare Relay first.' }

    $currentPort = [int]$frontOut.server_port
    if ($currentPort -eq [int]$starIn.listen_port -and
        $currentPort -ge $InternalPortStart -and $currentPort -le $InternalPortEnd -and
        (Get-ListeningConnections -Port $currentPort).Count -eq 0 -and
        (Get-ListeningUdpEndpoints -Port $currentPort).Count -eq 0) {
        return $currentPort
    }

    $newPort = Get-FreeInternalPort
    $frontOut.server_port = $newPort
    $starIn.listen_port = $newPort
    Write-JsonFile -Path $FrontConfig -Value $front
    Write-JsonFile -Path $StarConfig -Value $star

    try {
        $meta = Read-JsonFile -Path $ProfileMeta
        if ($meta) {
            $meta.internalPort = $newPort
            Write-JsonFile -Path $ProfileMeta -Value $meta
        }
    }
    catch {}

    Assert-Topology -PcIp $PcIp
    Test-SingBoxConfig -ConfigPath $FrontConfig
    Test-SingBoxConfig -ConfigPath $StarConfig
    Add-Log ('Localhost bridge port was busy/stale; refreshed it to ' + $newPort + ' without changing the Android profile.')
    return $newPort
}

function Get-RecordedPids {
    try { return Read-JsonFile -Path $PidFile } catch { return $null }
}


function Load-TrackedRelayIdentity {
    if ($script:trackedRelayIdentityLoaded) { return }
    $script:trackedRelayIdentityLoaded = $true
    $script:trackedStarPid = 0
    $script:trackedStarStartUtc = ''
    $script:trackedFrontPid = 0
    $script:trackedFrontStartUtc = ''

    $state = Get-RecordedPids
    if (-not $state -or -not $state.starPid -or -not $state.starStartUtc -or -not $state.frontPid -or -not $state.frontStartUtc) {
        return
    }

    $starPid = [int]$state.starPid
    $starStart = [string]$state.starStartUtc
    $frontPid = [int]$state.frontPid
    $frontStart = [string]$state.frontStartUtc

    # Full path/start-time verification happens once when this manager attaches.
    $starOk = Test-ExpectedProcess -ProcessId $starPid -ExpectedPath $StarExe -ExpectedStartUtc $starStart
    $frontOk = Test-ExpectedProcess -ProcessId $frontPid -ExpectedPath $FrontExe -ExpectedStartUtc $frontStart
    if ($starOk -and $frontOk) {
        $script:trackedStarPid = $starPid
        $script:trackedStarStartUtc = $starStart
        $script:trackedFrontPid = $frontPid
        $script:trackedFrontStartUtc = $frontStart
    }
}

function Set-TrackedRelayIdentity {
    param(
        [int]$StarProcessId,
        [string]$StarStartUtc,
        [int]$FrontProcessId,
        [string]$FrontStartUtc
    )
    $script:trackedStarPid = $StarProcessId
    $script:trackedStarStartUtc = $StarStartUtc
    $script:trackedFrontPid = $FrontProcessId
    $script:trackedFrontStartUtc = $FrontStartUtc
    $script:trackedRelayIdentityLoaded = $true
}

function Clear-TrackedRelayIdentity {
    $script:trackedStarPid = 0
    $script:trackedStarStartUtc = ''
    $script:trackedFrontPid = 0
    $script:trackedFrontStartUtc = ''
    $script:trackedRelayIdentityLoaded = $true
}

function Get-ProcessPath {
    param([int]$ProcessId)
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$process.Path)) { return [string]$process.Path }
        }
        catch {}
        $cim = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $ProcessId) -ErrorAction Stop
        return [string]$cim.ExecutablePath
    }
    catch { return '' }
}

function Test-ExpectedProcess {
    param([int]$ProcessId, [string]$ExpectedPath, [string]$ExpectedStartUtc = '')
    if ($ProcessId -le 0) { return $false }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $actualPath = Get-ProcessPath -ProcessId $ProcessId
        if ([string]::IsNullOrWhiteSpace($actualPath)) { return $false }
        $actualFull = [System.IO.Path]::GetFullPath($actualPath)
        $expectedFull = [System.IO.Path]::GetFullPath($ExpectedPath)
        if (-not $actualFull.Equals($expectedFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }

        if (-not [string]::IsNullOrWhiteSpace($ExpectedStartUtc)) {
            $expectedStart = [DateTime]::Parse($ExpectedStartUtc).ToUniversalTime()
            $actualStart = $process.StartTime.ToUniversalTime()
            if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-ExpectedRelayPath {
    param([string]$ProcessName)
    switch ($ProcessName) {
        'StarSEA' { return $StarExe }
        'BPSRMobileFront' { return $FrontExe }
        'BPSRRelayIngress' { return (Join-Path $Runtime 'BPSRRelayIngress.exe') }
        default { return '' }
    }
}
function Stop-ProfileShare {
    if ($script:shareProcess) {
        try {
            $script:shareProcess.Refresh()
            if (-not $script:shareProcess.HasExited) {
                Stop-Process -Id $script:shareProcess.Id -Force -ErrorAction SilentlyContinue
                Add-Log 'Stopped temporary phone profile sharing.'
            }
        }
        catch {}
    }
    $script:shareProcess = $null
    $script:shareUrl = ''
}


function Stop-Relay {
    $state = Get-RecordedPids
    if (-not $state) {
        # If pids.json becomes corrupt while this manager is open, keep using
        # the already-validated in-memory PID/start-time identity. The normal
        # exact executable-path checks below still gate every process kill.
        if ($script:trackedStarPid -gt 0 -or $script:trackedFrontPid -gt 0) {
            $state = [PSCustomObject]@{
                starPid = $script:trackedStarPid
                starStartUtc = $script:trackedStarStartUtc
                frontPid = $script:trackedFrontPid
                frontStartUtc = $script:trackedFrontStartUtc
                ingressPid = 0
            }
            Add-Log 'PID state file missing/unreadable; using in-memory relay identity for safe stop.'
        }
        else {
            Clear-TrackedRelayIdentity
            Update-Status
            return
        }
    }

    # Stop the phone-facing process first so no new traffic can enter while
    # StarSEA is being shut down.
    if ($state.frontPid) {
        $frontStart = if ($state.frontStartUtc) { [string]$state.frontStartUtc } else { '' }
        if (Test-ExpectedProcess -ProcessId ([int]$state.frontPid) -ExpectedPath $FrontExe -ExpectedStartUtc $frontStart) {
            try {
                Stop-Process -Id ([int]$state.frontPid) -Force -ErrorAction Stop
                Add-Log ('Stopped BPSRMobileFront (PID ' + [int]$state.frontPid + ').')
            }
            catch { Add-Log ('Warning: could not stop BPSRMobileFront: ' + $_.Exception.Message) }
        }
    }

    if ($state.starPid) {
        $starStart = if ($state.starStartUtc) { [string]$state.starStartUtc } else { '' }
        if (Test-ExpectedProcess -ProcessId ([int]$state.starPid) -ExpectedPath $StarExe -ExpectedStartUtc $starStart) {
            try {
                Stop-Process -Id ([int]$state.starPid) -Force -ErrorAction Stop
                Add-Log ('Stopped StarSEA (PID ' + [int]$state.starPid + ').')
            }
            catch { Add-Log ('Warning: could not stop StarSEA: ' + $_.Exception.Message) }
        }
    }

    # RC.14 migration cleanup: only stop an exact tracked BPSRRelayIngress copy.
    if ($state.ingressPid) {
        $oldIngress = Join-Path $Runtime 'BPSRRelayIngress.exe'
        if (Test-ExpectedProcess -ProcessId ([int]$state.ingressPid) -ExpectedPath $oldIngress) {
            Stop-Process -Id ([int]$state.ingressPid) -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Clear-TrackedRelayIdentity
    Update-Status
}

function Get-ForeignRelayProcesses {
    $state = Get-RecordedPids
    $trackedPairHealthy = $false
    $trackedStar = 0
    $trackedFront = 0

    if ($state -and $state.starPid -and $state.starStartUtc -and $state.frontPid -and $state.frontStartUtc) {
        $trackedStar = [int]$state.starPid
        $trackedFront = [int]$state.frontPid
        $starOk = Test-ExpectedProcess -ProcessId $trackedStar -ExpectedPath $StarExe -ExpectedStartUtc ([string]$state.starStartUtc)
        $frontOk = Test-ExpectedProcess -ProcessId $trackedFront -ExpectedPath $FrontExe -ExpectedStartUtc ([string]$state.frontStartUtc)
        $trackedPairHealthy = $starOk -and $frontOk
    }

    $foreign = @()
    foreach ($name in @('StarSEA', 'BPSRMobileFront', 'BPSRRelayIngress')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            if ($trackedPairHealthy) {
                if ($name -eq 'StarSEA' -and $process.Id -eq $trackedStar) { continue }
                if ($name -eq 'BPSRMobileFront' -and $process.Id -eq $trackedFront) { continue }
            }
            $startUtc = ''
            try { $startUtc = $process.StartTime.ToUniversalTime().ToString('o') } catch {}
            $foreign += [PSCustomObject]@{
                Name = $name
                Id = [int]$process.Id
                StartUtc = $startUtc
            }
        }
    }
    return @($foreign)
}

function Assert-NoForeignRelayProcesses {
    $foreign = @(Get-ForeignRelayProcesses)
    if ($foreign.Count -gt 0) {
        $labels = @($foreign | ForEach-Object { $_.Name + ' (PID ' + $_.Id + ')' })
        throw ('Foreign/duplicate relay process detected: ' + ($labels -join ', ') + '. Close it before continuing so there is never a second relay path.')
    }
}

function Get-ListeningConnections {
    param([int]$Port)
    try { return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) }
    catch { return @() }
}

function Get-ListeningUdpEndpoints {
    param([int]$Port)
    try { return @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) }
    catch { return @() }
}

function Assert-RelayPortFree {
    $tcp = @(Get-ListeningConnections -Port $FrontPort)
    $udp = @(Get-ListeningUdpEndpoints -Port $FrontPort)
    if ($tcp.Count -gt 0 -or $udp.Count -gt 0) {
        $parts = @()
        if ($tcp.Count -gt 0) {
            $owners = @($tcp | ForEach-Object { [string]$_.OwningProcess } | Select-Object -Unique)
            $parts += ('TCP listener PID ' + ($owners -join ', '))
        }
        if ($udp.Count -gt 0) {
            $owners = @($udp | ForEach-Object { [string]$_.OwningProcess } | Select-Object -Unique)
            $parts += ('UDP endpoint PID ' + ($owners -join ', '))
        }
        throw ('Relay port ' + $FrontPort + ' is already in use (' + ($parts -join '; ') + '). Stop the conflicting program first.')
    }
}

function Wait-ForProcessListener {
    param(
        [int]$ProcessId,
        [string]$Address,
        [int]$Port,
        [string]$ProcessLabel
    )

    for ($i = 0; $i -lt 40; $i++) {
        try {
            $process = Get-Process -Id $ProcessId -ErrorAction Stop
            if ($process.HasExited) { throw ($ProcessLabel + ' exited during startup.') }
        }
        catch { throw ($ProcessLabel + ' exited during startup.') }

        $listeners = @(Get-ListeningConnections -Port $Port | Where-Object {
            [int]$_.OwningProcess -eq $ProcessId -and
            ([string]$_.LocalAddress -eq $Address -or [string]$_.LocalAddress -eq '0.0.0.0')
        })
        if ($listeners.Count -gt 0) { return }
        Start-Sleep -Milliseconds 100
    }
    throw ($ProcessLabel + ' did not begin listening on ' + $Address + ':' + $Port + ' within 4 seconds.')
}


function Test-FirewallReady {
    param([string]$PcIp)
    if ((Get-NetworkCategoryForIp -Address $PcIp) -ne 'Private') { return $false }

    $tcpReady = $false
    $udpReady = $false
    try {
        $rules = @(Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue | Where-Object {
            $_.Enabled -eq 'True' -and
            $_.Direction -eq 'Inbound' -and
            $_.Action -eq 'Allow' -and
            $_.Profile -match 'Private'
        })

        foreach ($rule in $rules) {
            $port = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
            $addr = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
            if (-not $port -or -not $addr) { continue }

            $locals = @($addr.LocalAddress)
            $remotes = @($addr.RemoteAddress)
            if ([string]$port.LocalPort -ne [string]$FrontPort -or
                -not ($locals -contains $PcIp) -or
                -not ($remotes -contains 'LocalSubnet')) {
                continue
            }

            if ([string]$port.Protocol -eq 'TCP') { $tcpReady = $true }
            if ([string]$port.Protocol -eq 'UDP') { $udpReady = $true }
        }
    }
    catch { return $false }

    return $tcpReady -and $udpReady
}

function Allow-Firewall {
    $pcIp = Get-SelectedIp
    $adapter = Get-InterfaceForIp -Address $pcIp
    if (-not $adapter) { throw 'Could not find the selected Windows network adapter.' }

    $category = Get-NetworkCategoryForIp -Address $pcIp
    if ($category -eq 'Public') {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "This Windows network is Public.`r`n`r`nThe relay only opens on a Private LAN for safety.`r`n`r`nOnly continue if this is your trusted home/private network.`r`n`r`nChange it to Private and allow your phone to connect?",
            'Trusted network required',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            Add-Log 'Firewall setup cancelled because the active network is Public.'
            Update-Status
            return
        }
    }
    elseif ($category -ne 'Private') {
        throw ('Windows network profile is ' + $category + '. The relay requires a Private network profile.')
    }

    Ensure-Directories
    $profileCommand = ''
    if ($category -eq 'Public') {
        $profileCommand = 'Set-NetConnectionProfile -InterfaceIndex ' + [int]$adapter.InterfaceIndex + ' -NetworkCategory Private' + [Environment]::NewLine
    }

    $body = @"
`$ErrorActionPreference = 'Stop'
`$display = '$FirewallRuleName'
$profileCommand
Get-NetFirewallRule -DisplayName `$display -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName `$display -Direction Inbound -Action Allow -Protocol TCP -LocalPort $FrontPort -LocalAddress '$pcIp' -RemoteAddress LocalSubnet -Profile Private -EdgeTraversalPolicy Block | Out-Null
New-NetFirewallRule -DisplayName `$display -Direction Inbound -Action Allow -Protocol UDP -LocalPort $FrontPort -LocalAddress '$pcIp' -RemoteAddress LocalSubnet -Profile Private -EdgeTraversalPolicy Block | Out-Null
"@
    Write-Utf8NoBom -Path $FirewallScript -Text $body

    Add-Log ('Requesting Administrator permission for trusted-LAN TCP+UDP relay rules on ' + $pcIp + ':' + $FrontPort + '...')
    $args = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Argument $FirewallScript)
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList $args
    if ($process.ExitCode -ne 0) { throw ('Firewall setup failed with exit code ' + $process.ExitCode + '.') }

    $newCategory = Get-NetworkCategoryForIp -Address $pcIp
    if ($newCategory -ne 'Private') {
        throw ('Windows network is still ' + $newCategory + '. Change this trusted network to Private, then try again.')
    }
    if (-not (Test-FirewallReady -PcIp $pcIp)) {
        throw 'The Private-network TCP+UDP firewall rules could not be verified after setup.'
    }

    Add-Log 'Firewall ready: active network Private; TCP+UDP; selected IP only; LocalSubnet remote only.'
    Update-Status
}

function Remove-LegacyRuntimeFiles {
    foreach ($path in @(
        (Join-Path $Runtime 'BPSRRelayIngress.exe'),
        (Join-Path $ConfigDir 'front-socks.json'),
        (Join-Path $ConfigDir 'relay-hidden.json'),
        (Join-Path $ConfigDir 'starsea-relay.json')
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Setup-Relay {
    $pcIp = Get-SelectedIp
    Stop-ProfileShare
    Stop-Relay
    Assert-NoForeignRelayProcesses

    Add-Log ('Setup / Repair started for ' + $pcIp + '.')
    Ensure-TestedSingBox
    $credentials = Get-OrCreateCredentials

    Copy-Item -LiteralPath $SingBoxExe -Destination $FrontExe -Force
    Copy-Item -LiteralPath $SingBoxExe -Destination $StarExe -Force

    $sourceHash = (Get-FileHash -LiteralPath $SingBoxExe -Algorithm SHA256).Hash
    $frontHash = (Get-FileHash -LiteralPath $FrontExe -Algorithm SHA256).Hash
    $starHash = (Get-FileHash -LiteralPath $StarExe -Algorithm SHA256).Hash
    if ($sourceHash -ne $frontHash) { throw 'BPSRMobileFront runtime copy verification failed.' }
    if ($sourceHash -ne $starHash) { throw 'StarSEA runtime copy verification failed.' }

    Remove-LegacyRuntimeFiles
    Write-RelayConfigs -PcIp $pcIp -Credentials $credentials
    Validate-GeneratedConfigs -PcIp $pcIp

    Add-Log 'Setup / Repair complete. v1.0.1 keeps the original Clean v4 two-stage SOCKS5 route.'
    Add-Log 'If upgrading from an older test build, remove its old SFA profile and import the newly generated v1.0.1 profile.'
    Add-Log 'Next: Allow Firewall -> Send to Phone -> SFA BPSR-only per-app proxy -> DPS target StarSEA -> Start Relay.'
    Update-Status
}

function Restore-PreviousRuntime {
    Stop-ProfileShare
    Stop-Relay
    Assert-NoForeignRelayProcesses

    $rollbackExe = Join-Path $RollbackDir 'sing-box.exe'
    $rollbackVersion = Join-Path $RollbackDir 'version.txt'
    $rollbackHash = Join-Path $RollbackDir 'sha256.txt'
    if (-not (Test-Path -LiteralPath $rollbackExe) -or -not (Test-Path -LiteralPath $rollbackVersion) -or -not (Test-Path -LiteralPath $rollbackHash)) {
        throw 'No previous verified runtime is available for rollback.'
    }

    $expected = (Get-Content -LiteralPath $rollbackHash -Raw).Trim().ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $rollbackExe -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -notmatch '^[a-f0-9]{64}$' -or $expected -ne $actual) { throw 'Rollback runtime integrity check failed.' }

    $tempDir = Join-Path $Runtime 'rollback-swap-temp'
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $currentWasVerified = Test-RuntimeIntegrity
    $swapSucceeded = $false

    try {
        if (Test-Path -LiteralPath $SingBoxExe) {
            Copy-Item -LiteralPath $SingBoxExe -Destination (Join-Path $tempDir 'sing-box.exe') -Force
        }
        if (Test-Path -LiteralPath $VersionFile) {
            Copy-Item -LiteralPath $VersionFile -Destination (Join-Path $tempDir 'version.txt') -Force
        }
        if (Test-Path -LiteralPath $RuntimeHashFile) {
            Copy-Item -LiteralPath $RuntimeHashFile -Destination (Join-Path $tempDir 'sha256.txt') -Force
        }

        Copy-Item -LiteralPath $rollbackExe -Destination $SingBoxExe -Force
        Copy-Item -LiteralPath $rollbackVersion -Destination $VersionFile -Force
        Copy-Item -LiteralPath $rollbackHash -Destination $RuntimeHashFile -Force
        Copy-Item -LiteralPath $SingBoxExe -Destination $FrontExe -Force
        Copy-Item -LiteralPath $SingBoxExe -Destination $StarExe -Force

        if (-not (Test-RuntimeIntegrity)) { throw 'Restored runtime failed its local integrity check.' }
        $pcIp = Get-ProfilePcIp
        if ([string]::IsNullOrWhiteSpace($pcIp)) { throw 'Profile IP is unavailable; run Setup / Repair instead.' }
        Validate-GeneratedConfigs -PcIp $pcIp
        $swapSucceeded = $true

        if ($currentWasVerified -and (Test-Path -LiteralPath (Join-Path $tempDir 'sing-box.exe')) -and
            (Test-Path -LiteralPath (Join-Path $tempDir 'version.txt')) -and
            (Test-Path -LiteralPath (Join-Path $tempDir 'sha256.txt'))) {
            Copy-Item -LiteralPath (Join-Path $tempDir 'sing-box.exe') -Destination $rollbackExe -Force
            Copy-Item -LiteralPath (Join-Path $tempDir 'version.txt') -Destination $rollbackVersion -Force
            Copy-Item -LiteralPath (Join-Path $tempDir 'sha256.txt') -Destination $rollbackHash -Force
        }
        Add-Log ('Runtime rollback successful. Active sing-box: ' + (Get-InstalledVersion) + '.')
    }
    catch {
        $failure = $_.Exception
        if (-not $swapSucceeded -and (Test-Path -LiteralPath (Join-Path $tempDir 'sing-box.exe'))) {
            try {
                Copy-Item -LiteralPath (Join-Path $tempDir 'sing-box.exe') -Destination $SingBoxExe -Force
                if (Test-Path -LiteralPath (Join-Path $tempDir 'version.txt')) {
                    Copy-Item -LiteralPath (Join-Path $tempDir 'version.txt') -Destination $VersionFile -Force
                }
                else { Remove-Item -LiteralPath $VersionFile -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath (Join-Path $tempDir 'sha256.txt')) {
                    Copy-Item -LiteralPath (Join-Path $tempDir 'sha256.txt') -Destination $RuntimeHashFile -Force
                }
                else { Remove-Item -LiteralPath $RuntimeHashFile -Force -ErrorAction SilentlyContinue }
                Copy-Item -LiteralPath $SingBoxExe -Destination $FrontExe -Force
                Copy-Item -LiteralPath $SingBoxExe -Destination $StarExe -Force
                Add-Log 'Rollback validation failed; restored the exact pre-rollback runtime files.'
            }
            catch {
                Add-Log ('CRITICAL: rollback failed and restoring the pre-rollback runtime also failed: ' + $_.Exception.Message)
            }
        }
        Add-Log ('Rollback failed: ' + $failure.Message)
        throw $failure
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        Update-Status
    }
}


function Get-RelayTrackedRunning {
    Load-TrackedRelayIdentity
    if ($script:trackedStarPid -le 0 -or
        $script:trackedFrontPid -le 0 -or
        [string]::IsNullOrWhiteSpace($script:trackedStarStartUtc) -or
        [string]::IsNullOrWhiteSpace($script:trackedFrontStartUtc)) {
        return $false
    }

    try {
        # Gameplay hot check: two PIDs + immutable process start times only.
        # Paths were fully validated once when the manager attached/launched them.
        $star = Get-Process -Id $script:trackedStarPid -ErrorAction Stop
        $front = Get-Process -Id $script:trackedFrontPid -ErrorAction Stop

        $starExpected = [DateTime]::Parse($script:trackedStarStartUtc).ToUniversalTime()
        $frontExpected = [DateTime]::Parse($script:trackedFrontStartUtc).ToUniversalTime()
        $starActual = $star.StartTime.ToUniversalTime()
        $frontActual = $front.StartTime.ToUniversalTime()

        $starMatches = [Math]::Abs(($starActual - $starExpected).TotalSeconds) -le 2
        $frontMatches = [Math]::Abs(($frontActual - $frontExpected).TotalSeconds) -le 2
        return $starMatches -and $frontMatches
    }
    catch { return $false }
}

function Start-ProfileShare {
    $pcIp = Get-SelectedIp
    if (-not (Test-Path -LiteralPath $AndroidConfig)) { throw 'Run Setup / Repair first.' }
    if ((Get-ProfilePcIp) -ne $pcIp) { throw 'The Android profile is stale for this IP. Run Setup / Repair first.' }
    if (-not (Test-Path -LiteralPath $ServerScript)) { throw 'ServeProfile.ps1 is missing.' }
    if (Get-RelayTrackedRunning) { throw 'Stop the relay before sharing the profile. The share page intentionally uses the same port and never runs during gameplay.' }
    if (-not (Test-FirewallReady -PcIp $pcIp)) {
        throw 'Phone setup needs the trusted Private-LAN firewall rule first. Click Allow Firewall, then try again.'
    }

    Stop-ProfileShare
    Assert-NoForeignRelayProcesses
    Assert-RelayPortFree
    $token = New-ShareToken
    $args = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Argument $ServerScript) +
            ' -BindIp ' + (Quote-Argument $pcIp) +
            ' -Port ' + $FrontPort +
            ' -Token ' + (Quote-Argument $token) +
            ' -ProfilePath ' + (Quote-Argument $AndroidConfig) +
            ' -LifetimeSeconds ' + $ShareLifetimeSeconds

    $script:shareProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 250
    $script:shareProcess.Refresh()
    if ($script:shareProcess.HasExited) {
        $script:shareProcess = $null
        throw 'Temporary phone sharing server could not start. Check that the relay port is free and the firewall rule exists.'
    }

    $script:shareUrl = 'http://' + $pcIp + ':' + $FrontPort + '/' + $token + '/'
    try {
        [System.Windows.Forms.Clipboard]::SetText((Get-SfaImportUrl))
        Add-Log 'SFA import link copied to clipboard.'
    }
    catch {
        Add-Log ('WARNING: phone setup started, but Windows clipboard was busy: ' + $_.Exception.Message)
    }
    Add-Log ('Temporary SFA setup started for up to ' + $ShareLifetimeSeconds + ' seconds.')
    Add-Log 'The share server stops after SFA downloads the profile and is never part of gameplay traffic.'
    Update-Status
}

function Get-ProfileDownloadUrl {
    if ([string]::IsNullOrWhiteSpace($script:shareUrl)) { throw 'Start Phone Setup first.' }
    return $script:shareUrl + 'android-bpsr-relay.json'
}

function Get-SfaImportUrl {
    $profileUrl = Get-ProfileDownloadUrl
    return 'sing-box://import-remote-profile?url=' + [Uri]::EscapeDataString($profileUrl) + '#' + [Uri]::EscapeDataString('BPSR Relay')
}

function Copy-ShareUrl {
    if ([string]::IsNullOrWhiteSpace($script:shareUrl) -or -not $script:shareProcess) { throw 'Start Phone Setup first.' }
    $script:shareProcess.Refresh()
    if ($script:shareProcess.HasExited) { throw 'Phone setup expired. Start Phone Setup again.' }
    [System.Windows.Forms.Clipboard]::SetText((Get-SfaImportUrl))
    Add-Log 'SFA import link copied.'
}

function Show-ShareQr {
    if ([string]::IsNullOrWhiteSpace($script:shareUrl) -or -not $script:shareProcess) { throw 'Start Phone Setup first.' }
    $script:shareProcess.Refresh()
    if ($script:shareProcess.HasExited) { throw 'Phone setup expired. Start Phone Setup again.' }
    $sfaImportUrl = Get-SfaImportUrl
    $qrUrl = 'https://quickchart.io/qr?size=420&margin=2&text=' + [Uri]::EscapeDataString($sfaImportUrl)
    Start-Process $qrUrl | Out-Null
    Add-Log 'Opened SFA-ready QR. On Android: SFA > + > Scan QR Code.'
}

function Open-ProfileFolder {
    Ensure-Directories
    Start-Process -FilePath 'explorer.exe' -ArgumentList (Quote-Argument $OutputDir) | Out-Null
}

function Copy-ZdpsSettings {
    $pcIp = Get-SelectedIp
    $adapter = Get-InterfaceForIp -Address $pcIp
    $adapterText = 'physical Wi-Fi/Ethernet adapter used by this PC'
    if ($adapter) { $adapterText = [string]$adapter.Interface }
    $text = 'Universal DPS meter capture target: StarSEA' + "`r`n" +
            'Physical network adapter: ' + $adapterText + "`r`n" +
            'Configure the meter to detect/capture StarSEA. BPSRMobileFront is only the phone-facing proxy.' + "`r`n" +
            'ZDPS example: Game Capture Preference = Custom; Custom BPSR Executable Name: StarSEA' + "`r`n" +
            'Do not target BPSRMobileFront or BPSRRelayIngress.'
    [System.Windows.Forms.Clipboard]::SetText($text)
    Add-Log 'Copied universal DPS-meter StarSEA capture notes to clipboard.'
}


function Get-PreflightChecks {
    param([string]$PcIp, [switch]$RequirePortFree)

    $checks = New-Object System.Collections.ArrayList
    function Add-CheckLocal([string]$Name, [string]$State, [string]$Detail) {
        [void]$checks.Add([PSCustomObject]@{ Name = $Name; State = $State; Detail = $Detail })
    }

    if (Test-LocalIpAssigned $PcIp) { Add-CheckLocal 'LAN IP' 'OK' $PcIp }
    else { Add-CheckLocal 'LAN IP' 'FAIL' 'Selected IP is not currently assigned to this PC.' }

    $version = Get-InstalledVersion
    if (Test-RuntimeIntegrity) {
        if ($version -eq $TestedSingBoxVersion) {
            Add-CheckLocal 'Runtime' 'OK' ($version + ' tested / verified')
        }
        else {
            Add-CheckLocal 'Runtime' 'OK' ($version + ' verified rollback; current project-tested version is ' + $TestedSingBoxVersion)
        }
    }
    else {
        Add-CheckLocal 'Runtime' 'FAIL' 'Runtime integrity failed or Prepare Relay has not completed.'
    }

    if ((Test-Path -LiteralPath $FrontExe) -and
        (Test-Path -LiteralPath $StarExe) -and
        (Test-Path -LiteralPath $SingBoxExe)) {
        try {
            $baseHash = (Get-FileHash -LiteralPath $SingBoxExe -Algorithm SHA256).Hash
            $frontHash = (Get-FileHash -LiteralPath $FrontExe -Algorithm SHA256).Hash
            $starHash = (Get-FileHash -LiteralPath $StarExe -Algorithm SHA256).Hash
            if ($baseHash -eq $frontHash -and $baseHash -eq $starHash) {
                Add-CheckLocal 'Relay binaries' 'OK' 'BPSRMobileFront and StarSEA match the verified sing-box runtime.'
            }
            else {
                Add-CheckLocal 'Relay binaries' 'FAIL' 'A relay runtime copy hash does not match.'
            }
        }
        catch { Add-CheckLocal 'Relay binaries' 'FAIL' $_.Exception.Message }
    }
    else {
        Add-CheckLocal 'Relay binaries' 'FAIL' 'Run Prepare Relay first.'
    }

    $profileIp = Get-ProfilePcIp
    if ($profileIp -eq $PcIp) {
        Add-CheckLocal 'Android profile' 'OK' ('v1.0.1 v4-compatible profile matches ' + $PcIp)
    }
    elseif ([string]::IsNullOrWhiteSpace($profileIp)) {
        Add-CheckLocal 'Android profile' 'FAIL' 'v1.0.1 profile is not generated. Click Prepare Relay, then import the new profile into SFA.'
    }
    else {
        Add-CheckLocal 'Android profile' 'FAIL' ('Stale: profile=' + $profileIp + ', selected=' + $PcIp)
    }

    try {
        Validate-GeneratedConfigs -PcIp $PcIp
        Add-CheckLocal 'Relay topology' 'OK' 'BPSRMobileFront -> localhost -> StarSEA -> game server; one StarSEA capture path.'
    }
    catch {
        Add-CheckLocal 'Relay topology' 'FAIL' $_.Exception.Message
    }

    try {
        Assert-NoForeignRelayProcesses
        Add-CheckLocal 'Duplicate relay processes' 'OK' 'No extra StarSEA/front/legacy relay process detected.'
    }
    catch {
        Add-CheckLocal 'Duplicate relay processes' 'FAIL' $_.Exception.Message
    }

    if ($RequirePortFree) {
        $tcpListeners = @(Get-ListeningConnections -Port $FrontPort)
        $udpEndpoints = @(Get-ListeningUdpEndpoints -Port $FrontPort)
        if ($tcpListeners.Count -eq 0) {
            Add-CheckLocal ('TCP ' + $FrontPort) 'OK' 'Free for BPSRMobileFront.'
        }
        else {
            Add-CheckLocal ('TCP ' + $FrontPort) 'FAIL' 'Already in use.'
        }
        if ($udpEndpoints.Count -eq 0) {
            Add-CheckLocal ('UDP ' + $FrontPort) 'OK' 'Free for BPSRMobileFront.'
        }
        else {
            Add-CheckLocal ('UDP ' + $FrontPort) 'FAIL' 'Already in use.'
        }
    }

    $category = Get-NetworkCategoryForIp -Address $PcIp
    if ($category -eq 'Private') {
        Add-CheckLocal 'Windows network profile' 'OK' 'Private'
        if (Test-FirewallReady -PcIp $PcIp) {
            Add-CheckLocal 'Firewall' 'OK' 'Private-LAN TCP+UDP rules are active for the v4-compatible relay.'
        }
        else {
            Add-CheckLocal 'Firewall' 'FAIL' 'Click Allow Firewall to create the TCP+UDP Private-LAN rules for this IP.'
        }
    }
    elseif ($category -eq 'Public') {
        Add-CheckLocal 'Windows network profile' 'FAIL' 'Current category: Public. Click Allow Firewall and approve changing this trusted LAN to Private.'
        Add-CheckLocal 'Firewall' 'FAIL' 'The safe Private-only relay rules cannot apply while this network is Public.'
    }
    else {
        Add-CheckLocal 'Windows network profile' 'FAIL' ('Current category: ' + $category + '. The relay requires a Private network profile.')
        Add-CheckLocal 'Firewall' 'FAIL' 'The Private-only relay rules are not active on this network profile.'
    }

    return @($checks)
}

function Format-Checks {
    param($Checks)
    return (($Checks | ForEach-Object { '[' + $_.State + '] ' + $_.Name + ' - ' + $_.Detail }) -join [Environment]::NewLine)
}

function Show-Preflight {
    $pcIp = Get-SelectedIp
    $running = Get-RelayTrackedRunning
    $checks = Get-PreflightChecks -PcIp $pcIp -RequirePortFree:(-not $running)
    foreach ($line in (Format-Checks -Checks $checks) -split [Environment]::NewLine) { Add-Log $line }
    $fails = @($checks | Where-Object { $_.State -eq 'FAIL' })
    $title = if ($fails.Count -eq 0) { 'Preflight passed' } else { 'Preflight found a problem' }
    [System.Windows.Forms.MessageBox]::Show((Format-Checks -Checks $checks), $title, [System.Windows.Forms.MessageBoxButtons]::OK,
        $(if ($fails.Count -eq 0) { [System.Windows.Forms.MessageBoxIcon]::Information } else { [System.Windows.Forms.MessageBoxIcon]::Warning })) | Out-Null
}


function Start-Relay {
    $pcIp = Get-SelectedIp
    Stop-ProfileShare

    if (Get-RelayTrackedRunning) {
        Add-Log 'v1.0.1 two-stage relay is already running.'
        Update-Status
        return
    }

    Stop-Relay
    [void](Ensure-InternalBridgePortAvailable -PcIp $pcIp)
    $checks = Get-PreflightChecks -PcIp $pcIp -RequirePortFree
    $fails = @($checks | Where-Object { $_.State -eq 'FAIL' })
    if ($fails.Count -gt 0) {
        throw ('Preflight failed:' + [Environment]::NewLine + (Format-Checks -Checks $fails))
    }
    foreach ($warning in @($checks | Where-Object { $_.State -eq 'WARN' })) {
        Add-Log ('WARNING: ' + $warning.Name + ' - ' + $warning.Detail)
    }

    $starProcess = $null
    $frontProcess = $null
    try {
        $starConfigObject = Read-JsonFile -Path $StarConfig
        $starInbound = @($starConfigObject.inbounds | Select-Object -First 1)[0]
        $internalPort = [int]$starInbound.listen_port

        Add-Log ('Starting StarSEA localhost back relay on 127.0.0.1:' + $internalPort + '...')
        $starArgs = 'run -c ' + (Quote-Argument $StarConfig)
        $starProcess = Start-Process -FilePath $StarExe -ArgumentList $starArgs -WorkingDirectory $Runtime -WindowStyle Hidden -PassThru
        Wait-ForProcessListener -ProcessId $starProcess.Id -Address '127.0.0.1' -Port $internalPort -ProcessLabel 'StarSEA'
        $starProcess.Refresh()
        if ($starProcess.HasExited) { throw 'StarSEA exited immediately after startup.' }

        Add-Log ('Starting BPSRMobileFront phone relay on ' + $pcIp + ':' + $FrontPort + '...')
        $frontArgs = 'run -c ' + (Quote-Argument $FrontConfig)
        $frontProcess = Start-Process -FilePath $FrontExe -ArgumentList $frontArgs -WorkingDirectory $Runtime -WindowStyle Hidden -PassThru
        Wait-ForProcessListener -ProcessId $frontProcess.Id -Address $pcIp -Port $FrontPort -ProcessLabel 'BPSRMobileFront'
        $frontProcess.Refresh()
        if ($frontProcess.HasExited) { throw 'BPSRMobileFront exited immediately after startup.' }

        $starStartUtc = $starProcess.StartTime.ToUniversalTime().ToString('o')
        $frontStartUtc = $frontProcess.StartTime.ToUniversalTime().ToString('o')
        Write-JsonFile -Path $PidFile -Value ([ordered]@{
            starPid = $starProcess.Id
            starStartUtc = $starStartUtc
            frontPid = $frontProcess.Id
            frontStartUtc = $frontStartUtc
            starPath = $StarExe
            frontPath = $FrontExe
            pcIp = $pcIp
            startedUtc = [DateTime]::UtcNow.ToString('o')
        })
        Set-TrackedRelayIdentity `
            -StarProcessId $starProcess.Id `
            -StarStartUtc $starStartUtc `
            -FrontProcessId $frontProcess.Id `
            -FrontStartUtc $frontStartUtc

        Add-Log ('Relay RUNNING: Android -> BPSRMobileFront PID ' + $frontProcess.Id +
                 ' -> localhost -> StarSEA PID ' + $starProcess.Id + ' -> game server.')
        Add-Log 'DPS target remains StarSEA only. Do not target BPSRMobileFront.'
        Add-Log 'Phone-to-PC SOCKS5 is authenticated but not encrypted; use only on your trusted Private LAN and do not port-forward it.'
    }
    catch {
        if ($frontProcess) { Stop-Process -Id $frontProcess.Id -Force -ErrorAction SilentlyContinue }
        if ($starProcess) { Stop-Process -Id $starProcess.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        Clear-TrackedRelayIdentity
        throw
    }
    finally {
        Update-Status
    }
}


function Get-DiagnosticsText {
    $pcIp = ''
    try { $pcIp = Get-SelectedIp } catch { $pcIp = ([string]$script:cmbIp.Text).Trim() }
    $profileIp = Get-ProfilePcIp
    $runtimeVersion = Get-InstalledVersion
    $relayRunning = Get-RelayTrackedRunning
    $starCount = @(Get-Process -Name 'StarSEA' -ErrorAction SilentlyContinue).Count
    $frontCount = @(Get-Process -Name 'BPSRMobileFront' -ErrorAction SilentlyContinue).Count
    $legacyCount = @(Get-Process -Name 'BPSRRelayIngress' -ErrorAction SilentlyContinue).Count
    $listeners = @(Get-ListeningConnections -Port $FrontPort)
    $listenerText = if ($listeners.Count -eq 0) {
        'none'
    }
    else {
        (($listeners | ForEach-Object { $_.LocalAddress + ':' + $_.LocalPort + ' pid=' + $_.OwningProcess }) -join '; ')
    }

    $internalPortText = 'unknown'
    try {
        $starObject = Read-JsonFile -Path $StarConfig
        $starInbound = @($starObject.inbounds | Select-Object -First 1)[0]
        if ($starInbound) { $internalPortText = [string]$starInbound.listen_port }
    }
    catch {}

    $networkCategory = if (-not [string]::IsNullOrWhiteSpace($pcIp)) {
        Get-NetworkCategoryForIp -Address $pcIp
    }
    else { 'unknown' }

    $firewall = if ($networkCategory -eq 'Public') {
        'BLOCKED - Windows network is Public; click Allow Firewall to change this trusted LAN to Private'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($pcIp) -and (Test-FirewallReady -PcIp $pcIp)) {
        'OK - TCP+UDP active on Private network'
    }
    else {
        'not active / mismatch'
    }

    $topology = 'NOT CHECKED'
    if (-not [string]::IsNullOrWhiteSpace($pcIp)) {
        try {
            Assert-Topology -PcIp $pcIp
            $topology = 'OK - Clean v4-compatible two-stage SOCKS5 / one StarSEA game-server path'
        }
        catch {
            $topology = 'FAIL - ' + $_.Exception.Message
        }
    }

    $adapter = $null
    if (-not [string]::IsNullOrWhiteSpace($pcIp)) { $adapter = Get-InterfaceForIp -Address $pcIp }
    $adapterText = if ($adapter) { [string]$adapter.Interface } else { 'unknown' }

    return @"
BPSR Android DPSMeter Relay Diagnostics
Manager: $ManagerVersion
Tested sing-box: $TestedSingBoxVersion
Installed sing-box: $runtimeVersion
Runtime integrity: $(if (Test-RuntimeIntegrity) { 'OK' } else { 'FAIL/UNKNOWN' })

Selected PC IP: $pcIp
Selected adapter: $adapterText
Windows network category: $networkCategory
Profile IP: $profileIp
Firewall: $firewall

Relay running: $relayRunning
BPSRMobileFront process count: $frontCount
StarSEA process count: $starCount
Legacy BPSRRelayIngress process count: $legacyCount
Phone relay TCP listener: $listenerText
Localhost StarSEA bridge port: $internalPortText
Topology: $topology
Ingress transport: authenticated SOCKS5 on trusted Private LAN
Phone-to-PC encryption: DISABLED in v1.0.1 compatibility mode
Android protocol sniffing: DISABLED
Android selected-app route: all BPSR app traffic -> BPSRMobileFront -> localhost StarSEA -> game server
Multiplexing: DISABLED

Universal DPS meter target:
Process / executable: StarSEA
Do NOT target: BPSRMobileFront
Physical adapter: $adapterText
Any compatible DPS meter may independently capture the StarSEA stream.
ZDPS example only: Game Capture Preference = Custom; Custom BPSR Executable Name: StarSEA

No relay passwords or profile secrets are included in this diagnostic.
"@
}

function Copy-Diagnostics {
    [System.Windows.Forms.Clipboard]::SetText((Get-DiagnosticsText))
    Add-Log 'Copied privacy-safe diagnostics to clipboard.'
}

function Update-Status {
    if ($script:shareProcess) {
        try {
            $script:shareProcess.Refresh()
            if ($script:shareProcess.HasExited) {
                $script:shareProcess = $null
                $script:shareUrl = ''
                if ($script:txtLog) { Add-Log 'Temporary phone sharing ended/expired.' }
            }
        }
        catch {
            $script:shareProcess = $null
            $script:shareUrl = ''
        }
    }

    if (-not $script:lblRelayState) { return }

    # Gameplay hot path: once the tracked two-process relay is running, status polling must remain tiny.
    # Do not hash the runtime, enumerate adapters, reread PID JSON, or resolve executable paths every timer tick.
    if (Get-RelayTrackedRunning) {
        $script:lblRelayState.Text = 'Relay: RUNNING - v4-compatible path'
        $script:lblRelayState.ForeColor = [System.Drawing.Color]::DarkGreen
        return
    }

    if (@(Get-Process -Name 'StarSEA','BPSRMobileFront','BPSRRelayIngress' -ErrorAction SilentlyContinue).Count -gt 0) {
        $script:lblRelayState.Text = 'Relay: FOREIGN / DUPLICATE PROCESS DETECTED'
        $script:lblRelayState.ForeColor = [System.Drawing.Color]::Firebrick
    }
    else {
        $script:lblRelayState.Text = 'Relay: STOPPED'
        $script:lblRelayState.ForeColor = [System.Drawing.Color]::Firebrick
    }

    $selected = ([string]$script:cmbIp.Text).Trim()
    $profileIp = Get-ProfilePcIp
    if ([string]::IsNullOrWhiteSpace($profileIp)) {
        $script:lblProfileState.Text = 'Android profile: NOT GENERATED'
        $script:lblProfileState.ForeColor = [System.Drawing.Color]::Firebrick
    }
    elseif ($profileIp -eq $selected -and (Test-LocalIpAssigned $selected)) {
        $script:lblProfileState.Text = 'Android profile: READY - ' + $profileIp
        $script:lblProfileState.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    else {
        $script:lblProfileState.Text = 'Android profile: OUTDATED - profile ' + $profileIp + ' / selected ' + $selected
        $script:lblProfileState.ForeColor = [System.Drawing.Color]::DarkOrange
    }

    $version = Get-InstalledVersion
    if (Test-RuntimeIntegrity) {
        if ($version -eq $TestedSingBoxVersion) {
            $script:lblRuntimeState.Text = 'Runtime: ' + $version + ' TESTED / VERIFIED'
        }
        else {
            $script:lblRuntimeState.Text = 'Runtime: ' + $version + ' VERIFIED ROLLBACK (tested: ' + $TestedSingBoxVersion + ')'
        }
        $script:lblRuntimeState.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    else {
        $script:lblRuntimeState.Text = 'Runtime: SETUP / REPAIR REQUIRED'
        $script:lblRuntimeState.ForeColor = [System.Drawing.Color]::DarkOrange
    }
}


function Invoke-SelfTest {
    Ensure-Directories
    $testIp = '192.0.2.10'
    Write-Host ('BPSR Relay Manager self-test ' + $ManagerVersion)
    Write-Host ('Pinned sing-box: ' + $TestedSingBoxVersion)

    $sourceText = Get-Content -LiteralPath $PSCommandPath -Raw
    if ($sourceText -notmatch 'Set-NetConnectionProfile') {
        throw 'Self-test found missing Public-to-Private network repair path.'
    }
    if ($sourceText -notmatch "Windows network profile' 'FAIL'") {
        throw 'Self-test found missing blocking network-profile preflight.'
    }
    if ($sourceText -notmatch 'Protocol UDP') {
        throw 'Self-test found missing UDP trusted-LAN firewall rule.'
    }

    Ensure-TestedSingBox
    $credentials = Get-OrCreateCredentials
    Copy-Item -LiteralPath $SingBoxExe -Destination $FrontExe -Force
    Copy-Item -LiteralPath $SingBoxExe -Destination $StarExe -Force
    Write-RelayConfigs -PcIp $testIp -Credentials $credentials
    Validate-GeneratedConfigs -PcIp $testIp

    $androidText = Get-Content -LiteralPath $AndroidConfig -Raw
    $frontText = Get-Content -LiteralPath $FrontConfig -Raw
    $starText = Get-Content -LiteralPath $StarConfig -Raw
    $allText = $androidText + "`n" + $frontText + "`n" + $starText

    if ($androidText -match '"action"\s*:\s*"sniff"') {
        throw 'Self-test found forbidden sniff action.'
    }
    if ($androidText -match '"strict_route"') {
        throw 'Self-test found unsupported SFA Android strict_route option.'
    }
    if ($allText -match '"multiplex"') {
        throw 'Self-test found multiplexing on the latency path.'
    }
    if ($androidText -notmatch 'route_exclude_address') {
        throw 'Self-test found missing TUN relay-IP exclusion.'
    }
    if ($androidText -notmatch '"final"\s*:\s*"bpsr-pc"') {
        throw 'Self-test found Android traffic is not fully routed to the v4-compatible PC proxy.'
    }
    if ($frontText -notmatch '"server"\s*:\s*"127\.0\.0\.1"') {
        throw 'Self-test found BPSRMobileFront is not forwarding only to localhost.'
    }
    if ($allText -match '"type"\s*:\s*"shadowsocks"') {
        throw 'Self-test found RC.14 Shadowsocks transport still present.'
    }

    Write-Host 'SELF-TEST PASS: configs parse, original Clean v4-compatible two-stage SOCKS5 route restored, no sniff/multiplex, StarSEA remains the only game-server process.'
}

Ensure-Directories

if ($SelfTest) {
    try {
        Invoke-SelfTest
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

$UiScript = Join-Path $PSScriptRoot 'ManagerUi.ps1'
if (-not (Test-Path -LiteralPath $UiScript -PathType Leaf)) {
    throw 'ManagerUi.ps1 is missing. Re-extract the full release ZIP.'
}
. $UiScript
