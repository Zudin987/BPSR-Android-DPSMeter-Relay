$ErrorActionPreference = 'Stop'

$managerPath = Join-Path $PSScriptRoot 'BPSRRelayManager.ps1'
$uiPath = Join-Path $PSScriptRoot 'ManagerUi.ps1'

function Replace-Literal {
    param([ref]$Text, [string]$Old, [string]$New, [string]$Label)
    $first = $Text.Value.IndexOf($Old, [System.StringComparison]::Ordinal)
    if ($first -lt 0) { throw ($Label + ' old text not found.') }
    $second = $Text.Value.IndexOf($Old, ($first + $Old.Length), [System.StringComparison]::Ordinal)
    if ($second -ge 0) { throw ($Label + ' old text appears more than once.') }
    $Text.Value = $Text.Value.Substring(0, $first) + $New + $Text.Value.Substring($first + $Old.Length)
}

function Replace-FunctionBlock {
    param([ref]$Text, [string]$Name, [string]$NextName, [string]$NewBlock)
    $startNeedle = 'function ' + $Name + ' {'
    $endNeedle = 'function ' + $NextName + ' {'
    $start = $Text.Value.IndexOf($startNeedle, [System.StringComparison]::Ordinal)
    if ($start -lt 0) { throw ('Function ' + $Name + ' was not found.') }
    $secondStart = $Text.Value.IndexOf($startNeedle, ($start + $startNeedle.Length), [System.StringComparison]::Ordinal)
    if ($secondStart -ge 0) { throw ('Function ' + $Name + ' appears more than once.') }
    $end = $Text.Value.IndexOf($endNeedle, ($start + $startNeedle.Length), [System.StringComparison]::Ordinal)
    if ($end -le $start) { throw ('Function boundary ' + $Name + ' -> ' + $NextName + ' was not found.') }
    $Text.Value = $Text.Value.Substring(0, $start) + $NewBlock.TrimEnd() + "`r`n`r`n" + $Text.Value.Substring($end)
}

$manager = Get-Content -LiteralPath $managerPath -Raw
$m = [ref]$manager
Replace-Literal $m '$ManagerVersion = ''1.0.0''' '$ManagerVersion = ''1.0.1''' 'manager version'
Replace-Literal $m '$ShareLifetimeSeconds = 300' "$([char]36)ShareLifetimeSeconds = 300`r`n$([char]36)MaxLogBytes = 2097152" 'log limit constant'

$addLog = @'
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
'@
Replace-FunctionBlock $m 'Add-Log' 'Show-FriendlyError' $addLog

$getFreeInternal = @'
function Get-FreeInternalPort {
    foreach ($candidatePort in $InternalPortStart..$InternalPortEnd) {
        if ((Get-ListeningConnections -Port $candidatePort).Count -eq 0 -and
            (Get-ListeningUdpEndpoints -Port $candidatePort).Count -eq 0) {
            return [int]$candidatePort
        }
    }
    throw ('Could not find a free TCP+UDP localhost bridge port between ' + $InternalPortStart + ' and ' + $InternalPortEnd + '.')
}
'@
Replace-FunctionBlock $m 'Get-FreeInternalPort' 'Write-RelayConfigs' $getFreeInternal

$validateBlock = @'
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
'@
Replace-FunctionBlock $m 'Validate-GeneratedConfigs' 'Get-RecordedPids' $validateBlock

$foreignBlock = @'
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
'@
Replace-FunctionBlock $m 'Get-ForeignRelayProcesses' 'Assert-NoForeignRelayProcesses' $foreignBlock

$listenerBlock = @'
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
'@
Replace-FunctionBlock $m 'Get-ListeningConnections' 'Wait-ForProcessListener' $listenerBlock

$profileShare = @'
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
'@
Replace-FunctionBlock $m 'Start-ProfileShare' 'Get-ProfileDownloadUrl' $profileShare

$oldPortPreflight = @'
    if ($RequirePortFree) {
        $listeners = @(Get-ListeningConnections -Port $FrontPort)
        if ($listeners.Count -eq 0) {
            Add-CheckLocal ('TCP ' + $FrontPort) 'OK' 'Free for BPSRMobileFront.'
        }
        else {
            Add-CheckLocal ('TCP ' + $FrontPort) 'FAIL' 'Already in use.'
        }
    }
'@
$newPortPreflight = @'
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
'@
Replace-Literal $m $oldPortPreflight $newPortPreflight 'TCP+UDP preflight'

$oldStart = @'
    Stop-Relay
    $checks = Get-PreflightChecks -PcIp $pcIp -RequirePortFree
'@
$newStart = @'
    Stop-Relay
    [void](Ensure-InternalBridgePortAvailable -PcIp $pcIp)
    $checks = Get-PreflightChecks -PcIp $pcIp -RequirePortFree
'@
Replace-Literal $m $oldStart $newStart 'refresh stale internal port before start'
Replace-Literal $m "Add-Log 'v1.0.0 two-stage relay is already running.'" "Add-Log 'v1.0.1 two-stage relay is already running.'" 'running log version'
Replace-Literal $m 'Setup / Repair complete. v1.0.0 now matches' 'Setup / Repair complete. v1.0.1 keeps' 'setup version log'
Replace-Literal $m 'IMPORTANT: delete/disable the RC.14 SFA profile and import the newly generated v1.0.0 profile.' 'If upgrading from an older test build, remove its old SFA profile and import the newly generated v1.0.1 profile.' 'setup old profile log'
Replace-Literal $m 'Phone-to-PC encryption: DISABLED in v1.0.0 compatibility mode' 'Phone-to-PC encryption: DISABLED in v1.0.1 compatibility mode' 'diagnostic version'
Replace-Literal $m "Add-CheckLocal 'Android profile' 'OK' ('v1.0.0 v4-compatible profile matches ' + $PcIp)" "Add-CheckLocal 'Android profile' 'OK' ('v1.0.1 v4-compatible profile matches ' + $PcIp)" 'preflight profile version'
Replace-Literal $m "Add-CheckLocal 'Android profile' 'FAIL' 'v1.0.0 profile is not generated. Click Prepare Relay, then import the new profile into SFA.'" "Add-CheckLocal 'Android profile' 'FAIL' 'v1.0.1 profile is not generated. Click Prepare Relay, then import the new profile into SFA.'" 'preflight profile missing version'
Replace-Literal $m 'IMPORTANT FOR v1.0.0:' 'IMPORTANT FOR v1.0.1:' 'import note version'
Replace-Literal $m 'Delete/disable the RC.14 SFA profile and import this newly generated profile.' 'If upgrading from an older test build, remove its old BPSR Relay profile and import this newly generated profile.' 'import note old profile'
Replace-Literal $m 'v1.0.0 restores the original Clean v4 routing shape for compatibility.' 'v1.0.1 keeps the field-tested Clean v4 routing shape unchanged.' 'import note topology'
Replace-Literal $m "Add-Log ('Generated v4-compatible Android SFA profile for PC ' + $PcIp + '. Re-import is required when upgrading from RC.14.')" "Add-Log ('Generated v4-compatible Android SFA profile for PC ' + $PcIp + '. Re-import is required only when the profile/IP changes or when upgrading from an incompatible test profile.')" 'profile generated log'

$manager = $m.Value
[System.IO.File]::WriteAllText($managerPath, $manager, (New-Object System.Text.UTF8Encoding($false)))

$ui = Get-Content -LiteralPath $uiPath -Raw
$u = [ref]$ui
$closeOld = @'
function Close-OldRelayPrompt {
    $items = @(Get-ForeignRelayProcesses)
    if ($items.Count -eq 0) { return $true }

    $summary = (@($items | ForEach-Object { $_.Name + '.exe (PID ' + $_.Id + ')' }) -join ', ')
    $message = "Old relay found:`r`n`r`n$summary`r`n`r`nThis is usually a relay left running by an older build.`r`n`r`nClose it now?"
    $choice = [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Old relay found',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }

    foreach ($item in $items) {
        try {
            if ([string]::IsNullOrWhiteSpace([string]$item.StartUtc)) {
                Add-Log ('Skipped old relay PID ' + $item.Id + ' because its start-time identity could not be recorded. Refresh and try again.')
                continue
            }
            $current = Get-Process -Id ([int]$item.Id) -ErrorAction Stop
            if ([string]$current.ProcessName -ne [string]$item.Name) { continue }
            $expectedStart = [DateTime]::Parse([string]$item.StartUtc).ToUniversalTime()
            $actualStart = $current.StartTime.ToUniversalTime()
            if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) {
                Add-Log ('Skipped PID ' + $item.Id + ' because the process identity changed before cleanup.')
                continue
            }
            Stop-Process -Id ([int]$item.Id) -Force -ErrorAction Stop
            Add-Log ('Closed old relay ' + $item.Name + ' (PID ' + $item.Id + ') after PID/name/start-time verification and user confirmation.')
        }
        catch {
            Add-Log ('Could not close old relay PID ' + $item.Id + ': ' + $_.Exception.Message)
        }
    }

    Start-Sleep -Milliseconds 150
    $remaining = @(Get-ForeignRelayProcesses)
    Update-Status
    if ($remaining.Count -gt 0) {
        $left = (@($remaining | ForEach-Object { $_.Name + '.exe (PID ' + $_.Id + ')' }) -join ', ')
        [System.Windows.Forms.MessageBox]::Show(
            "Windows could not safely close:`r`n`r`n$left`r`n`r`nTry Prepare Relay again, or restart your PC.",
            'Could not close old relay',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $false
    }
    return $true
}
'@
Replace-FunctionBlock $u 'Close-OldRelayPrompt' 'Invoke-PrepareRelay' $closeOld

Replace-Literal $u "if ($names -match 'Duplicate relay|TCP')" "if ($names -match 'Duplicate relay|TCP|UDP')" 'friendly preflight port wording'
Replace-Literal $u 'if ($script:btnShare)       { $script:btnShare.Enabled = (-not $Running) -and $ProfileReady -and (-not $ForeignRelay) }' 'if ($script:btnShare)       { $script:btnShare.Enabled = (-not $Running) -and $ProfileReady -and $FirewallReady -and (-not $ForeignRelay) }' 'phone setup firewall button gate'
Replace-Literal $u 'if ($script:btnPreflight)   { $script:btnPreflight.Enabled = (-not $Running) -and $RuntimeReady -and $ProfileReady -and (-not $ForeignRelay) }' 'if ($script:btnPreflight)   { $script:btnPreflight.Enabled = -not $Running }' 'run check enablement'

$oldSelection = 'if ($script:cmbIp.Items.Count -gt 0) { $script:cmbIp.SelectedIndex = 0 }'
$newSelection = @'
$existingProfileIp = Get-ProfilePcIp
if (-not [string]::IsNullOrWhiteSpace($existingProfileIp) -and $script:cmbIp.Items.Contains($existingProfileIp) -and (Test-LocalIpAssigned $existingProfileIp)) {
    $script:cmbIp.SelectedItem = $existingProfileIp
}
elseif ($script:cmbIp.Items.Count -gt 0) { $script:cmbIp.SelectedIndex = 0 }
'@
Replace-Literal $u $oldSelection $newSelection.TrimEnd() 'prefer existing working profile IP'
Replace-Literal $u 'Create v1.0.0 compatibility profile. Do this first.' 'Create/repair the field-tested compatibility profile. Do this first.' 'prepare helper wording'
Replace-Literal $u 'Remove old RC.14 profile, then scan the new v1.0.0 QR.' 'First setup or profile refresh: scan the current QR in SFA.' 'android setup helper wording'

$oldShareHandler = @'
$script:btnShare.Add_Click({
    try { Start-ProfileShare; Show-ShareQr }
    catch { Show-FriendlyError -Title 'Could not start phone setup' -Exception $_.Exception }
})
'@
$newShareHandler = @'
$script:btnShare.Add_Click({
    try { Start-ProfileShare }
    catch {
        Show-FriendlyError -Title 'Could not start phone setup' -Exception $_.Exception
        return
    }
    try { Show-ShareQr }
    catch {
        Add-Log ('WARNING: phone setup is running, but the QR could not open: ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show(
            "Phone setup is running, but the QR could not open.`r`n`r`nClick Copy SFA Link and send/open that link on your phone.",
            'Phone setup started',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
})
'@
Replace-Literal $u $oldShareHandler $newShareHandler 'separate QR failure from phone setup'
Replace-Literal $u 'After the first setup:`r`nOpen app  ->  Start Relay  ->  Play' 'After the first setup:`r`nPC Start Relay  ->  Phone Start SFA  ->  Open BPSR' 'daily use includes SFA'
Replace-Literal $u '5. Delete/disable old RC.14 profile.' '5. If an old test profile exists, remove it.' 'help old profile wording'
Replace-Literal $u 'Phone issue: re-import v1.0.0 QR.' 'Phone issue: run Phone Setup and re-import the current QR.' 'help phone wording'

$ui = $u.Value
[System.IO.File]::WriteAllText($uiPath, $ui, (New-Object System.Text.UTF8Encoding($false)))

foreach ($path in @($managerPath, $uiPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Error ($path + ': ' + $_.Message) }
        throw 'PowerShell parse failed after hardening patch.'
    }
}
Write-Host 'v1.0.1 runtime/UI hardening patch applied successfully.'
