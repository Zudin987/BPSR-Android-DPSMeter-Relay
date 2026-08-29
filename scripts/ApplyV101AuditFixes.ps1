$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Read-Lf([string]$Path) {
    return [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
}

function Write-Utf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

$enginePath = '.\scripts\BPSRRelayManager.ps1'
$engine = Read-Lf $enginePath

if (-not $engine.Contains('function Get-ExpectedRelayPath {')) {
    $marker = 'function Stop-ProfileShare {'
    if (-not $engine.Contains($marker)) { throw 'Could not find Stop-ProfileShare insertion point.' }
    $helper = @'
function Get-ExpectedRelayPath {
    param([string]$ProcessName)
    switch ($ProcessName) {
        'StarSEA' { return $StarExe }
        'BPSRMobileFront' { return $FrontExe }
        'BPSRRelayIngress' { return (Join-Path $Runtime 'BPSRRelayIngress.exe') }
        default { return '' }
    }
}

'@
    $engine = $engine.Replace($marker, $helper.Replace("`r`n", "`n") + $marker)
}

$oldStopPrefix = @'
function Stop-Relay {
    $state = Get-RecordedPids
    if (-not $state) {
        Clear-TrackedRelayIdentity
        Update-Status
        return
    }

'@.Replace("`r`n", "`n")
$newStopPrefix = @'
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

'@.Replace("`r`n", "`n")
if ($engine.Contains($oldStopPrefix)) {
    $engine = $engine.Replace($oldStopPrefix, $newStopPrefix)
}
elseif (-not $engine.Contains('PID state file missing/unreadable; using in-memory relay identity for safe stop.')) {
    throw 'Could not locate Stop-Relay prefix for corrupt PID recovery patch.'
}
Write-Utf8 $enginePath $engine

$uiPath = '.\scripts\ManagerUi.ps1'
$ui = Read-Lf $uiPath
$closeStart = $ui.IndexOf('function Close-OldRelayPrompt {', [System.StringComparison]::Ordinal)
$loopStart = $ui.IndexOf('    foreach ($item in $items) {', $closeStart, [System.StringComparison]::Ordinal)
$loopEnd = $ui.IndexOf('    Start-Sleep -Milliseconds 150', $loopStart, [System.StringComparison]::Ordinal)
if ($closeStart -lt 0 -or $loopStart -lt 0 -or $loopEnd -le $loopStart) { throw 'Could not isolate stale relay cleanup loop.' }

if (-not $ui.Substring($closeStart, $loopEnd - $closeStart).Contains('Get-ExpectedRelayPath -ProcessName')) {
    $newLoop = @'
    foreach ($item in $items) {
        try {
            if ([string]::IsNullOrWhiteSpace([string]$item.StartUtc)) {
                Add-Log ('Skipped old relay PID ' + $item.Id + ' because its start-time identity could not be recorded. Refresh and try again.')
                continue
            }

            $expectedPath = Get-ExpectedRelayPath -ProcessName ([string]$item.Name)
            if ([string]::IsNullOrWhiteSpace($expectedPath)) {
                Add-Log ('Skipped old relay PID ' + $item.Id + ' because its executable name is not managed by this project.')
                continue
            }

            # Re-check PID + exact project executable path + start time immediately
            # before Stop-Process. A same-named unrelated process must never be killed.
            if (-not (Test-ExpectedProcess -ProcessId ([int]$item.Id) -ExpectedPath $expectedPath -ExpectedStartUtc ([string]$item.StartUtc))) {
                Add-Log ('Skipped ' + $item.Name + ' PID ' + $item.Id + ' because it is not the exact project relay process recorded by path/start time.')
                continue
            }

            Stop-Process -Id ([int]$item.Id) -Force -ErrorAction Stop
            Add-Log ('Closed old project relay ' + $item.Name + ' (PID ' + $item.Id + ') after PID/path/start-time verification and user confirmation.')
        }
        catch {
            Add-Log ('Could not close old relay PID ' + $item.Id + ': ' + $_.Exception.Message)
        }
    }

'@.Replace("`r`n", "`n")
    $ui = $ui.Substring(0, $loopStart) + $newLoop + $ui.Substring($loopEnd)
}

$oldOrder = '12. Start SFA. Allow VPN permission.`r`n`r`n13. PC: Start Relay. Open BPSR.'
$newOrder = '12. PC: Start Relay.`r`n13. Phone: Start SFA. Allow VPN permission.`r`n14. Open BPSR.'
if ($ui.Contains($oldOrder)) {
    $ui = $ui.Replace($oldOrder, $newOrder)
}
elseif (-not $ui.Contains($newOrder)) {
    throw 'Could not locate first-time Android startup order text.'
}

if (-not $ui.Contains("Stale-process safety self-test failed")) {
    $selfTestMarker = "    if (`$targetValue.Text -ne 'StarSEA') { throw 'DPS target card changed unexpectedly.' }"
    if (-not $ui.Contains($selfTestMarker)) { throw 'Could not find UI self-test insertion point.' }
    $selfTests = @'

    $cleanupSource = (Get-Command Close-OldRelayPrompt -ErrorAction Stop).ScriptBlock.ToString()
    foreach ($needle in @('Get-ExpectedRelayPath -ProcessName','Test-ExpectedProcess -ProcessId ([int]$item.Id) -ExpectedPath $expectedPath -ExpectedStartUtc','same-named unrelated process must never be killed')) {
        if (-not $cleanupSource.Contains($needle)) { throw ('Stale-process safety self-test failed: ' + $needle) }
    }
    if ($cleanupSource.Contains('$current.ProcessName -ne [string]$item.Name')) { throw 'Unsafe name/start-time-only stale cleanup was reintroduced.' }

    $stopSource = (Get-Command Stop-Relay -ErrorAction Stop).ScriptBlock.ToString()
    foreach ($needle in @('PID state file missing/unreadable; using in-memory relay identity for safe stop.','$script:trackedStarPid','$script:trackedFrontPid','Test-ExpectedProcess')) {
        if (-not $stopSource.Contains($needle)) { throw ('PID recovery self-test failed: ' + $needle) }
    }

    foreach ($needle in @('12. PC: Start Relay.','13. Phone: Start SFA. Allow VPN permission.','14. Open BPSR.')) {
        if (-not $androidRight.Text.Contains($needle)) { throw ('Android startup-order self-test failed: ' + $needle) }
    }
    if ($androidRight.Text.Contains('12. Start SFA. Allow VPN permission.')) { throw 'Old phone-before-PC startup order was reintroduced.' }
'@
    $ui = $ui.Replace($selfTestMarker, $selfTestMarker + $selfTests.Replace("`r`n", "`n"))
}
Write-Utf8 $uiPath $ui

git diff --check
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add scripts/BPSRRelayManager.ps1 scripts/ManagerUi.ps1
git rm scripts/ApplyV101AuditFixes.ps1
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
git commit -m 'Harden stale relay cleanup and startup guidance'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
git push origin HEAD:feature/v1.0.1-hardening
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
