param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ManagerVersion = '1.0.0-rc.6'
$TestedSingBoxVersion = 'v1.13.19'
$IngressMethod = '2022-blake3-aes-128-gcm'
$FrontPort = 10902
$BpsrTcpPorts = @(15000, 16000, 17000, 18000, 20000, 20001, 21000)
$FirewallRuleName = 'BPSR Android DPSMeter Relay'
$ShareLifetimeSeconds = 300

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
$StarExe = Join-Path $Runtime 'StarSEA.exe'
$StarConfig = Join-Path $ConfigDir 'starsea-relay.json'
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

function Add-Log {
    param([string]$Message)
    Ensure-Directories
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

function Install-SingBoxVersion {
    param([string]$Version)

    Ensure-Directories
    $arch = Get-SingBoxArchitecture
    $number = $Version.TrimStart('v')
    Add-Log ('Downloading tested sing-box ' + $Version + ' for Windows/' + $arch + '...')

    $releaseUri = 'https://api.github.com/repos/SagerNet/sing-box/releases/tags/' + $Version
    $release = Invoke-RestMethod -Uri $releaseUri -UseBasicParsing -Headers @{ 'User-Agent' = 'BPSR-Android-DPSMeter-Relay' }
    if (-not $release -or [string]$release.tag_name -ne $Version) {
        throw ('Could not resolve official sing-box release ' + $Version + '.')
    }

    $assetName = 'sing-box-' + $number + '-windows-' + $arch + '.zip'
    $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if (-not $asset) { throw ('Official release asset not found: ' + $assetName) }
    if ([string]$asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
        throw 'The official release asset did not expose a SHA256 digest. Refusing an unverified runtime download.'
    }
    $expectedZipHash = $Matches[1].ToLowerInvariant()

    $temp = Join-Path $Runtime 'download-temp'
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    try {
        $zipPath = Join-Path $temp $assetName
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -Headers @{ 'User-Agent' = 'BPSR-Android-DPSMeter-Relay' }
        $actualZipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualZipHash -ne $expectedZipHash) {
            throw 'SHA256 verification failed for the official sing-box archive.'
        }
        Add-Log 'Official sing-box archive SHA256 verification passed.'

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
                [string]$existing.ingressMethod -eq $IngressMethod -and
                [string]$existing.ingressPassword -match '^[A-Za-z0-9+/]{22}==$') {
                return $existing
            }
            Add-Log 'Existing relay credentials were invalid or incompatible; generating new credentials.'
        }
        catch {
            Add-Log 'Existing relay credentials were unreadable; generating new credentials.'
        }
    }

    $credentials = [ordered]@{
        ingressMethod = $IngressMethod
        ingressPassword = New-RandomBase64 -Length 16
        createdUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonFile -Path $CredentialsFile -Value $credentials
    Add-Log 'Generated persistent relay credentials. They are reused so routine repairs do not force a new SFA import.'
    return (Read-JsonFile -Path $CredentialsFile)
}

function Write-RelayConfigs {
    param([string]$PcIp, $Credentials)

    Ensure-Directories

    $star = [ordered]@{
        log = [ordered]@{ disabled = $true; level = 'error' }
        inbounds = @(
            [ordered]@{
                type = 'shadowsocks'
                tag = 'phone-encrypted-in'
                listen = $PcIp
                listen_port = $FrontPort
                network = 'tcp'
                method = [string]$Credentials.ingressMethod
                password = [string]$Credentials.ingressPassword
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
            final = 'local'
            strategy = 'prefer_ipv4'
        }
        inbounds = @(
            [ordered]@{
                type = 'tun'
                tag = 'tun-in'
                address = @('172.19.0.1/30')
                auto_route = $true
                strict_route = $true
                route_exclude_address = @($PcIp + '/32')
                stack = 'system'
            }
        )
        outbounds = @(
            [ordered]@{
                type = 'shadowsocks'
                tag = 'bpsr-pc'
                server = $PcIp
                server_port = $FrontPort
                network = 'tcp'
                method = [string]$Credentials.ingressMethod
                password = [string]$Credentials.ingressPassword
            },
            [ordered]@{ type = 'direct'; tag = 'direct' }
        )
        route = [ordered]@{
            rules = @(
                [ordered]@{ protocol = 'dns'; action = 'hijack-dns' },
                [ordered]@{
                    network = 'tcp'
                    port = $BpsrTcpPorts
                    action = 'route'
                    outbound = 'bpsr-pc'
                }
            )
            final = 'direct'
            auto_detect_interface = $true
            default_domain_resolver = 'local'
        }
    }

    Write-JsonFile -Path $StarConfig -Value $star
    Write-JsonFile -Path $AndroidConfig -Value $android
    Write-JsonFile -Path $ProfileMeta -Value ([ordered]@{
        managerVersion = $ManagerVersion
        pcIp = $PcIp
        relayPort = $FrontPort
        ingress = 'encrypted-shadowsocks'
        ingressMethod = [string]$Credentials.ingressMethod
        testedSingBoxVersion = $TestedSingBoxVersion
        bpsrTcpPorts = $BpsrTcpPorts
        generatedUtc = [DateTime]::UtcNow.ToString('o')
    })

    $importText = @"
BPSR Android DPSMeter Relay

Import android-bpsr-relay.json into SFA on the Android phone.
PC LAN IPv4 in this profile: $PcIp
Relay port: $FrontPort

SFA:
- Use per-app mode / Proxy selected apps.
- Select BPSR only after testing.

DPS meter:
- Universal relay capture target: StarSEA
- If your meter captures by process/executable, configure it to detect StarSEA.
- If it captures by network device, select the physical Wi-Fi/Ethernet adapter carrying StarSEA traffic.
- ZDPS example: Game Capture Preference = Custom; Custom BPSR Executable Name: StarSEA

IMPORTANT:
Only StarSEA sends clear BPSR traffic to the game server. Phone-to-PC relay traffic is encrypted so a packet parser cannot count the same BPSR payload a second time.
Multiple compatible DPS meters may independently observe the same StarSEA stream.
"@
    Write-Utf8NoBom -Path (Join-Path $OutputDir 'README-IMPORT.txt') -Text $importText
    Add-Log ('Generated encrypted Android SFA profile for PC ' + $PcIp + '.')
}

function Get-ProfilePcIp {
    try {
        $profile = Read-JsonFile -Path $AndroidConfig
        if (-not $profile) { return '' }
        $outbound = @($profile.outbounds | Where-Object { $_.tag -eq 'bpsr-pc' } | Select-Object -First 1)[0]
        if (-not $outbound) { return '' }
        return [string]$outbound.server
    }
    catch { return '' }
}

function Assert-Topology {
    param([string]$PcIp)

    $star = Read-JsonFile -Path $StarConfig
    $android = Read-JsonFile -Path $AndroidConfig
    if (-not $star -or -not $android) { throw 'Generated relay configuration files are missing or unreadable.' }

    $starIn = @($star.inbounds)
    $starOut = @($star.outbounds)
    if ($starIn.Count -ne 1 -or [string]$starIn[0].type -ne 'shadowsocks') {
        throw 'Topology check failed: StarSEA must have exactly one encrypted Shadowsocks inbound.'
    }
    if ([string]$starIn[0].listen -ne $PcIp -or [int]$starIn[0].listen_port -ne $FrontPort) {
        throw 'Topology check failed: StarSEA is not bound only to the selected LAN IP/relay port.'
    }
    if ([string]$starIn[0].network -ne 'tcp' -or [string]$starIn[0].method -ne $IngressMethod) {
        throw 'Topology check failed: the encrypted ingress is not the expected low-overhead TCP Shadowsocks mode.'
    }
    if ($starOut.Count -ne 1 -or [string]$starOut[0].type -ne 'direct' -or [string]$star.route.final -ne 'direct') {
        throw 'Topology check failed: StarSEA must have exactly one direct Internet outbound path.'
    }

    $androidTun = @($android.inbounds | Where-Object { $_.tag -eq 'tun-in' } | Select-Object -First 1)[0]
    $androidProxy = @($android.outbounds | Where-Object { $_.tag -eq 'bpsr-pc' } | Select-Object -First 1)[0]
    if (-not $androidTun -or -not $androidProxy) { throw 'Topology check failed: Android TUN/proxy entries are missing.' }
    if ([string]$androidProxy.type -ne 'shadowsocks' -or [string]$androidProxy.server -ne $PcIp -or [int]$androidProxy.server_port -ne $FrontPort) {
        throw 'Topology check failed: Android is not using the encrypted PC relay.'
    }
    if ([string]$androidProxy.method -ne $IngressMethod -or [string]$androidProxy.password -ne [string]$starIn[0].password) {
        throw 'Topology check failed: Android and StarSEA encryption credentials do not match.'
    }
    if (@($android.route.rules | Where-Object { $_.action -eq 'sniff' }).Count -ne 0) {
        throw 'Topology check failed: protocol sniffing must remain disabled on the latency path.'
    }
    if (-not (@($androidTun.route_exclude_address) -contains ($PcIp + '/32'))) {
        throw 'Topology check failed: the PC relay IP must be excluded from the Android TUN route to prevent a VPN loop.'
    }
    if ([string]$android.route.final -ne 'direct') {
        throw 'Topology check failed: non-BPSR Android traffic must remain direct.'
    }

    $bpsrRules = @($android.route.rules | Where-Object { $_.outbound -eq 'bpsr-pc' })
    if ($bpsrRules.Count -ne 1 -or [string]$bpsrRules[0].network -ne 'tcp') {
        throw 'Topology check failed: there must be exactly one TCP BPSR relay rule.'
    }
    $actualPorts = @($bpsrRules[0].port | ForEach-Object { [int]$_ } | Sort-Object)
    $expectedPorts = @($BpsrTcpPorts | Sort-Object)
    if (($actualPorts -join ',') -ne ($expectedPorts -join ',')) {
        throw 'Topology check failed: the BPSR TCP port allow-list changed unexpectedly.'
    }

    $jsonText = (Get-Content -LiteralPath $StarConfig -Raw) + "`n" + (Get-Content -LiteralPath $AndroidConfig -Raw)
    if ($jsonText -match 'BPSRMobileFront|BPSRRelayIngress|"type"\s*:\s*"socks"') {
        throw 'Topology check failed: legacy/raw relay components unexpectedly remain in the generated data path.'
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
    Test-SingBoxConfig -ConfigPath $StarConfig
    Test-SingBoxConfig -ConfigPath $AndroidConfig
    Add-Log 'Config validation passed: encrypted single-process topology, no sniffing, no second clear BPSR path.'
}

function Get-RecordedPids {
    try { return Read-JsonFile -Path $PidFile } catch { return $null }
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
        Update-Status
        return
    }

    if ($state.starPid) {
        $start = ''
        if ($state.starStartUtc) { $start = [string]$state.starStartUtc }
        if (Test-ExpectedProcess -ProcessId ([int]$state.starPid) -ExpectedPath $StarExe -ExpectedStartUtc $start) {
            try {
                Stop-Process -Id ([int]$state.starPid) -Force -ErrorAction Stop
                Add-Log ('Stopped StarSEA (PID ' + [int]$state.starPid + ').')
            }
            catch { Add-Log ('Warning: could not stop StarSEA: ' + $_.Exception.Message) }
        }
    }

    # Migration cleanup for the previous two-process RC. Only stop the exact runtime copy we created.
    if ($state.frontPid) {
        foreach ($legacyPath in @((Join-Path $Runtime 'BPSRMobileFront.exe'), (Join-Path $Runtime 'BPSRRelayIngress.exe'))) {
            if (Test-ExpectedProcess -ProcessId ([int]$state.frontPid) -ExpectedPath $legacyPath) {
                try {
                    Stop-Process -Id ([int]$state.frontPid) -Force -ErrorAction Stop
                    Add-Log ('Stopped legacy relay process PID ' + [int]$state.frontPid + '.')
                }
                catch {}
                break
            }
        }
    }

    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Update-Status
}

function Assert-NoForeignRelayProcesses {
    $state = Get-RecordedPids
    $trackedStar = 0
    $trackedStart = ''
    if ($state -and $state.starPid) {
        $trackedStar = [int]$state.starPid
        if ($state.starStartUtc) { $trackedStart = [string]$state.starStartUtc }
    }

    $foreign = @()
    foreach ($name in @('StarSEA', 'BPSRMobileFront', 'BPSRRelayIngress')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            if ($name -eq 'StarSEA' -and
                $process.Id -eq $trackedStar -and
                (Test-ExpectedProcess -ProcessId $process.Id -ExpectedPath $StarExe -ExpectedStartUtc $trackedStart)) {
                continue
            }
            $foreign += ($name + ' (PID ' + $process.Id + ')')
        }
    }
    if ($foreign.Count -gt 0) {
        throw ('Foreign/legacy relay process detected: ' + ($foreign -join ', ') + '. Close it before continuing so there is never a second relay path.')
    }
}

function Get-ListeningConnections {
    param([int]$Port)
    try { return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) }
    catch { return @() }
}

function Assert-RelayPortFree {
    $listeners = @(Get-ListeningConnections -Port $FrontPort)
    if ($listeners.Count -gt 0) {
        $owners = @($listeners | ForEach-Object { [string]$_.OwningProcess } | Select-Object -Unique)
        throw ('TCP ' + $FrontPort + ' is already listening (PID ' + ($owners -join ', ') + '). Stop the conflicting program first.')
    }
}

function Wait-ForRelayListener {
    param([int]$ProcessId, [string]$PcIp)
    for ($i = 0; $i -lt 40; $i++) {
        try {
            $process = Get-Process -Id $ProcessId -ErrorAction Stop
            if ($process.HasExited) { throw 'StarSEA exited during startup.' }
        }
        catch { throw 'StarSEA exited during startup.' }

        $listeners = @(Get-ListeningConnections -Port $FrontPort | Where-Object {
            [int]$_.OwningProcess -eq $ProcessId -and ([string]$_.LocalAddress -eq $PcIp -or [string]$_.LocalAddress -eq '0.0.0.0')
        })
        if ($listeners.Count -gt 0) { return }
        Start-Sleep -Milliseconds 100
    }
    throw ('StarSEA did not begin listening on ' + $PcIp + ':' + $FrontPort + ' within 4 seconds.')
}

function Test-FirewallReady {
    param([string]$PcIp)
    try {
        $rules = @(Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction Stop | Where-Object { $_.Enabled -eq 'True' })
        foreach ($rule in $rules) {
            if ([string]$rule.Profile -notmatch 'Private') { continue }
            $port = $rule | Get-NetFirewallPortFilter
            $addr = $rule | Get-NetFirewallAddressFilter
            if ([string]$port.Protocol -eq 'TCP' -and [string]$port.LocalPort -eq [string]$FrontPort) {
                $locals = @($addr.LocalAddress)
                $remotes = @($addr.RemoteAddress)
                if (($locals -contains $PcIp) -and ($remotes -contains 'LocalSubnet')) {
                    return $true
                }
            }
        }
    }
    catch {}
    return $false
}

function Allow-Firewall {
    $pcIp = Get-SelectedIp
    Ensure-Directories
    $body = @"
`$ErrorActionPreference = 'Stop'
`$display = '$FirewallRuleName'
Get-NetFirewallRule -DisplayName `$display -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName `$display -Direction Inbound -Action Allow -Protocol TCP -LocalPort $FrontPort -LocalAddress '$pcIp' -RemoteAddress LocalSubnet -Profile Private -EdgeTraversalPolicy Block | Out-Null
"@
    Write-Utf8NoBom -Path $FirewallScript -Text $body

    Add-Log ('Requesting Administrator permission for the LAN-only firewall rule on ' + $pcIp + ':' + $FrontPort + '...')
    $args = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Argument $FirewallScript)
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList $args
    if ($process.ExitCode -ne 0) { throw ('Firewall setup failed with exit code ' + $process.ExitCode + '.') }
    Add-Log 'Firewall ready: Private profile, selected local IP only, LocalSubnet remote only.'
    Update-Status
}

function Remove-LegacyRuntimeFiles {
    foreach ($path in @(
        (Join-Path $Runtime 'BPSRMobileFront.exe'),
        (Join-Path $Runtime 'BPSRRelayIngress.exe'),
        (Join-Path $ConfigDir 'front-socks.json'),
        (Join-Path $ConfigDir 'relay-hidden.json')
    )) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
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

    Copy-Item -LiteralPath $SingBoxExe -Destination $StarExe -Force
    $sourceHash = (Get-FileHash -LiteralPath $SingBoxExe -Algorithm SHA256).Hash
    $starHash = (Get-FileHash -LiteralPath $StarExe -Algorithm SHA256).Hash
    if ($sourceHash -ne $starHash) { throw 'StarSEA runtime copy verification failed.' }

    Write-RelayConfigs -PcIp $pcIp -Credentials $credentials
    Validate-GeneratedConfigs -PcIp $pcIp
    Remove-LegacyRuntimeFiles

    Add-Log 'Setup / Repair complete. The data path now uses one StarSEA relay process and encrypted phone-to-PC transport.'
    Add-Log 'Next: Firewall -> Share to Phone/import SFA profile -> configure any compatible DPS meter to capture StarSEA -> Preflight -> START RELAY.'
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
    $state = Get-RecordedPids
    if (-not $state -or -not $state.starPid) { return $false }
    $start = ''
    if ($state.starStartUtc) { $start = [string]$state.starStartUtc }
    return Test-ExpectedProcess -ProcessId ([int]$state.starPid) -ExpectedPath $StarExe -ExpectedStartUtc $start
}

function Start-ProfileShare {
    $pcIp = Get-SelectedIp
    if (-not (Test-Path -LiteralPath $AndroidConfig)) { throw 'Run Setup / Repair first.' }
    if ((Get-ProfilePcIp) -ne $pcIp) { throw 'The Android profile is stale for this IP. Run Setup / Repair first.' }
    if (-not (Test-Path -LiteralPath $ServerScript)) { throw 'ServeProfile.ps1 is missing.' }
    if (Get-RelayTrackedRunning) { throw 'Stop the relay before sharing the profile. The share page intentionally uses the same port and never runs during gameplay.' }

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
    [System.Windows.Forms.Clipboard]::SetText($script:shareUrl)
    Add-Log ('Temporary profile page started for up to ' + $ShareLifetimeSeconds + ' seconds. URL copied to clipboard.')
    Add-Log 'The share server stops after the profile is downloaded and is never part of the gameplay data path.'
    Update-Status
}

function Copy-ShareUrl {
    if ([string]::IsNullOrWhiteSpace($script:shareUrl) -or -not $script:shareProcess) { throw 'Start Share to Phone first.' }
    $script:shareProcess.Refresh()
    if ($script:shareProcess.HasExited) { throw 'The temporary share page has expired. Start Share to Phone again.' }
    [System.Windows.Forms.Clipboard]::SetText($script:shareUrl)
    Add-Log 'Temporary phone URL copied to clipboard.'
}

function Show-ShareQr {
    if ([string]::IsNullOrWhiteSpace($script:shareUrl) -or -not $script:shareProcess) { throw 'Start Share to Phone first.' }
    $script:shareProcess.Refresh()
    if ($script:shareProcess.HasExited) { throw 'The temporary share page has expired. Start Share to Phone again.' }
    $qrUrl = 'https://quickchart.io/qr?size=360&margin=2&text=' + [Uri]::EscapeDataString($script:shareUrl)
    Start-Process $qrUrl | Out-Null
    Add-Log 'Opened optional QR rendering in the default browser. Copy URL remains available if you prefer not to use the online QR renderer.'
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
            'Configure the meter to detect/capture the StarSEA process or its traffic.' + "`r`n" +
            'ZDPS example: Game Capture Preference = Custom; Custom BPSR Executable Name: StarSEA' + "`r`n" +
            'Do not use a legacy BPSRMobileFront/BPSRRelayIngress process.'
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
    else { Add-CheckLocal 'Runtime' 'FAIL' 'Runtime integrity failed or Setup / Repair has not completed.' }

    if ((Test-Path -LiteralPath $StarExe) -and (Test-Path -LiteralPath $SingBoxExe)) {
        try {
            $same = (Get-FileHash -LiteralPath $StarExe -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $SingBoxExe -Algorithm SHA256).Hash
            if ($same) { Add-CheckLocal 'StarSEA binary' 'OK' 'Matches verified active sing-box runtime.' }
            else { Add-CheckLocal 'StarSEA binary' 'FAIL' 'Runtime copy hash mismatch.' }
        }
        catch { Add-CheckLocal 'StarSEA binary' 'FAIL' $_.Exception.Message }
    }
    else { Add-CheckLocal 'StarSEA binary' 'FAIL' 'Run Setup / Repair first.' }

    $profileIp = Get-ProfilePcIp
    if ($profileIp -eq $PcIp) { Add-CheckLocal 'Android profile' 'OK' ('Matches ' + $PcIp) }
    elseif ([string]::IsNullOrWhiteSpace($profileIp)) { Add-CheckLocal 'Android profile' 'FAIL' 'Profile not generated.' }
    else { Add-CheckLocal 'Android profile' 'FAIL' ('Stale: profile=' + $profileIp + ', selected=' + $PcIp) }

    try {
        Validate-GeneratedConfigs -PcIp $PcIp
        Add-CheckLocal 'Relay topology' 'OK' 'One StarSEA process; encrypted ingress; no sniff; one clear game-server path.'
    }
    catch { Add-CheckLocal 'Relay topology' 'FAIL' $_.Exception.Message }

    try {
        Assert-NoForeignRelayProcesses
        Add-CheckLocal 'Duplicate relay processes' 'OK' 'None detected.'
    }
    catch { Add-CheckLocal 'Duplicate relay processes' 'FAIL' $_.Exception.Message }

    if ($RequirePortFree) {
        $listeners = @(Get-ListeningConnections -Port $FrontPort)
        if ($listeners.Count -eq 0) { Add-CheckLocal ('TCP ' + $FrontPort) 'OK' 'Free for StarSEA.' }
        else { Add-CheckLocal ('TCP ' + $FrontPort) 'FAIL' 'Already in use.' }
    }

    if (Test-FirewallReady -PcIp $PcIp) { Add-CheckLocal 'Firewall' 'OK' 'LAN-only Private-profile rule found.' }
    else { Add-CheckLocal 'Firewall' 'WARN' 'Expected narrow Private-profile manager firewall rule was not found for this IP.' }

    $category = Get-NetworkCategoryForIp -Address $PcIp
    if ($category -eq 'Private') { Add-CheckLocal 'Windows network profile' 'OK' $category }
    else { Add-CheckLocal 'Windows network profile' 'WARN' ('Current category: ' + $category + '. The manager firewall rule is intentionally Private-only.') }

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
        Add-Log 'StarSEA relay is already running.'
        Update-Status
        return
    }

    Stop-Relay
    $checks = Get-PreflightChecks -PcIp $pcIp -RequirePortFree
    $fails = @($checks | Where-Object { $_.State -eq 'FAIL' })
    if ($fails.Count -gt 0) {
        throw ('Preflight failed:' + [Environment]::NewLine + (Format-Checks -Checks $fails))
    }
    foreach ($warning in @($checks | Where-Object { $_.State -eq 'WARN' })) {
        Add-Log ('WARNING: ' + $warning.Name + ' - ' + $warning.Detail)
    }

    $process = $null
    try {
        Add-Log 'Starting single-process StarSEA encrypted relay...'
        $args = 'run -c ' + (Quote-Argument $StarConfig)
        $process = Start-Process -FilePath $StarExe -ArgumentList $args -WorkingDirectory $Runtime -WindowStyle Hidden -PassThru
        Wait-ForRelayListener -ProcessId $process.Id -PcIp $pcIp
        $process.Refresh()
        if ($process.HasExited) { throw 'StarSEA exited immediately after startup.' }

        Write-JsonFile -Path $PidFile -Value ([ordered]@{
            starPid = $process.Id
            starStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
            starPath = $StarExe
            pcIp = $pcIp
            startedUtc = [DateTime]::UtcNow.ToString('o')
        })
        Add-Log ('Relay RUNNING: StarSEA PID ' + $process.Id + ' on ' + $pcIp + ':' + $FrontPort + '.')
        Add-Log 'Phone-to-PC packets are encrypted; only StarSEA-to-game-server BPSR payload is clear for compatible DPS meters to parse.'
    }
    catch {
        if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        throw
    }
    finally { Update-Status }
}

function Get-DiagnosticsText {
    $pcIp = ''
    try { $pcIp = Get-SelectedIp } catch { $pcIp = ([string]$script:cmbIp.Text).Trim() }
    $profileIp = Get-ProfilePcIp
    $runtimeVersion = Get-InstalledVersion
    $relayRunning = Get-RelayTrackedRunning
    $starCount = @(Get-Process -Name 'StarSEA' -ErrorAction SilentlyContinue).Count
    $legacyCount = @(Get-Process -Name 'BPSRMobileFront','BPSRRelayIngress' -ErrorAction SilentlyContinue).Count
    $listeners = @(Get-ListeningConnections -Port $FrontPort)
    $listenerText = if ($listeners.Count -eq 0) { 'none' } else { (($listeners | ForEach-Object { $_.LocalAddress + ':' + $_.LocalPort + ' pid=' + $_.OwningProcess }) -join '; ') }
    $firewall = if (-not [string]::IsNullOrWhiteSpace($pcIp) -and (Test-FirewallReady -PcIp $pcIp)) { 'OK' } else { 'not detected / mismatch' }
    $topology = 'NOT CHECKED'
    if (-not [string]::IsNullOrWhiteSpace($pcIp)) {
        try { Assert-Topology -PcIp $pcIp; $topology = 'OK - encrypted single-process / no sniff / one clear path' }
        catch { $topology = 'FAIL - ' + $_.Exception.Message }
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
Windows network category: $(if ($pcIp) { Get-NetworkCategoryForIp -Address $pcIp } else { 'unknown' })
Profile IP: $profileIp
Firewall: $firewall

Relay running: $relayRunning
StarSEA process count: $starCount
Legacy relay process count: $legacyCount
TCP $FrontPort listeners: $listenerText
Topology: $topology
Ingress transport: Shadowsocks $IngressMethod / TCP / no multiplex
Android protocol sniffing: DISABLED
BPSR relayed TCP ports: $($BpsrTcpPorts -join ', ')

Universal DPS meter target:
Process / executable: StarSEA
Physical adapter: $adapterText
Any compatible DPS meter may independently capture this StarSEA stream.
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

    # Gameplay hot path: once StarSEA is running, status polling must remain tiny.
    # Do not hash the runtime or enumerate adapters every timer tick while playing.
    if (Get-RelayTrackedRunning) {
        $script:lblRelayState.Text = 'Relay: RUNNING - StarSEA only'
        $script:lblRelayState.ForeColor = [System.Drawing.Color]::DarkGreen
        return
    }

    if (@(Get-Process -Name 'StarSEA','BPSRMobileFront','BPSRRelayIngress' -ErrorAction SilentlyContinue).Count -gt 0) {
        $script:lblRelayState.Text = 'Relay: FOREIGN / LEGACY PROCESS DETECTED'
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
    Ensure-TestedSingBox
    $credentials = Get-OrCreateCredentials
    Copy-Item -LiteralPath $SingBoxExe -Destination $StarExe -Force
    Write-RelayConfigs -PcIp $testIp -Credentials $credentials
    Validate-GeneratedConfigs -PcIp $testIp

    $text = (Get-Content -LiteralPath $AndroidConfig -Raw)
    if ($text -match '"action"\s*:\s*"sniff"') { throw 'Self-test found forbidden sniff action.' }
    if ($text -notmatch 'route_exclude_address') { throw 'Self-test found missing TUN relay-IP exclusion.' }
    Write-Host 'SELF-TEST PASS: configs parse, topology invariants pass, no sniff, encrypted single-process relay.'
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

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'BPSR Android DPSMeter Relay'
$form.Size = New-Object System.Drawing.Size(920, 760)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'BPSR Android DPSMeter Relay'
$title.Location = New-Object System.Drawing.Point(22, 16)
$title.Size = New-Object System.Drawing.Size(850, 31)
$title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Low-latency universal capture path: Android -> encrypted LAN tunnel -> StarSEA -> game server.'
$subtitle.Location = New-Object System.Drawing.Point(24, 50)
$subtitle.Size = New-Object System.Drawing.Size(850, 24)
$form.Controls.Add($subtitle)

$ipLabel = New-Object System.Windows.Forms.Label
$ipLabel.Text = 'PC LAN IPv4 (phone must be able to reach this address)'
$ipLabel.Location = New-Object System.Drawing.Point(24, 87)
$ipLabel.Size = New-Object System.Drawing.Size(340, 20)
$form.Controls.Add($ipLabel)

$script:cmbIp = New-Object System.Windows.Forms.ComboBox
$script:cmbIp.Location = New-Object System.Drawing.Point(27, 110)
$script:cmbIp.Size = New-Object System.Drawing.Size(260, 25)
$script:cmbIp.DropDownStyle = 'DropDown'
$form.Controls.Add($script:cmbIp)

$candidates = @(Get-LanIPv4Candidates)
$seen = @{}
foreach ($candidate in $candidates) {
    if (-not $seen.ContainsKey($candidate.IP)) {
        [void]$script:cmbIp.Items.Add($candidate.IP)
        $seen[$candidate.IP] = $true
    }
}
if ($script:cmbIp.Items.Count -gt 0) { $script:cmbIp.SelectedIndex = 0 }

$btnSetup = New-Object System.Windows.Forms.Button
$btnSetup.Text = '1. Setup / Repair'
$btnSetup.Location = New-Object System.Drawing.Point(305, 106)
$btnSetup.Size = New-Object System.Drawing.Size(145, 33)
$btnSetup.Add_Click({ try { Setup-Relay } catch { Show-FriendlyError -Title 'Setup / Repair failed' -Exception $_.Exception } })
$form.Controls.Add($btnSetup)

$btnFirewall = New-Object System.Windows.Forms.Button
$btnFirewall.Text = '2. Allow Firewall'
$btnFirewall.Location = New-Object System.Drawing.Point(463, 106)
$btnFirewall.Size = New-Object System.Drawing.Size(145, 33)
$btnFirewall.Add_Click({ try { Allow-Firewall } catch { Show-FriendlyError -Title 'Firewall setup failed' -Exception $_.Exception } })
$form.Controls.Add($btnFirewall)

$btnShare = New-Object System.Windows.Forms.Button
$btnShare.Text = '3. Share to Phone'
$btnShare.Location = New-Object System.Drawing.Point(27, 154)
$btnShare.Size = New-Object System.Drawing.Size(160, 33)
$btnShare.Add_Click({ try { Start-ProfileShare } catch { Show-FriendlyError -Title 'Could not share profile' -Exception $_.Exception } })
$form.Controls.Add($btnShare)

$btnQr = New-Object System.Windows.Forms.Button
$btnQr.Text = 'Show QR (optional)'
$btnQr.Location = New-Object System.Drawing.Point(198, 154)
$btnQr.Size = New-Object System.Drawing.Size(155, 33)
$btnQr.Add_Click({ try { Show-ShareQr } catch { Show-FriendlyError -Title 'Could not show QR' -Exception $_.Exception } })
$form.Controls.Add($btnQr)

$btnUrl = New-Object System.Windows.Forms.Button
$btnUrl.Text = 'Copy Phone URL'
$btnUrl.Location = New-Object System.Drawing.Point(364, 154)
$btnUrl.Size = New-Object System.Drawing.Size(145, 33)
$btnUrl.Add_Click({ try { Copy-ShareUrl } catch { Show-FriendlyError -Title 'Could not copy URL' -Exception $_.Exception } })
$form.Controls.Add($btnUrl)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = 'Open Profile Folder'
$btnFolder.Location = New-Object System.Drawing.Point(520, 154)
$btnFolder.Size = New-Object System.Drawing.Size(145, 33)
$btnFolder.Add_Click({ try { Open-ProfileFolder } catch { Show-FriendlyError -Title 'Could not open profile folder' -Exception $_.Exception } })
$form.Controls.Add($btnFolder)

$shareNote = New-Object System.Windows.Forms.Label
$shareNote.Text = 'Phone sharing is temporary, one-download/5-minute, and uses the relay port only while the gameplay relay is stopped.'
$shareNote.Location = New-Object System.Drawing.Point(27, 191)
$shareNote.Size = New-Object System.Drawing.Size(840, 22)
$form.Controls.Add($shareNote)

$zdpsBox = New-Object System.Windows.Forms.GroupBox
$zdpsBox.Text = '4. Compatible DPS meter - universal StarSEA target'
$zdpsBox.Location = New-Object System.Drawing.Point(27, 219)
$zdpsBox.Size = New-Object System.Drawing.Size(850, 105)
$form.Controls.Add($zdpsBox)

$zdpsText = New-Object System.Windows.Forms.Label
$zdpsText.Text = 'Configure your DPS meter to detect/capture StarSEA. If it uses a network device, select the physical Wi-Fi/Ethernet adapter.' + "`r`n" +
                 'ZDPS is only an example: Game Capture Preference = Custom | Custom BPSR Executable Name = StarSEA.'
$zdpsText.Location = New-Object System.Drawing.Point(14, 24)
$zdpsText.Size = New-Object System.Drawing.Size(820, 42)
$zdpsBox.Controls.Add($zdpsText)

$btnCopyZdps = New-Object System.Windows.Forms.Button
$btnCopyZdps.Text = 'Copy DPS Meter Notes'
$btnCopyZdps.Location = New-Object System.Drawing.Point(14, 68)
$btnCopyZdps.Size = New-Object System.Drawing.Size(180, 27)
$btnCopyZdps.Add_Click({ try { Copy-ZdpsSettings } catch { Show-FriendlyError -Title 'Clipboard error' -Exception $_.Exception } })
$zdpsBox.Controls.Add($btnCopyZdps)

$btnPreflight = New-Object System.Windows.Forms.Button
$btnPreflight.Text = '5. PREFLIGHT CHECK'
$btnPreflight.Location = New-Object System.Drawing.Point(27, 342)
$btnPreflight.Size = New-Object System.Drawing.Size(180, 42)
$btnPreflight.Add_Click({ try { Show-Preflight } catch { Show-FriendlyError -Title 'Preflight error' -Exception $_.Exception } })
$form.Controls.Add($btnPreflight)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '6. START RELAY'
$btnStart.Location = New-Object System.Drawing.Point(218, 342)
$btnStart.Size = New-Object System.Drawing.Size(180, 42)
$btnStart.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnStart.Add_Click({ try { Start-Relay } catch { Show-FriendlyError -Title 'Could not start relay' -Exception $_.Exception } })
$form.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'STOP RELAY'
$btnStop.Location = New-Object System.Drawing.Point(409, 342)
$btnStop.Size = New-Object System.Drawing.Size(135, 42)
$btnStop.Add_Click({ try { Stop-Relay } catch { Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception } })
$form.Controls.Add($btnStop)

$btnDiag = New-Object System.Windows.Forms.Button
$btnDiag.Text = 'Copy Diagnostics'
$btnDiag.Location = New-Object System.Drawing.Point(555, 342)
$btnDiag.Size = New-Object System.Drawing.Size(145, 42)
$btnDiag.Add_Click({ try { Copy-Diagnostics } catch { Show-FriendlyError -Title 'Diagnostics error' -Exception $_.Exception } })
$form.Controls.Add($btnDiag)

$btnRollback = New-Object System.Windows.Forms.Button
$btnRollback.Text = 'Restore Previous Runtime'
$btnRollback.Location = New-Object System.Drawing.Point(711, 342)
$btnRollback.Size = New-Object System.Drawing.Size(166, 42)
$btnRollback.Add_Click({ try { Restore-PreviousRuntime } catch { Show-FriendlyError -Title 'Runtime rollback failed' -Exception $_.Exception } })
$form.Controls.Add($btnRollback)

$script:lblRelayState = New-Object System.Windows.Forms.Label
$script:lblRelayState.Location = New-Object System.Drawing.Point(27, 398)
$script:lblRelayState.Size = New-Object System.Drawing.Size(840, 22)
$script:lblRelayState.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($script:lblRelayState)

$script:lblProfileState = New-Object System.Windows.Forms.Label
$script:lblProfileState.Location = New-Object System.Drawing.Point(27, 422)
$script:lblProfileState.Size = New-Object System.Drawing.Size(840, 22)
$form.Controls.Add($script:lblProfileState)

$script:lblRuntimeState = New-Object System.Windows.Forms.Label
$script:lblRuntimeState.Location = New-Object System.Drawing.Point(27, 446)
$script:lblRuntimeState.Size = New-Object System.Drawing.Size(840, 22)
$form.Controls.Add($script:lblRuntimeState)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = 'Status / log'
$logLabel.Location = New-Object System.Drawing.Point(24, 478)
$logLabel.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($logLabel)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Location = New-Object System.Drawing.Point(27, 500)
$script:txtLog.Size = New-Object System.Drawing.Size(850, 165)
$script:txtLog.Multiline = $true
$script:txtLog.ReadOnly = $true
$script:txtLog.ScrollBars = 'Vertical'
$script:txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($script:txtLog)

$note = New-Object System.Windows.Forms.Label
$note.Text = 'Closing the manager does not stop StarSEA. Use STOP RELAY when you actually want the relay stopped.'
$note.Location = New-Object System.Drawing.Point(27, 679)
$note.Size = New-Object System.Drawing.Size(840, 22)
$form.Controls.Add($note)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ Update-Status })
$timer.Start()

Update-Status
Add-Log ('Ready - manager ' + $ManagerVersion + '. Priority: latency -> single-count capture -> convenience.')
Add-Log 'Universal DPS target: StarSEA. The relay does not depend on a specific DPS meter.'
Add-Log ('Tested runtime is pinned to sing-box ' + $TestedSingBoxVersion + '; Setup does not blindly upgrade to an untested upstream release.')

[void]$form.ShowDialog()
$timer.Stop()
Stop-ProfileShare
