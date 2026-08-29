$ErrorActionPreference = 'Stop'

function Replace-Exact {
    param([string]$Path, [string]$Old, [string]$New)
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Old)) { throw ('Expected text not found in ' + $Path) }
    $text = $text.Replace($Old, $New)
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path), $text, (New-Object System.Text.UTF8Encoding($false)))
}

Replace-Exact -Path 'scripts\BPSRRelayManager.ps1' -Old @'
$ManagerVersion = '1.0.0-rc.11'
'@ -New @'
$ManagerVersion = '1.0.0-rc.12'
'@

$oldAssert = @'
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
'@
$newAssert = @'
function Get-ForeignRelayProcesses {
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
            $foreign += [PSCustomObject]@{
                Name = $name
                Id = [int]$process.Id
            }
        }
    }
    return @($foreign)
}

function Assert-NoForeignRelayProcesses {
    $foreign = @(Get-ForeignRelayProcesses)
    if ($foreign.Count -gt 0) {
        $labels = @($foreign | ForEach-Object { $_.Name + ' (PID ' + $_.Id + ')' })
        throw ('Foreign/legacy relay process detected: ' + ($labels -join ', ') + '. Close it before continuing so there is never a second relay path.')
    }
}
'@
Replace-Exact -Path 'scripts\BPSRRelayManager.ps1' -Old $oldAssert -New $newAssert

$oldButton = @'
    $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.25)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.TabStop = $true
'@
$newButton = @'
    $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.25)
    $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $button.Padding = New-Object System.Windows.Forms.Padding(0)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.TabStop = $true
'@
Replace-Exact -Path 'scripts\ManagerUi.ps1' -Old $oldButton -New $newButton

Replace-Exact -Path 'scripts\ManagerUi.ps1' -Old @'
function Get-FriendlyErrorText {
'@ -New @'
function Get-OldRelaySummary {
    $items = @(Get-ForeignRelayProcesses)
    if ($items.Count -eq 0) { return '' }
    return (@($items | ForEach-Object { $_.Name + '.exe (PID ' + $_.Id + ')' }) -join ', ')
}

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
            $current = Get-Process -Id ([int]$item.Id) -ErrorAction Stop
            if ([string]$current.ProcessName -ne [string]$item.Name) { continue }
            Stop-Process -Id ([int]$item.Id) -Force -ErrorAction Stop
            Add-Log ('Closed old relay ' + $item.Name + ' (PID ' + $item.Id + ') after user confirmation.')
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
            "Windows could not close:`r`n`r`n$left`r`n`r`nRestart your PC, then try again.",
            'Could not close old relay',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $false
    }
    return $true
}

function Invoke-PrepareRelay {
    $oldText = $script:btnSetup.Text
    $script:btnSetup.Enabled = $false
    $script:btnSetup.Text = 'Preparing...'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        try {
            Setup-Relay
        }
        catch {
            $firstError = $_.Exception
            if ([string]$firstError.Message -match 'foreign|legacy|duplicate relay') {
                if (Close-OldRelayPrompt) {
                    Setup-Relay
                }
            }
            else {
                throw $firstError
            }
        }
    }
    catch {
        Show-FriendlyError -Title 'Could not prepare relay' -Exception $_.Exception
    }
    finally {
        $script:btnSetup.Text = $oldText
        Update-Status
    }
}

function Get-FriendlyErrorText {
'@

$oldShow = @'
function Show-FriendlyError {
    param([string]$Title, [System.Exception]$Exception)

    Add-Log ('ERROR: ' + $Exception.Message)
    [System.Windows.Forms.MessageBox]::Show(
        (Get-FriendlyErrorText -Exception $Exception),
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}
'@
$newShow = @'
function Show-FriendlyError {
    param([string]$Title, [System.Exception]$Exception)

    Add-Log ('ERROR: ' + $Exception.Message)
    if ([string]$Exception.Message -match 'foreign|legacy|duplicate relay') {
        [void](Close-OldRelayPrompt)
        return
    }
    [System.Windows.Forms.MessageBox]::Show(
        (Get-FriendlyErrorText -Exception $Exception),
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}
'@
Replace-Exact -Path 'scripts\ManagerUi.ps1' -Old $oldShow -New $newShow

$oldForeign = @'
    $foreign = @(Get-Process -Name 'StarSEA','BPSRMobileFront','BPSRRelayIngress' -ErrorAction SilentlyContinue).Count -gt 0
    if ($foreign) {
        Set-UiStatusLabel -Label $script:lblRelayState -Text 'Old relay found' -State 'Error'
    }
    else {
        Set-UiStatusLabel -Label $script:lblRelayState -Text 'Stopped' -State 'Neutral'
    }
'@
$newForeign = @'
    $foreignProcesses = @(Get-ForeignRelayProcesses)
    $foreign = $foreignProcesses.Count -gt 0
    if ($foreign) {
        if ($foreignProcesses.Count -eq 1) {
            Set-UiStatusLabel -Label $script:lblRelayState -Text ($foreignProcesses[0].Name + '.exe') -State 'Error'
        }
        else {
            Set-UiStatusLabel -Label $script:lblRelayState -Text ($foreignProcesses.Count.ToString() + ' old relays') -State 'Error'
        }
    }
    else {
        Set-UiStatusLabel -Label $script:lblRelayState -Text 'Stopped' -State 'Neutral'
    }
'@
Replace-Exact -Path 'scripts\ManagerUi.ps1' -Old $oldForeign -New $newForeign

Replace-Exact -Path 'scripts\ManagerUi.ps1' -Old @'
        $script:lblNextAction.Text = 'Close old relay apps or restart your PC.'
'@ -New @'
        if ($foreignProcesses.Count -eq 1) {
            $script:lblNextAction.Text = 'Found ' + $foreignProcesses[0].Name + '.exe. Click Prepare Relay to close it.'
        }
        else {
            $script:lblNextAction.Text = 'Found ' + $foreignProcesses.Count + ' old relay processes. Click Prepare Relay to close them.'
        }
'@

Replace-Exact -Path 'scripts\ManagerUi.ps1' -Old @'
$script:btnSetup = New-UiButton -Text 'Prepare Relay' -X 382 -Y 17 -Width 148 -Height 36 -Primary
'@ -New @'
$script:btnSetup = New-UiButton -Text 'Prepare Relay' -X 382 -Y 32 -Width 148 -Height 30 -Primary
'@
Replace-Exact -Path 'scripts\ManagerUi.ps1' -Old @'
$script:btnSetup.Add_Click({ try { Setup-Relay } catch { Show-FriendlyError -Title 'Could not prepare relay' -Exception $_.Exception } })
'@ -New @'
$script:btnSetup.Add_Click({ Invoke-PrepareRelay })
'@
Replace-Exact -Path 'scripts\ManagerUi.ps1' -Old @'
$script:btnFirewall = New-UiButton -Text 'Allow Firewall' -X 382 -Y 17 -Width 148 -Height 36
'@ -New @'
$script:btnFirewall = New-UiButton -Text 'Allow Firewall' -X 382 -Y 32 -Width 148 -Height 30
'@
Replace-Exact -Path 'scripts\ManagerUi.ps1' -Old @'
$btnCopyDpsHome = New-UiButton -Text 'Copy Setup Notes' -X 382 -Y 17 -Width 148 -Height 36
'@ -New @'
$btnCopyDpsHome = New-UiButton -Text 'Copy Setup Notes' -X 382 -Y 32 -Width 148 -Height 30
'@

Write-Host 'RC.12 UX patch applied safely.'
