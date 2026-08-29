$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root = Split-Path -Parent $PSScriptRoot
$Runtime = Join-Path $Root '.runtime'
$ConfigDir = Join-Path $Runtime 'config'
$OutputDir = Join-Path $Root 'output'
$PidFile = Join-Path $Runtime 'pids.json'
$VersionFile = Join-Path $Runtime 'sing-box-version.txt'
$SingBoxExe = Join-Path $Runtime 'sing-box.exe'
$FrontExe = Join-Path $Runtime 'BPSRMobileFront.exe'
$StarExe = Join-Path $Runtime 'StarSEA.exe'
$FrontConfig = Join-Path $ConfigDir 'front-socks.json'
$RelayConfig = Join-Path $ConfigDir 'relay-hidden.json'
$AndroidConfig = Join-Path $OutputDir 'android-bpsr-relay.json'
$FirewallScript = Join-Path $Runtime 'allow-firewall.ps1'
$FrontPort = 10902
$RelayPort = 10903
$FirewallRuleName = 'BPSR Android DPSMeter Relay'

$script:txtLog = $null
$script:lblRelayState = $null
$script:lblProfileState = $null
$script:cmbIp = $null

function Ensure-Directories {
    foreach ($dir in @($Runtime, $ConfigDir, $OutputDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Add-Log {
    param([string]$Message)
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message
    if ($script:txtLog) {
        $script:txtLog.AppendText($line + [Environment]::NewLine)
        $script:txtLog.SelectionStart = $script:txtLog.TextLength
        $script:txtLog.ScrollToCaret()
    }
}

function Show-FriendlyError {
    param([string]$Title, [System.Exception]$Exception)
    Add-Log ('ERROR: ' + $Exception.Message)
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

function Get-SingBoxArchitecture {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($arch)) {
        $arch = $env:PROCESSOR_ARCHITECTURE
    }

    switch -Regex ($arch) {
        '^AMD64$' { return 'amd64' }
        '^ARM64$' { return 'arm64' }
        default { throw ('Unsupported Windows architecture: ' + $arch + '. Only x64 (amd64) and ARM64 are supported.') }
    }
}

function Get-LanIPv4Candidates {
    $items = @()
    try {
        $addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -ne '127.0.0.1' -and
                $_.IPAddress -notlike '169.254.*' -and
                $_.AddressState -ne 'Duplicate'
            }

        foreach ($entry in $addresses) {
            $score = 0
            if ($entry.InterfaceAlias -match 'Wi-?Fi|Ethernet') { $score += 20 }
            if ($entry.InterfaceAlias -match 'vEthernet|Virtual|VMware|VirtualBox|WSL|Loopback') { $score -= 50 }
            if ($entry.IPAddress -match '^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.') { $score += 10 }

            $items += [PSCustomObject]@{
                IP = $entry.IPAddress
                Interface = $entry.InterfaceAlias
                Score = $score
            }
        }
    }
    catch {
        Add-Log 'Could not enumerate adapters automatically. Type the PC LAN IPv4 manually.'
    }

    return @($items | Sort-Object Score -Descending)
}

function Test-IPv4Address {
    param([string]$Address)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Get-SelectedIp {
    $value = ([string]$script:cmbIp.Text).Trim()
    if (-not (Test-IPv4Address $value)) {
        throw 'Choose or type a valid PC LAN IPv4 address, for example 192.168.1.20.'
    }
    if ($value -eq '127.0.0.1' -or $value -like '169.254.*') {
        throw 'That address cannot be reached reliably by your phone. Choose the PC Wi-Fi/Ethernet LAN IPv4 instead.'
    }
    return $value
}

function Invoke-DownloadFile {
    param([string]$Url, [string]$Destination)
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -Headers @{ 'User-Agent' = 'BPSR-Android-DPSMeter-Relay' }
}

function Ensure-LatestSingBox {
    Ensure-Directories
    $arch = Get-SingBoxArchitecture
    Add-Log ('Checking latest official sing-box for Windows/' + $arch + '...')

    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/SagerNet/sing-box/releases/latest' -Headers @{ 'User-Agent' = 'BPSR-Android-DPSMeter-Relay' }
    if (-not $release -or -not $release.tag_name) {
        throw 'GitHub did not return a valid latest sing-box release.'
    }

    $pattern = '^sing-box-.*-windows-' + [regex]::Escape($arch) + '\.zip$'
    $zipAsset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $zipAsset) {
        throw ('Could not find the official Windows/' + $arch + ' sing-box ZIP in release ' + $release.tag_name + '.')
    }

    $installedVersion = ''
    if (Test-Path $VersionFile) {
        $installedVersion = (Get-Content $VersionFile -Raw).Trim()
    }

    if ((Test-Path $SingBoxExe) -and $installedVersion -eq [string]$release.tag_name) {
        Add-Log ('sing-box ' + $installedVersion + ' is already installed.')
        return
    }

    $downloadDir = Join-Path $Runtime 'download-temp'
    if (Test-Path $downloadDir) { Remove-Item $downloadDir -Recurse -Force }
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    try {
        $zipPath = Join-Path $downloadDir $zipAsset.name
        Add-Log ('Downloading ' + $zipAsset.name + '...')
        Invoke-DownloadFile -Url $zipAsset.browser_download_url -Destination $zipPath

        $checksumAsset = $release.assets |
            Where-Object { $_.name -match '(?i)(sha256|checksum)' } |
            Select-Object -First 1

        if ($checksumAsset) {
            try {
                $checksumPath = Join-Path $downloadDir $checksumAsset.name
                Invoke-DownloadFile -Url $checksumAsset.browser_download_url -Destination $checksumPath
                $expectedHash = $null

                foreach ($line in Get-Content $checksumPath) {
                    if ($line -match '(?i)^\s*([a-f0-9]{64})\s+\*?(.+?)\s*$') {
                        $listedName = [System.IO.Path]::GetFileName($Matches[2].Trim())
                        if ($listedName -eq $zipAsset.name) {
                            $expectedHash = $Matches[1].ToLowerInvariant()
                            break
                        }
                    }
                }

                if ($expectedHash) {
                    $actualHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($actualHash -ne $expectedHash) {
                        throw 'SHA256 verification FAILED. The downloaded sing-box archive will not be used.'
                    }
                    Add-Log 'SHA256 verification passed.'
                }
                else {
                    Add-Log 'Warning: checksum file found, but it did not contain a matching hash for this ZIP.'
                }
            }
            catch {
                if ($_.Exception.Message -like 'SHA256 verification FAILED*') { throw }
                Add-Log ('Warning: checksum verification was unavailable: ' + $_.Exception.Message)
            }
        }
        else {
            Add-Log 'Warning: no checksum asset was published with this release; using the official GitHub release download.'
        }

        $extractDir = Join-Path $downloadDir 'extracted'
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        $foundExe = Get-ChildItem -Path $extractDir -Filter 'sing-box.exe' -File -Recurse | Select-Object -First 1
        if (-not $foundExe) { throw 'The downloaded archive did not contain sing-box.exe.' }

        Copy-Item -Path $foundExe.FullName -Destination $SingBoxExe -Force
        ([string]$release.tag_name) | Set-Content -Path $VersionFile -Encoding ASCII
        Add-Log ('Installed official sing-box ' + $release.tag_name + '.')
    }
    finally {
        if (Test-Path $downloadDir) {
            Remove-Item $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-RelayConfigs {
    param([string]$PcIp)
    Ensure-Directories

    $front = [ordered]@{
        log = [ordered]@{ level = 'warn' }
        inbounds = @(
            [ordered]@{ type = 'socks'; tag = 'phone-in'; listen = '0.0.0.0'; listen_port = $FrontPort }
        )
        outbounds = @(
            [ordered]@{ type = 'socks'; tag = 'to-zdps'; server = '127.0.0.1'; server_port = $RelayPort; version = '5' }
        )
        route = [ordered]@{ final = 'to-zdps' }
    }

    $relay = [ordered]@{
        log = [ordered]@{ level = 'warn' }
        inbounds = @(
            [ordered]@{ type = 'socks'; tag = 'zdps-in'; listen = '127.0.0.1'; listen_port = $RelayPort }
        )
        outbounds = @(
            [ordered]@{ type = 'direct'; tag = 'direct' }
        )
        route = [ordered]@{ final = 'direct' }
    }

    $android = [ordered]@{
        log = [ordered]@{ disabled = $true; level = 'warn' }
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
                stack = 'system'
            }
        )
        outbounds = @(
            [ordered]@{ type = 'socks'; tag = 'bpsr-pc'; server = $PcIp; server_port = $FrontPort; version = '5' },
            [ordered]@{ type = 'direct'; tag = 'direct' }
        )
        route = [ordered]@{
            rules = @(
                [ordered]@{ action = 'sniff' },
                [ordered]@{ protocol = 'dns'; action = 'hijack-dns' },
                [ordered]@{
                    network = 'tcp'
                    port = @(15000, 16000, 17000, 18000, 20000, 20001, 21000)
                    action = 'route'
                    outbound = 'bpsr-pc'
                }
            )
            final = 'direct'
            auto_detect_interface = $true
            default_domain_resolver = 'local'
        }
    }

    $front | ConvertTo-Json -Depth 20 | Set-Content -Path $FrontConfig -Encoding UTF8
    $relay | ConvertTo-Json -Depth 20 | Set-Content -Path $RelayConfig -Encoding UTF8
    $android | ConvertTo-Json -Depth 20 | Set-Content -Path $AndroidConfig -Encoding UTF8

    @"
BPSR Android DPSMeter Relay

Import android-bpsr-relay.json into SFA on the Android phone.
PC LAN IPv4 used by this profile: $PcIp
PC relay port: $FrontPort

ZDPS / DPS meter:
  Capture Process: StarSEA
  Listen IP:       127.0.0.1
  Listen Port:     $RelayPort

IMPORTANT: Capture StarSEA only. Do NOT capture BPSRMobileFront.
"@ | Set-Content -Path (Join-Path $OutputDir 'README-IMPORT.txt') -Encoding UTF8

    Add-Log ('Generated Android SFA profile for PC ' + $PcIp + '.')
}

function Get-RecordedPids {
    if (-not (Test-Path $PidFile)) { return $null }
    try {
        return Get-Content $PidFile -Raw | ConvertFrom-Json
    }
    catch {
        Add-Log 'Warning: PID state file is unreadable.'
        return $null
    }
}

function Test-ExpectedProcess {
    param([int]$ProcessId, [string]$ExpectedName)
    if ($ProcessId -le 0) { return $false }
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        return $proc.ProcessName -eq $ExpectedName
    }
    catch {
        return $false
    }
}

function Stop-Relay {
    $pids = Get-RecordedPids
    if (-not $pids) {
        Add-Log 'No recorded relay processes to stop.'
        Update-Status
        return
    }

    $targets = @(
        [PSCustomObject]@{ ProcessId = [int]$pids.frontPid; Name = 'BPSRMobileFront' },
        [PSCustomObject]@{ ProcessId = [int]$pids.starPid; Name = 'StarSEA' }
    )

    foreach ($target in $targets) {
        if (Test-ExpectedProcess -ProcessId $target.ProcessId -ExpectedName $target.Name) {
            try {
                Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop
                Add-Log ('Stopped ' + $target.Name + ' (PID ' + $target.ProcessId + ').')
            }
            catch {
                Add-Log ('Warning: could not stop ' + $target.Name + ': ' + $_.Exception.Message)
            }
        }
    }

    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    Update-Status
}

function Assert-NoUntrackedRelayProcesses {
    $pids = Get-RecordedPids
    $trackedFront = 0
    $trackedStar = 0
    if ($pids) {
        $trackedFront = [int]$pids.frontPid
        $trackedStar = [int]$pids.starPid
    }

    $foreign = @()
    foreach ($name in @('BPSRMobileFront', 'StarSEA')) {
        foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $isTracked = ($name -eq 'BPSRMobileFront' -and $proc.Id -eq $trackedFront) -or
                         ($name -eq 'StarSEA' -and $proc.Id -eq $trackedStar)
            if (-not $isTracked) { $foreign += ($name + ' (PID ' + $proc.Id + ')') }
        }
    }

    if ($foreign.Count -gt 0) {
        throw ('Existing untracked relay process detected: ' + ($foreign -join ', ') + '. Close it manually first. The manager will not kill untracked processes automatically.')
    }
}

function Start-Relay {
    Ensure-Directories
    if (-not (Test-Path $FrontExe) -or -not (Test-Path $StarExe) -or -not (Test-Path $FrontConfig) -or -not (Test-Path $RelayConfig)) {
        throw 'Relay files are not ready. Click Setup / Repair first.'
    }

    Assert-NoUntrackedRelayProcesses
    Stop-Relay

    $star = $null
    $front = $null
    try {
        Add-Log 'Starting StarSEA and BPSRMobileFront hidden in the background...'

        $starArgs = 'run -c ' + (Quote-Argument $RelayConfig)
        $star = Start-Process -FilePath $StarExe -ArgumentList $starArgs -WorkingDirectory $Runtime -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 450
        $star.Refresh()
        if ($star.HasExited) { throw 'StarSEA exited immediately. Run Setup / Repair and try again.' }

        $frontArgs = 'run -c ' + (Quote-Argument $FrontConfig)
        $front = Start-Process -FilePath $FrontExe -ArgumentList $frontArgs -WorkingDirectory $Runtime -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 450
        $front.Refresh()
        if ($front.HasExited) { throw 'BPSRMobileFront exited immediately. Port 10902 may already be in use.' }

        [ordered]@{
            frontPid = $front.Id
            starPid = $star.Id
            started = (Get-Date).ToString('o')
        } | ConvertTo-Json | Set-Content -Path $PidFile -Encoding UTF8

        Add-Log ('Relay running. BPSRMobileFront PID ' + $front.Id + ', StarSEA PID ' + $star.Id + '.')
    }
    catch {
        if ($front) { Stop-Process -Id $front.Id -Force -ErrorAction SilentlyContinue }
        if ($star) { Stop-Process -Id $star.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        Update-Status
    }
}

function Setup-Relay {
    $pcIp = Get-SelectedIp
    Add-Log ('Setup / Repair started for PC LAN IP ' + $pcIp + '.')

    Stop-Relay
    Assert-NoUntrackedRelayProcesses
    Ensure-LatestSingBox

    Copy-Item -Path $SingBoxExe -Destination $FrontExe -Force
    Copy-Item -Path $SingBoxExe -Destination $StarExe -Force
    Write-RelayConfigs -PcIp $pcIp

    Add-Log 'Setup / Repair complete.'
    Add-Log 'Next: firewall -> import Android profile -> ZDPS StarSEA -> Start Relay.'
    Update-Status
}

function Allow-Firewall {
    Ensure-Directories
    @"
`$ErrorActionPreference = 'Stop'
`$display = '$FirewallRuleName'
Get-NetFirewallRule -DisplayName `$display -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName `$display -Direction Inbound -Action Allow -Protocol TCP -LocalPort $FrontPort -Profile Private | Out-Null
"@ | Set-Content -Path $FirewallScript -Encoding UTF8

    Add-Log 'Requesting Administrator permission for the Private-network firewall rule...'
    $fwArgs = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Argument $FirewallScript)
    $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList $fwArgs
    if ($proc.ExitCode -ne 0) {
        throw ('Firewall setup did not complete successfully (exit code ' + $proc.ExitCode + ').')
    }
    Add-Log ('Firewall ready: inbound TCP ' + $FrontPort + ' allowed on Private networks only.')
}

function Open-ProfileFolder {
    Ensure-Directories
    Start-Process -FilePath 'explorer.exe' -ArgumentList (Quote-Argument $OutputDir) | Out-Null
}

function Copy-ZdpsSettings {
    $text = 'Capture Process: StarSEA' + "`r`n" + 'Listen IP: 127.0.0.1' + "`r`n" + ('Listen Port: ' + $RelayPort)
    [System.Windows.Forms.Clipboard]::SetText($text)
    Add-Log 'Copied ZDPS settings to clipboard.'
}

function Test-TrackedRunning {
    param([string]$Property, [string]$ExpectedName)
    $pids = Get-RecordedPids
    if (-not $pids) { return $false }

    $processId = 0
    try { $processId = [int]$pids.$Property } catch { return $false }
    return Test-ExpectedProcess -ProcessId $processId -ExpectedName $ExpectedName
}

function Update-Status {
    if (-not $script:lblRelayState) { return }

    $frontRunning = Test-TrackedRunning -Property 'frontPid' -ExpectedName 'BPSRMobileFront'
    $starRunning = Test-TrackedRunning -Property 'starPid' -ExpectedName 'StarSEA'

    if ($frontRunning -and $starRunning) {
        $script:lblRelayState.Text = 'Relay: RUNNING'
        $script:lblRelayState.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    elseif ($frontRunning -or $starRunning) {
        $script:lblRelayState.Text = 'Relay: PARTIAL / CHECK'
        $script:lblRelayState.ForeColor = [System.Drawing.Color]::DarkOrange
    }
    else {
        $script:lblRelayState.Text = 'Relay: STOPPED'
        $script:lblRelayState.ForeColor = [System.Drawing.Color]::Firebrick
    }

    if (Test-Path $AndroidConfig) {
        $script:lblProfileState.Text = 'Android profile: READY'
        $script:lblProfileState.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    else {
        $script:lblProfileState.Text = 'Android profile: NOT GENERATED'
        $script:lblProfileState.ForeColor = [System.Drawing.Color]::Firebrick
    }
}

Ensure-Directories

$form = New-Object System.Windows.Forms.Form
$form.Text = 'BPSR Android DPSMeter Relay'
$form.Size = New-Object System.Drawing.Size(780, 650)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'BPSR Android DPSMeter Relay'
$title.Location = New-Object System.Drawing.Point(22, 18)
$title.Size = New-Object System.Drawing.Size(700, 30)
$title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Phone traffic -> PC relay -> StarSEA -> game server. ZDPS captures StarSEA only.'
$subtitle.Location = New-Object System.Drawing.Point(24, 52)
$subtitle.Size = New-Object System.Drawing.Size(700, 22)
$form.Controls.Add($subtitle)

$ipLabel = New-Object System.Windows.Forms.Label
$ipLabel.Text = '1. PC LAN IPv4 (same Wi-Fi/LAN as phone)'
$ipLabel.Location = New-Object System.Drawing.Point(24, 91)
$ipLabel.Size = New-Object System.Drawing.Size(300, 22)
$form.Controls.Add($ipLabel)

$script:cmbIp = New-Object System.Windows.Forms.ComboBox
$script:cmbIp.Location = New-Object System.Drawing.Point(27, 116)
$script:cmbIp.Size = New-Object System.Drawing.Size(300, 25)
$script:cmbIp.DropDownStyle = 'DropDown'
$form.Controls.Add($script:cmbIp)

$candidates = @(Get-LanIPv4Candidates)
$seenIps = @{}
foreach ($candidate in $candidates) {
    if (-not $seenIps.ContainsKey($candidate.IP)) {
        [void]$script:cmbIp.Items.Add($candidate.IP)
        $seenIps[$candidate.IP] = $true
    }
}
if ($script:cmbIp.Items.Count -gt 0) { $script:cmbIp.SelectedIndex = 0 }

$btnSetup = New-Object System.Windows.Forms.Button
$btnSetup.Text = 'Setup / Repair'
$btnSetup.Location = New-Object System.Drawing.Point(345, 113)
$btnSetup.Size = New-Object System.Drawing.Size(145, 31)
$btnSetup.Add_Click({
    try { Setup-Relay }
    catch { Show-FriendlyError -Title 'Setup / Repair failed' -Exception $_.Exception }
})
$form.Controls.Add($btnSetup)

$btnFirewall = New-Object System.Windows.Forms.Button
$btnFirewall.Text = '2. Allow Phone Through Firewall'
$btnFirewall.Location = New-Object System.Drawing.Point(27, 160)
$btnFirewall.Size = New-Object System.Drawing.Size(220, 33)
$btnFirewall.Add_Click({
    try { Allow-Firewall }
    catch { Show-FriendlyError -Title 'Firewall setup failed' -Exception $_.Exception }
})
$form.Controls.Add($btnFirewall)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = '3. Open Android Profile Folder'
$btnFolder.Location = New-Object System.Drawing.Point(260, 160)
$btnFolder.Size = New-Object System.Drawing.Size(220, 33)
$btnFolder.Add_Click({
    try { Open-ProfileFolder }
    catch { Show-FriendlyError -Title 'Could not open profile folder' -Exception $_.Exception }
})
$form.Controls.Add($btnFolder)

$zdpsBox = New-Object System.Windows.Forms.GroupBox
$zdpsBox.Text = '4. ZDPS / DPS meter settings'
$zdpsBox.Location = New-Object System.Drawing.Point(27, 211)
$zdpsBox.Size = New-Object System.Drawing.Size(705, 100)
$form.Controls.Add($zdpsBox)

$zdpsText = New-Object System.Windows.Forms.Label
$zdpsText.Text = 'Capture Process: StarSEA     |     Listen IP: 127.0.0.1     |     Listen Port: 10903' + "`r`n" + 'IMPORTANT: Do NOT capture BPSRMobileFront or DPS may be counted twice.'
$zdpsText.Location = New-Object System.Drawing.Point(14, 24)
$zdpsText.Size = New-Object System.Drawing.Size(675, 42)
$zdpsBox.Controls.Add($zdpsText)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = 'Copy ZDPS Settings'
$btnCopy.Location = New-Object System.Drawing.Point(14, 65)
$btnCopy.Size = New-Object System.Drawing.Size(165, 27)
$btnCopy.Add_Click({
    try { Copy-ZdpsSettings }
    catch { Show-FriendlyError -Title 'Clipboard error' -Exception $_.Exception }
})
$zdpsBox.Controls.Add($btnCopy)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '5. START RELAY'
$btnStart.Location = New-Object System.Drawing.Point(27, 328)
$btnStart.Size = New-Object System.Drawing.Size(220, 45)
$btnStart.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnStart.Add_Click({
    try { Start-Relay }
    catch { Show-FriendlyError -Title 'Could not start relay' -Exception $_.Exception }
})
$form.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'STOP RELAY'
$btnStop.Location = New-Object System.Drawing.Point(260, 328)
$btnStop.Size = New-Object System.Drawing.Size(150, 45)
$btnStop.Add_Click({
    try { Stop-Relay }
    catch { Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception }
})
$form.Controls.Add($btnStop)

$script:lblRelayState = New-Object System.Windows.Forms.Label
$script:lblRelayState.Location = New-Object System.Drawing.Point(437, 328)
$script:lblRelayState.Size = New-Object System.Drawing.Size(280, 22)
$script:lblRelayState.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($script:lblRelayState)

$script:lblProfileState = New-Object System.Windows.Forms.Label
$script:lblProfileState.Location = New-Object System.Drawing.Point(437, 352)
$script:lblProfileState.Size = New-Object System.Drawing.Size(280, 22)
$form.Controls.Add($script:lblProfileState)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = 'Status / log'
$logLabel.Location = New-Object System.Drawing.Point(24, 393)
$logLabel.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($logLabel)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Location = New-Object System.Drawing.Point(27, 416)
$script:txtLog.Size = New-Object System.Drawing.Size(705, 145)
$script:txtLog.Multiline = $true
$script:txtLog.ReadOnly = $true
$script:txtLog.ScrollBars = 'Vertical'
$script:txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($script:txtLog)

$note = New-Object System.Windows.Forms.Label
$note.Text = 'Closing this manager does NOT stop the relay. Use STOP RELAY when you want to stop it.'
$note.Location = New-Object System.Drawing.Point(27, 574)
$note.Size = New-Object System.Drawing.Size(705, 22)
$form.Controls.Add($note)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Status })
$timer.Start()

Update-Status
Add-Log 'Ready. First time: Setup / Repair -> Firewall -> import Android profile -> ZDPS StarSEA -> Start Relay.'

[void]$form.ShowDialog()
$timer.Stop()
