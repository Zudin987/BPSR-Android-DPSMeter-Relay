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
Write-Utf8 $uiPath $ui

$validatePath = '.\.github\workflows\validate.yml'
$validate = Read-Lf $validatePath
if (-not $validate.Contains('Check stale-process ownership, PID recovery, and startup-order guards')) {
    $validationMarker = '      - name: Verify Windows TCP and UDP conflict detection primitives'
    if (-not $validate.Contains($validationMarker)) { throw 'Could not find validation insertion point.' }
    $validationStep = @'
      - name: Check stale-process ownership, PID recovery, and startup-order guards
        shell: powershell
        run: |
          $text = Get-Content 'scripts\BPSRRelayManager.ps1' -Raw
          $ui = Get-Content 'scripts\ManagerUi.ps1' -Raw

          foreach ($needle in @('function Get-ExpectedRelayPath', "'StarSEA' { return `$StarExe }", "'BPSRMobileFront' { return `$FrontExe }", "'BPSRRelayIngress' { return (Join-Path `$Runtime 'BPSRRelayIngress.exe') }")) {
            if (-not $text.Contains($needle)) { throw ('Missing exact relay ownership guard: ' + $needle) }
          }

          $stopStart = $text.IndexOf('function Stop-Relay {', [System.StringComparison]::Ordinal)
          $stopEnd = $text.IndexOf('function Get-ForeignRelayProcesses', $stopStart, [System.StringComparison]::Ordinal)
          if ($stopStart -lt 0 -or $stopEnd -le $stopStart) { throw 'Could not isolate Stop-Relay.' }
          $stop = $text.Substring($stopStart, $stopEnd - $stopStart)
          foreach ($needle in @('PID state file missing/unreadable; using in-memory relay identity for safe stop.','$script:trackedStarPid','$script:trackedFrontPid','Test-ExpectedProcess')) {
            if (-not $stop.Contains($needle)) { throw ('Corrupt PID recovery guard missing: ' + $needle) }
          }

          $cleanupStart = $ui.IndexOf('function Close-OldRelayPrompt {', [System.StringComparison]::Ordinal)
          $cleanupEnd = $ui.IndexOf('function Invoke-PrepareRelay', $cleanupStart, [System.StringComparison]::Ordinal)
          if ($cleanupStart -lt 0 -or $cleanupEnd -le $cleanupStart) { throw 'Could not isolate Close-OldRelayPrompt.' }
          $cleanup = $ui.Substring($cleanupStart, $cleanupEnd - $cleanupStart)
          foreach ($needle in @('Get-ExpectedRelayPath -ProcessName','Test-ExpectedProcess -ProcessId ([int]$item.Id) -ExpectedPath $expectedPath -ExpectedStartUtc','same-named unrelated process must never be killed','PID/path/start-time verification')) {
            if (-not $cleanup.Contains($needle)) { throw ('Safe stale cleanup guard missing: ' + $needle) }
          }
          if ($cleanup.Contains('$current.ProcessName -ne [string]$item.Name')) {
            throw 'Name/start-time-only stale-process kill logic was reintroduced.'
          }

          foreach ($needle in @('12. PC: Start Relay.','13. Phone: Start SFA. Allow VPN permission.','14. Open BPSR.')) {
            if (-not $ui.Contains($needle)) { throw ('First-time startup order regression: ' + $needle) }
          }
          if ($ui.Contains('12. Start SFA. Allow VPN permission.')) {
            throw 'Old phone-before-PC startup order was reintroduced.'
          }
          Write-Host 'Stale-process ownership, PID recovery, and startup-order guards passed.'

'@.Replace("`r`n", "`n")
    $validate = $validate.Replace($validationMarker, $validationStep + $validationMarker)
}
Write-Utf8 $validatePath $validate

git diff --check
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add scripts/BPSRRelayManager.ps1 scripts/ManagerUi.ps1 .github/workflows/validate.yml
git rm scripts/ApplyV101AuditFixes.ps1 .github/workflows/apply-v101-stale-process-safety.yml
git commit -m 'Harden stale relay cleanup and startup guidance'
git push origin HEAD:feature/v1.0.1-hardening
