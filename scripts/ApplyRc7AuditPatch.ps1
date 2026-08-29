$ErrorActionPreference = 'Stop'

function Replace-Exact {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New
    )
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Old)) {
        throw ('Expected patch target was not found in ' + $Path + ': ' + ($Old.Substring(0, [Math]::Min(100, $Old.Length))))
    }
    $text = $text.Replace($Old, $New)
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path), $text, (New-Object System.Text.UTF8Encoding($false)))
}

$manager = 'scripts\BPSRRelayManager.ps1'
$readme = 'README.md'
$validate = '.github\workflows\validate.yml'

Replace-Exact $manager "`$ManagerVersion = '1.0.0-rc.6'" "`$ManagerVersion = '1.0.0-rc.7'"

Replace-Exact $manager @'
$script:shareProcess = $null
$script:shareUrl = ''
'@ @'
$script:shareProcess = $null
$script:shareUrl = ''
$script:trackedStarPid = 0
$script:trackedStarStartUtc = ''
$script:trackedRelayIdentityLoaded = $false
'@

Replace-Exact $manager @'
                auto_route = $true
                strict_route = $true
                route_exclude_address = @($PcIp + '/32')
'@ @'
                auto_route = $true
                route_exclude_address = @($PcIp + '/32')
'@

Replace-Exact $manager @'
    if (-not (@($androidTun.route_exclude_address) -contains ($PcIp + '/32'))) {
        throw 'Topology check failed: the PC relay IP must be excluded from the Android TUN route to prevent a VPN loop.'
    }
'@ @'
    if ($androidTun.PSObject.Properties['strict_route']) {
        throw 'Topology check failed: strict_route must stay absent because SFA Android does not implement it.'
    }
    if (-not (@($androidTun.route_exclude_address) -contains ($PcIp + '/32'))) {
        throw 'Topology check failed: the PC relay IP must be excluded from the Android TUN route to prevent a VPN loop.'
    }
'@

Replace-Exact $manager @'
function Get-RecordedPids {
    try { return Read-JsonFile -Path $PidFile } catch { return $null }
}

function Get-ProcessPath {
'@ @'
function Get-RecordedPids {
    try { return Read-JsonFile -Path $PidFile } catch { return $null }
}

function Load-TrackedRelayIdentity {
    if ($script:trackedRelayIdentityLoaded) { return }
    $script:trackedRelayIdentityLoaded = $true
    $script:trackedStarPid = 0
    $script:trackedStarStartUtc = ''

    $state = Get-RecordedPids
    if ($state -and $state.starPid) {
        $script:trackedStarPid = [int]$state.starPid
        if ($state.starStartUtc) { $script:trackedStarStartUtc = [string]$state.starStartUtc }
    }
}

function Set-TrackedRelayIdentity {
    param([int]$ProcessId, [string]$StartUtc)
    $script:trackedStarPid = $ProcessId
    $script:trackedStarStartUtc = $StartUtc
    $script:trackedRelayIdentityLoaded = $true
}

function Clear-TrackedRelayIdentity {
    $script:trackedStarPid = 0
    $script:trackedStarStartUtc = ''
    $script:trackedRelayIdentityLoaded = $true
}

function Get-ProcessPath {
'@

Replace-Exact $manager @'
    if (-not $state) {
        Update-Status
        return
    }
'@ @'
    if (-not $state) {
        Clear-TrackedRelayIdentity
        Update-Status
        return
    }
'@

Replace-Exact $manager @'
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Update-Status
}

function Assert-NoForeignRelayProcesses {
'@ @'
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Clear-TrackedRelayIdentity
    Update-Status
}

function Assert-NoForeignRelayProcesses {
'@

Replace-Exact $manager @'
function Get-RelayTrackedRunning {
    $state = Get-RecordedPids
    if (-not $state -or -not $state.starPid) { return $false }
    $start = ''
    if ($state.starStartUtc) { $start = [string]$state.starStartUtc }
    return Test-ExpectedProcess -ProcessId ([int]$state.starPid) -ExpectedPath $StarExe -ExpectedStartUtc $start
}
'@ @'
function Get-RelayTrackedRunning {
    Load-TrackedRelayIdentity
    if ($script:trackedStarPid -le 0) { return $false }
    return Test-ExpectedProcess -ProcessId $script:trackedStarPid -ExpectedPath $StarExe -ExpectedStartUtc $script:trackedStarStartUtc
}
'@

Replace-Exact $manager @'
        Write-JsonFile -Path $PidFile -Value ([ordered]@{
            starPid = $process.Id
            starStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
            starPath = $StarExe
            pcIp = $pcIp
            startedUtc = [DateTime]::UtcNow.ToString('o')
        })
        Add-Log ('Relay RUNNING: StarSEA PID ' + $process.Id + ' on ' + $pcIp + ':' + $FrontPort + '.')
'@ @'
        $starStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
        Write-JsonFile -Path $PidFile -Value ([ordered]@{
            starPid = $process.Id
            starStartUtc = $starStartUtc
            starPath = $StarExe
            pcIp = $pcIp
            startedUtc = [DateTime]::UtcNow.ToString('o')
        })
        Set-TrackedRelayIdentity -ProcessId $process.Id -StartUtc $starStartUtc
        Add-Log ('Relay RUNNING: StarSEA PID ' + $process.Id + ' on ' + $pcIp + ':' + $FrontPort + '.')
'@

Replace-Exact $manager @'
        if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        throw
'@ @'
        if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        Clear-TrackedRelayIdentity
        throw
'@

Replace-Exact $manager @'
    # Gameplay hot path: once StarSEA is running, status polling must remain tiny.
    # Do not hash the runtime or enumerate adapters every timer tick while playing.
'@ @'
    # Gameplay hot path: once StarSEA is running, status polling must remain tiny.
    # Do not hash the runtime, enumerate adapters, or reread PID JSON every timer tick while playing.
'@

Replace-Exact $manager @'
    if ($text -match '"action"\s*:\s*"sniff"') { throw 'Self-test found forbidden sniff action.' }
    if ($text -notmatch 'route_exclude_address') { throw 'Self-test found missing TUN relay-IP exclusion.' }
    Write-Host 'SELF-TEST PASS: configs parse, topology invariants pass, no sniff, encrypted single-process relay.'
'@ @'
    if ($text -match '"action"\s*:\s*"sniff"') { throw 'Self-test found forbidden sniff action.' }
    if ($text -match '"strict_route"') { throw 'Self-test found unsupported SFA Android strict_route option.' }
    if ($text -match '"multiplex"') { throw 'Self-test found multiplexing on the latency path.' }
    if ($text -notmatch 'route_exclude_address') { throw 'Self-test found missing TUN relay-IP exclusion.' }
    Write-Host 'SELF-TEST PASS: configs parse, SFA-compatible TUN options pass, no sniff/multiplex, encrypted single-process relay.'
'@

Replace-Exact $readme @'
- SFA / sing-box-compatible Android client
- one or more compatible DPS meters that can parse BPSR and capture/detect `StarSEA` traffic
'@ @'
- SFA / sing-box-compatible Android client; for the release candidate, use SFA/sing-box **1.13.x** (1.13.19 is the pinned reference core)
- one or more compatible DPS meters that can parse BPSR and capture/detect `StarSEA` traffic
'@

Replace-Exact $readme @'
In SFA, use per-app / selected-app routing and leave only BPSR selected after testing.

### 5. Configure your DPS meter
'@ @'
In SFA, use per-app / selected-app routing and leave only BPSR selected after testing.

The generated Android profile intentionally does **not** set `strict_route`. SFA's Android graphical client does not implement that TUN option, so the relay does not rely on it for loop prevention or correctness. The PC relay IP is explicitly excluded from the Android TUN route instead.

### 5. Configure your DPS meter
'@

Replace-Exact $readme @'
- no protocol sniff action
- disabled sing-box runtime logging on the data path
'@ @'
- no protocol sniff action
- no unsupported SFA Android `strict_route` setting
- disabled sing-box runtime logging on the data path
'@

Replace-Exact $readme @'
The manager UI can remain open while playing. Its live status path only checks the tracked StarSEA process state; heavier integrity/network checks are done during setup, preflight, diagnostics, or while the relay is stopped.
'@ @'
The manager UI can remain open while playing. Its live status path uses an in-memory tracked StarSEA identity and only checks process state; it does not repeatedly hash binaries, enumerate adapters, or reread the PID JSON while the relay is running. Heavier integrity/network checks are done during setup, preflight, diagnostics, or while the relay is stopped.
'@

# Add regression assertions to CI without changing the existing test topology.
Replace-Exact $validate @'
            'Gameplay hot path: once StarSEA is running, status polling must remain tiny.',
            '-RemoteAddress LocalSubnet -Profile Private -EdgeTraversalPolicy Block',
'@ @'
            'Gameplay hot path: once StarSEA is running, status polling must remain tiny.',
            'function Load-TrackedRelayIdentity',
            'reread PID JSON every timer tick',
            '-RemoteAddress LocalSubnet -Profile Private -EdgeTraversalPolicy Block',
'@

Replace-Exact $validate @'
          if ($text.Contains("[ordered]@{ action = 'sniff' }")) {
            Write-Error 'Protocol sniff action was reintroduced into the generated Android path.'
            exit 1
          }

          if (-not $bat.Contains('scripts\LaunchManager.ps1')) {
'@ @'
          if ($text.Contains("[ordered]@{ action = 'sniff' }")) {
            Write-Error 'Protocol sniff action was reintroduced into the generated Android path.'
            exit 1
          }

          if ($text.Contains('strict_route = $true')) {
            Write-Error 'Unsupported SFA Android strict_route was reintroduced.'
            exit 1
          }

          if (-not $text.Contains("PSObject.Properties['strict_route']")) {
            Write-Error 'SFA strict_route absence is no longer enforced by topology validation.'
            exit 1
          }

          if (-not $readme.Contains('does not implement that TUN option')) {
            Write-Error 'README no longer explains the SFA strict_route compatibility decision.'
            exit 1
          }

          if (-not $bat.Contains('scripts\LaunchManager.ps1')) {
'@

Write-Host 'RC.7 audit patch applied successfully.'
