$ErrorActionPreference = 'Stop'

function Replace-Exact {
    param([string]$Path, [string]$Old, [string]$New)
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Old)) { throw ('Expected patch target missing in ' + $Path) }
    $text = $text.Replace($Old, $New)
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path), $text, (New-Object System.Text.UTF8Encoding($false)))
}

$manager = 'scripts\BPSRRelayManager.ps1'
$readme = 'README.md'

Replace-Exact $manager "`$ManagerVersion = '1.0.0-rc.7'" "`$ManagerVersion = '1.0.0-rc.8'"

Replace-Exact $manager @'
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
'@ @'
function Load-TrackedRelayIdentity {
    if ($script:trackedRelayIdentityLoaded) { return }
    $script:trackedRelayIdentityLoaded = $true
    $script:trackedStarPid = 0
    $script:trackedStarStartUtc = ''

    $state = Get-RecordedPids
    if ($state -and $state.starPid -and $state.starStartUtc) {
        $candidatePid = [int]$state.starPid
        $candidateStart = [string]$state.starStartUtc
        # Full path/start-time verification happens once when this manager attaches.
        if (Test-ExpectedProcess -ProcessId $candidatePid -ExpectedPath $StarExe -ExpectedStartUtc $candidateStart) {
            $script:trackedStarPid = $candidatePid
            $script:trackedStarStartUtc = $candidateStart
        }
    }
}
'@

Replace-Exact $manager @'
function Get-RelayTrackedRunning {
    Load-TrackedRelayIdentity
    if ($script:trackedStarPid -le 0) { return $false }
    return Test-ExpectedProcess -ProcessId $script:trackedStarPid -ExpectedPath $StarExe -ExpectedStartUtc $script:trackedStarStartUtc
}
'@ @'
function Get-RelayTrackedRunning {
    Load-TrackedRelayIdentity
    if ($script:trackedStarPid -le 0 -or [string]::IsNullOrWhiteSpace($script:trackedStarStartUtc)) { return $false }
    try {
        # Gameplay hot check: PID + immutable process start time only. The executable path
        # was fully validated when the identity was loaded or when this manager launched it.
        $process = Get-Process -Id $script:trackedStarPid -ErrorAction Stop
        $expectedStart = [DateTime]::Parse($script:trackedStarStartUtc).ToUniversalTime()
        $actualStart = $process.StartTime.ToUniversalTime()
        return [Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -le 2
    }
    catch { return $false }
}
'@

Replace-Exact $manager @'
    # Gameplay hot path: once StarSEA is running, status polling must remain tiny.
    # Do not hash the runtime, enumerate adapters, or reread PID JSON every timer tick while playing.
'@ @'
    # Gameplay hot path: once StarSEA is running, status polling must remain tiny.
    # Do not hash the runtime, enumerate adapters, reread PID JSON, or resolve the executable path every timer tick.
'@

Replace-Exact $readme @'
The manager UI can remain open while playing. Its live status path uses an in-memory tracked StarSEA identity and only checks process state; it does not repeatedly hash binaries, enumerate adapters, or reread the PID JSON while the relay is running. Heavier integrity/network checks are done during setup, preflight, diagnostics, or while the relay is stopped.
'@ @'
The manager UI can remain open while playing. When it first attaches to a tracked StarSEA process it verifies the executable path and start time once. While the relay is running, the recurring status check uses only the cached PID + immutable process start time; it does not repeatedly hash binaries, enumerate adapters, reread PID JSON, or resolve the executable path. Heavier integrity/network checks are done during setup, preflight, diagnostics, or while the relay is stopped.
'@

Write-Host 'RC.8 latency patch applied.'
