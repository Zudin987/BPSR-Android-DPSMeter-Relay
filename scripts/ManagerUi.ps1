# BPSR Android Relay - user interface
# This file contains UI only. It does not proxy or inspect gameplay traffic.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Ui = @{
    Background = [System.Drawing.Color]::FromArgb(247, 248, 250)
    Card       = [System.Drawing.Color]::White
    Text       = [System.Drawing.Color]::FromArgb(30, 41, 59)
    Muted      = [System.Drawing.Color]::FromArgb(100, 116, 139)
    Border     = [System.Drawing.Color]::FromArgb(226, 232, 240)
    Primary    = [System.Drawing.Color]::FromArgb(37, 99, 235)
    Success    = [System.Drawing.Color]::FromArgb(22, 128, 60)
    Warning    = [System.Drawing.Color]::FromArgb(180, 83, 9)
    Danger     = [System.Drawing.Color]::FromArgb(185, 28, 28)
    Neutral    = [System.Drawing.Color]::FromArgb(71, 85, 105)
}

function New-UiButton {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height = 36,
        [switch]$Primary,
        [switch]$Danger
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, $Height)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = $Ui.Border
    $button.BackColor = $Ui.Card
    $button.ForeColor = $Ui.Text
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand

    if ($Primary) {
        $button.BackColor = $Ui.Primary
        $button.ForeColor = [System.Drawing.Color]::White
        $button.FlatAppearance.BorderColor = $Ui.Primary
        $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
    }
    elseif ($Danger) {
        $button.ForeColor = $Ui.Danger
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(239, 180, 180)
    }

    return $button
}

function New-UiCard {
    param([int]$X, [int]$Y, [int]$Width, [int]$Height)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($Width, $Height)
    $panel.BackColor = $Ui.Card
    $panel.BorderStyle = 'FixedSingle'
    return $panel
}

function Add-CardTitle {
    param($Parent, [string]$Text, [int]$Y = 9)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point(14, $Y)
    $label.Size = New-Object System.Drawing.Size(($Parent.Width - 30), 22)
    $label.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $label.ForeColor = $Ui.Text
    $Parent.Controls.Add($label)
    return $label
}

function Add-CardHelp {
    param($Parent, [string]$Text, [int]$Y, [int]$Width = 330, [int]$Height = 22)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point(14, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.ForeColor = $Ui.Muted
    $Parent.Controls.Add($label)
    return $label
}

function New-StatusCard {
    param($Parent, [string]$Title, [int]$X, [int]$Y, [int]$Width)

    $card = New-UiCard -X $X -Y $Y -Width $Width -Height 64

    $heading = New-Object System.Windows.Forms.Label
    $heading.Text = $Title
    $heading.Location = New-Object System.Drawing.Point(11, 8)
    $heading.Size = New-Object System.Drawing.Size(($Width - 22), 18)
    $heading.ForeColor = $Ui.Muted
    $card.Controls.Add($heading)

    $value = New-Object System.Windows.Forms.Label
    $value.Text = 'Checking...'
    $value.Location = New-Object System.Drawing.Point(11, 31)
    $value.Size = New-Object System.Drawing.Size(($Width - 22), 22)
    $value.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
    $value.ForeColor = $Ui.Neutral
    $card.Controls.Add($value)

    $Parent.Controls.Add($card)
    return $value
}

function Set-UiStatusLabel {
    param($Label, [string]$Text, [string]$State = 'Neutral')

    if (-not $Label) { return }
    $Label.Text = $Text

    switch ($State) {
        'Ready'   { $Label.ForeColor = $Ui.Success }
        'Running' { $Label.ForeColor = $Ui.Primary }
        'Warning' { $Label.ForeColor = $Ui.Warning }
        'Error'   { $Label.ForeColor = $Ui.Danger }
        default   { $Label.ForeColor = $Ui.Neutral }
    }
}

function Get-FriendlyErrorText {
    param([System.Exception]$Exception)

    $raw = [string]$Exception.Message
    switch -Regex ($raw) {
        'foreign|legacy|duplicate relay|already running' {
            return "An old relay is still running.`r`n`r`nClose old relay apps or restart your PC, then try again."
        }
        'port.*free|port.*used|listener|occupied|already in use' {
            return "Another app is using the relay connection.`r`n`r`nClose the old relay or restart your PC, then try again."
        }
        'profile.*stale|profile.*missing|profile.*unavailable|Run Setup|Setup / Repair|Profile not generated' {
            return "Your phone profile is not ready.`r`n`r`nClick Prepare Relay, then try again."
        }
        'firewall|administrator|access is denied|elevation' {
            return "Windows could not allow the phone connection.`r`n`r`nClick Allow Firewall again and approve the Windows message."
        }
        'LAN IP|selected IP|local IP|address.*assigned|valid PC LAN' {
            return "This PC address cannot be used now.`r`n`r`nChoose the current address and try again."
        }
        default {
            return "Something went wrong.`r`n`r`nOpen Details > Logs for more information."
        }
    }
}

# Override the engine's technical dialog with short user-facing text.
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

# Keep the full check details in Logs, but show a short result to normal users.
function Show-Preflight {
    $pcIp = Get-SelectedIp
    $running = Get-RelayTrackedRunning
    $checks = Get-PreflightChecks -PcIp $pcIp -RequirePortFree:(-not $running)

    foreach ($line in (Format-Checks -Checks $checks) -split [Environment]::NewLine) {
        Add-Log $line
    }

    $fails = @($checks | Where-Object { $_.State -eq 'FAIL' })
    $warnings = @($checks | Where-Object { $_.State -eq 'WARN' })

    if ($fails.Count -eq 0) {
        $message = 'Everything important looks ready.'
        if ($warnings.Count -gt 0) {
            $message += "`r`n`r`nThere is a Windows network warning. If your phone cannot connect, click Allow Firewall again."
        }
        else {
            $message += "`r`n`r`nYou can click Start Relay."
        }

        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'Ready to use',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    $names = ($fails.Name -join ' ')
    if ($names -match 'Duplicate relay|TCP') {
        $message = "An old relay or another app is still using the relay.`r`n`r`nClose it or restart your PC."
    }
    elseif ($names -match 'LAN IP') {
        $message = "This PC address is not ready.`r`n`r`nChoose the current address and try again."
    }
    else {
        $message = "Setup is not ready yet.`r`n`r`nClick Prepare Relay, then run the check again."
    }

    [System.Windows.Forms.MessageBox]::Show(
        $message,
        'One thing needs attention',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
}

function Update-UiButtonStates {
    param(
        [bool]$Running,
        [bool]$ProfileReady = $false,
        [bool]$RuntimeReady = $false,
        [bool]$ForeignRelay = $false
    )

    if ($script:btnSetup)       { $script:btnSetup.Enabled = -not $Running }
    if ($script:btnFirewall)    { $script:btnFirewall.Enabled = -not $Running }
    if ($script:btnShare)       { $script:btnShare.Enabled = (-not $Running) -and $ProfileReady -and (-not $ForeignRelay) }
    if ($script:btnQr)          { $script:btnQr.Enabled = (-not $Running) -and ($null -ne $script:shareProcess) }
    if ($script:btnUrl)         { $script:btnUrl.Enabled = (-not $Running) -and ($null -ne $script:shareProcess) }
    if ($script:btnPreflight)   { $script:btnPreflight.Enabled = (-not $Running) -and $RuntimeReady -and $ProfileReady -and (-not $ForeignRelay) }
    if ($script:btnStart)       { $script:btnStart.Enabled = (-not $Running) -and $RuntimeReady -and $ProfileReady -and (-not $ForeignRelay) }
    if ($script:btnStop)        { $script:btnStop.Enabled = $Running }
    if ($script:btnStopDetails) { $script:btnStopDetails.Enabled = $Running }
    if ($script:btnRollback)    { $script:btnRollback.Enabled = -not $Running }
}

# Override the engine status renderer for the simplified UI.
function Update-Status {
    if ($script:shareProcess) {
        try {
            $script:shareProcess.Refresh()
            if ($script:shareProcess.HasExited) {
                $script:shareProcess = $null
                $script:shareUrl = ''
                if ($script:txtLog) { Add-Log 'Phone setup link ended. Create a new one if needed.' }
            }
        }
        catch {
            $script:shareProcess = $null
            $script:shareUrl = ''
        }
    }

    if (-not $script:lblRelayState) { return }

    # Gameplay hot path: one tracked-process check only. No hashing, adapter scans,
    # config reads, firewall queries, or other setup work while StarSEA is running.
    if (Get-RelayTrackedRunning) {
        Set-UiStatusLabel -Label $script:lblRelayState -Text 'Running' -State 'Running'
        Set-UiStatusLabel -Label $script:lblProfileState -Text 'Ready' -State 'Ready'
        Set-UiStatusLabel -Label $script:lblRuntimeState -Text 'Ready' -State 'Ready'
        Set-UiStatusLabel -Label $script:lblFirewallState -Text 'Active' -State 'Ready'
        $script:lblNextAction.Text = 'Relay is running. Start BPSR and play.'
        Update-UiButtonStates -Running $true
        return
    }

    $foreign = @(Get-Process -Name 'StarSEA','BPSRMobileFront','BPSRRelayIngress' -ErrorAction SilentlyContinue).Count -gt 0
    if ($foreign) {
        Set-UiStatusLabel -Label $script:lblRelayState -Text 'Old relay found' -State 'Error'
    }
    else {
        Set-UiStatusLabel -Label $script:lblRelayState -Text 'Stopped' -State 'Neutral'
    }

    $selected = ([string]$script:cmbIp.Text).Trim()
    $profileIp = Get-ProfilePcIp
    $profileReady = $false
    if ([string]::IsNullOrWhiteSpace($profileIp)) {
        Set-UiStatusLabel -Label $script:lblProfileState -Text 'Missing' -State 'Error'
    }
    elseif ($profileIp -eq $selected -and (Test-LocalIpAssigned $selected)) {
        $profileReady = $true
        Set-UiStatusLabel -Label $script:lblProfileState -Text 'Ready' -State 'Ready'
    }
    else {
        Set-UiStatusLabel -Label $script:lblProfileState -Text 'Needs update' -State 'Warning'
    }

    $runtimeReady = Test-RuntimeIntegrity
    if ($runtimeReady) {
        Set-UiStatusLabel -Label $script:lblRuntimeState -Text 'Ready' -State 'Ready'
    }
    else {
        Set-UiStatusLabel -Label $script:lblRuntimeState -Text 'Needs setup' -State 'Warning'
    }

    $firewallReady = $false
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        try { $firewallReady = Test-FirewallReady -PcIp $selected } catch {}
    }
    if ($firewallReady) {
        Set-UiStatusLabel -Label $script:lblFirewallState -Text 'Ready' -State 'Ready'
    }
    else {
        Set-UiStatusLabel -Label $script:lblFirewallState -Text 'Not set' -State 'Warning'
    }

    if ($foreign) {
        $script:lblNextAction.Text = 'Close old relay apps or restart your PC.'
    }
    elseif (-not $runtimeReady) {
        $script:lblNextAction.Text = 'Click Prepare Relay.'
    }
    elseif (-not $profileReady) {
        $script:lblNextAction.Text = 'Click Prepare Relay to refresh the phone profile.'
    }
    elseif (-not $firewallReady) {
        $script:lblNextAction.Text = 'Click Allow Firewall.'
    }
    elseif ($script:shareProcess) {
        $script:lblNextAction.Text = 'Phone link is ready. Use Show QR or Copy Link.'
    }
    else {
        $script:lblNextAction.Text = 'Ready. Click Start Relay.'
    }

    Update-UiButtonStates -Running $false -ProfileReady $profileReady -RuntimeReady $runtimeReady -ForeignRelay $foreign
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'BPSR Android Relay'
$form.Size = New-Object System.Drawing.Size(980, 730)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.BackColor = $Ui.Background
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$title = New-Object System.Windows.Forms.Label
$title.Text = 'BPSR Android Relay'
$title.Location = New-Object System.Drawing.Point(24, 15)
$title.Size = New-Object System.Drawing.Size(650, 31)
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 17)
$title.ForeColor = $Ui.Text
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Use your phone with a compatible DPS meter'
$subtitle.Location = New-Object System.Drawing.Point(27, 48)
$subtitle.Size = New-Object System.Drawing.Size(650, 22)
$subtitle.ForeColor = $Ui.Muted
$form.Controls.Add($subtitle)

$versionLabel = New-Object System.Windows.Forms.Label
$versionLabel.Text = 'v' + $ManagerVersion
$versionLabel.Location = New-Object System.Drawing.Point(810, 24)
$versionLabel.Size = New-Object System.Drawing.Size(125, 22)
$versionLabel.TextAlign = 'MiddleRight'
$versionLabel.ForeColor = $Ui.Muted
$form.Controls.Add($versionLabel)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(20, 80)
$tabs.Size = New-Object System.Drawing.Size(925, 595)
$tabs.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$form.Controls.Add($tabs)

$homeTab = New-Object System.Windows.Forms.TabPage
$homeTab.Text = 'Home'
$homeTab.BackColor = $Ui.Background
$tabs.TabPages.Add($homeTab)

$detailsTab = New-Object System.Windows.Forms.TabPage
$detailsTab.Text = 'Details'
$detailsTab.BackColor = $Ui.Background
$tabs.TabPages.Add($detailsTab)

$helpTab = New-Object System.Windows.Forms.TabPage
$helpTab.Text = 'Help'
$helpTab.BackColor = $Ui.Background
$tabs.TabPages.Add($helpTab)

# HOME - simple guided setup
$setupPanel = New-Object System.Windows.Forms.Panel
$setupPanel.Location = New-Object System.Drawing.Point(10, 10)
$setupPanel.Size = New-Object System.Drawing.Size(535, 520)
$setupPanel.BackColor = $Ui.Background
$homeTab.Controls.Add($setupPanel)

$addressCard = New-UiCard -X 0 -Y 0 -Width 535 -Height 60
[void](Add-CardTitle -Parent $addressCard -Text 'This PC' -Y 5)
$script:cmbIp = New-Object System.Windows.Forms.ComboBox
$script:cmbIp.Location = New-Object System.Drawing.Point(14, 29)
$script:cmbIp.Size = New-Object System.Drawing.Size(225, 25)
$script:cmbIp.DropDownStyle = 'DropDown'
$addressCard.Controls.Add($script:cmbIp)
$addressHint = New-Object System.Windows.Forms.Label
$addressHint.Text = 'Usually leave this as-is. Phone and PC need the same Wi-Fi.'
$addressHint.Location = New-Object System.Drawing.Point(250, 31)
$addressHint.Size = New-Object System.Drawing.Size(270, 22)
$addressHint.ForeColor = $Ui.Muted
$addressCard.Controls.Add($addressHint)
$setupPanel.Controls.Add($addressCard)

$candidates = @(Get-LanIPv4Candidates)
$seen = @{}
foreach ($candidate in $candidates) {
    if (-not $seen.ContainsKey($candidate.IP)) {
        [void]$script:cmbIp.Items.Add($candidate.IP)
        $seen[$candidate.IP] = $true
    }
}
if ($script:cmbIp.Items.Count -gt 0) { $script:cmbIp.SelectedIndex = 0 }
$script:cmbIp.Add_SelectedIndexChanged({ Update-Status })
$script:cmbIp.Add_Leave({ Update-Status })

$step1 = New-UiCard -X 0 -Y 70 -Width 535 -Height 70
[void](Add-CardTitle -Parent $step1 -Text '1. Prepare Relay')
[void](Add-CardHelp -Parent $step1 -Text 'Set up this PC. Do this first.' -Y 35 -Width 320)
$script:btnSetup = New-UiButton -Text 'Prepare Relay' -X 370 -Y 17 -Width 145 -Height 36 -Primary
$script:btnSetup.Add_Click({ try { Setup-Relay } catch { Show-FriendlyError -Title 'Could not prepare relay' -Exception $_.Exception } })
$step1.Controls.Add($script:btnSetup)
$setupPanel.Controls.Add($step1)

$step2 = New-UiCard -X 0 -Y 150 -Width 535 -Height 70
[void](Add-CardTitle -Parent $step2 -Text '2. Allow Firewall')
[void](Add-CardHelp -Parent $step2 -Text 'Let your phone connect to this PC.' -Y 35 -Width 320)
$script:btnFirewall = New-UiButton -Text 'Allow Firewall' -X 370 -Y 17 -Width 145 -Height 36
$script:btnFirewall.Add_Click({ try { Allow-Firewall } catch { Show-FriendlyError -Title 'Could not allow connection' -Exception $_.Exception } })
$step2.Controls.Add($script:btnFirewall)
$setupPanel.Controls.Add($step2)

$step3 = New-UiCard -X 0 -Y 230 -Width 535 -Height 100
[void](Add-CardTitle -Parent $step3 -Text '3. Send to Phone')
[void](Add-CardHelp -Parent $step3 -Text 'Import the profile in SFA. Select BPSR only.' -Y 34 -Width 490)
$script:btnShare = New-UiButton -Text 'Send to Phone' -X 14 -Y 59 -Width 130 -Height 32 -Primary
$script:btnShare.Add_Click({ try { Start-ProfileShare } catch { Show-FriendlyError -Title 'Could not send profile' -Exception $_.Exception } })
$step3.Controls.Add($script:btnShare)
$script:btnQr = New-UiButton -Text 'Show QR' -X 153 -Y 59 -Width 95 -Height 32
$script:btnQr.Add_Click({ try { Show-ShareQr } catch { Show-FriendlyError -Title 'Could not show QR' -Exception $_.Exception } })
$step3.Controls.Add($script:btnQr)
$script:btnUrl = New-UiButton -Text 'Copy Link' -X 257 -Y 59 -Width 95 -Height 32
$script:btnUrl.Add_Click({ try { Copy-ShareUrl } catch { Show-FriendlyError -Title 'Could not copy link' -Exception $_.Exception } })
$step3.Controls.Add($script:btnUrl)
$script:btnFolder = New-UiButton -Text 'Open Folder' -X 361 -Y 59 -Width 140 -Height 32
$script:btnFolder.Add_Click({ try { Open-ProfileFolder } catch { Show-FriendlyError -Title 'Could not open folder' -Exception $_.Exception } })
$step3.Controls.Add($script:btnFolder)
$setupPanel.Controls.Add($step3)

$step4 = New-UiCard -X 0 -Y 340 -Width 535 -Height 70
[void](Add-CardTitle -Parent $step4 -Text '4. DPS Meter')
$dpsText = New-Object System.Windows.Forms.Label
$dpsText.Text = 'Set your DPS meter to:  StarSEA'
$dpsText.Location = New-Object System.Drawing.Point(14, 37)
$dpsText.Size = New-Object System.Drawing.Size(320, 22)
$dpsText.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$dpsText.ForeColor = $Ui.Text
$step4.Controls.Add($dpsText)
$btnCopyDpsHome = New-UiButton -Text 'Copy Setup Notes' -X 370 -Y 17 -Width 145 -Height 36
$btnCopyDpsHome.Add_Click({ try { Copy-ZdpsSettings } catch { Show-FriendlyError -Title 'Could not copy notes' -Exception $_.Exception } })
$step4.Controls.Add($btnCopyDpsHome)
$setupPanel.Controls.Add($step4)

$step5 = New-UiCard -X 0 -Y 420 -Width 535 -Height 100
[void](Add-CardTitle -Parent $step5 -Text '5. Start & Play')
[void](Add-CardHelp -Parent $step5 -Text 'Next time: Start Relay, then play.' -Y 34 -Width 300)
$script:btnPreflight = New-UiButton -Text 'Run Check' -X 14 -Y 59 -Width 105 -Height 32
$script:btnPreflight.Add_Click({ try { Show-Preflight } catch { Show-FriendlyError -Title 'Check could not finish' -Exception $_.Exception } })
$step5.Controls.Add($script:btnPreflight)
$script:btnStart = New-UiButton -Text 'Start Relay' -X 128 -Y 59 -Width 135 -Height 32 -Primary
$script:btnStart.Add_Click({ try { Start-Relay } catch { Show-FriendlyError -Title 'Could not start relay' -Exception $_.Exception } })
$step5.Controls.Add($script:btnStart)
$script:btnStop = New-UiButton -Text 'Stop Relay' -X 272 -Y 59 -Width 110 -Height 32 -Danger
$script:btnStop.Add_Click({ try { Stop-Relay } catch { Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception } })
$step5.Controls.Add($script:btnStop)
$setupPanel.Controls.Add($step5)

# HOME - status and next action
$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(560, 10)
$statusPanel.Size = New-Object System.Drawing.Size(330, 520)
$statusPanel.BackColor = $Ui.Background
$homeTab.Controls.Add($statusPanel)

$statusTitle = New-Object System.Windows.Forms.Label
$statusTitle.Text = 'Status'
$statusTitle.Location = New-Object System.Drawing.Point(0, 0)
$statusTitle.Size = New-Object System.Drawing.Size(320, 25)
$statusTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$statusTitle.ForeColor = $Ui.Text
$statusPanel.Controls.Add($statusTitle)

$script:lblRelayState = New-StatusCard -Parent $statusPanel -Title 'Relay' -X 0 -Y 30 -Width 160
$script:lblProfileState = New-StatusCard -Parent $statusPanel -Title 'Phone Profile' -X 170 -Y 30 -Width 160
$script:lblRuntimeState = New-StatusCard -Parent $statusPanel -Title 'PC Setup' -X 0 -Y 104 -Width 160
$script:lblFirewallState = New-StatusCard -Parent $statusPanel -Title 'Firewall' -X 170 -Y 104 -Width 160

$nextCard = New-UiCard -X 0 -Y 178 -Width 330 -Height 88
[void](Add-CardTitle -Parent $nextCard -Text 'What to do next')
$script:lblNextAction = New-Object System.Windows.Forms.Label
$script:lblNextAction.Text = 'Checking your setup...'
$script:lblNextAction.Location = New-Object System.Drawing.Point(14, 37)
$script:lblNextAction.Size = New-Object System.Drawing.Size(300, 38)
$script:lblNextAction.ForeColor = $Ui.Neutral
$nextCard.Controls.Add($script:lblNextAction)
$statusPanel.Controls.Add($nextCard)

$quickCard = New-UiCard -X 0 -Y 276 -Width 330 -Height 178
[void](Add-CardTitle -Parent $quickCard -Text 'Quick guide')
$quickText = New-Object System.Windows.Forms.Label
$quickText.Text = "First time`r`n1. Prepare Relay`r`n2. Allow Firewall`r`n3. Send to Phone`r`n4. Import in SFA`r`n5. Start Relay`r`n`r`nNext time`r`nStart Relay, then play."
$quickText.Location = New-Object System.Drawing.Point(14, 37)
$quickText.Size = New-Object System.Drawing.Size(300, 130)
$quickText.ForeColor = $Ui.Neutral
$quickCard.Controls.Add($quickText)
$statusPanel.Controls.Add($quickCard)

$targetCard = New-UiCard -X 0 -Y 464 -Width 330 -Height 56
$targetTitle = New-Object System.Windows.Forms.Label
$targetTitle.Text = 'DPS meter target'
$targetTitle.Location = New-Object System.Drawing.Point(14, 8)
$targetTitle.Size = New-Object System.Drawing.Size(130, 18)
$targetTitle.ForeColor = $Ui.Muted
$targetCard.Controls.Add($targetTitle)
$targetValue = New-Object System.Windows.Forms.Label
$targetValue.Text = 'StarSEA'
$targetValue.Location = New-Object System.Drawing.Point(14, 29)
$targetValue.Size = New-Object System.Drawing.Size(280, 20)
$targetValue.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$targetValue.ForeColor = $Ui.Text
$targetCard.Controls.Add($targetValue)
$statusPanel.Controls.Add($targetCard)

# DETAILS - advanced tools and technical logs
$detailsTitle = New-Object System.Windows.Forms.Label
$detailsTitle.Text = 'Details & Troubleshooting'
$detailsTitle.Location = New-Object System.Drawing.Point(20, 18)
$detailsTitle.Size = New-Object System.Drawing.Size(500, 28)
$detailsTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$detailsTitle.ForeColor = $Ui.Text
$detailsTab.Controls.Add($detailsTitle)

$detailsHelp = New-Object System.Windows.Forms.Label
$detailsHelp.Text = 'You normally do not need this page.'
$detailsHelp.Location = New-Object System.Drawing.Point(22, 49)
$detailsHelp.Size = New-Object System.Drawing.Size(500, 22)
$detailsHelp.ForeColor = $Ui.Muted
$detailsTab.Controls.Add($detailsHelp)

$btnDiag = New-UiButton -Text 'Copy Report' -X 22 -Y 80 -Width 125 -Height 36
$btnDiag.Add_Click({ try { Copy-Diagnostics } catch { Show-FriendlyError -Title 'Could not copy report' -Exception $_.Exception } })
$detailsTab.Controls.Add($btnDiag)

$btnCopyDps = New-UiButton -Text 'Copy DPS Notes' -X 157 -Y 80 -Width 135 -Height 36
$btnCopyDps.Add_Click({ try { Copy-ZdpsSettings } catch { Show-FriendlyError -Title 'Could not copy notes' -Exception $_.Exception } })
$detailsTab.Controls.Add($btnCopyDps)

$script:btnStopDetails = New-UiButton -Text 'Stop Relay' -X 302 -Y 80 -Width 115 -Height 36 -Danger
$script:btnStopDetails.Add_Click({ try { Stop-Relay } catch { Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception } })
$detailsTab.Controls.Add($script:btnStopDetails)

$script:btnRollback = New-UiButton -Text 'Restore Previous Version' -X 427 -Y 80 -Width 180 -Height 36
$script:btnRollback.Add_Click({ try { Restore-PreviousRuntime } catch { Show-FriendlyError -Title 'Could not restore previous version' -Exception $_.Exception } })
$detailsTab.Controls.Add($script:btnRollback)

$btnFolderDetails = New-UiButton -Text 'Open Profile Folder' -X 617 -Y 80 -Width 155 -Height 36
$btnFolderDetails.Add_Click({ try { Open-ProfileFolder } catch { Show-FriendlyError -Title 'Could not open folder' -Exception $_.Exception } })
$detailsTab.Controls.Add($btnFolderDetails)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = 'Logs'
$logLabel.Location = New-Object System.Drawing.Point(20, 135)
$logLabel.Size = New-Object System.Drawing.Size(100, 22)
$logLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$logLabel.ForeColor = $Ui.Text
$detailsTab.Controls.Add($logLabel)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Location = New-Object System.Drawing.Point(22, 161)
$script:txtLog.Size = New-Object System.Drawing.Size(850, 335)
$script:txtLog.Multiline = $true
$script:txtLog.ReadOnly = $true
$script:txtLog.ScrollBars = 'Vertical'
$script:txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:txtLog.BackColor = [System.Drawing.Color]::White
$detailsTab.Controls.Add($script:txtLog)

$detailsNote = New-Object System.Windows.Forms.Label
$detailsNote.Text = 'Closing this window does not stop the relay. Use Stop Relay when you want it stopped.'
$detailsNote.Location = New-Object System.Drawing.Point(22, 508)
$detailsNote.Size = New-Object System.Drawing.Size(850, 22)
$detailsNote.ForeColor = $Ui.Muted
$detailsTab.Controls.Add($detailsNote)

# HELP - short English only
$helpTitle = New-Object System.Windows.Forms.Label
$helpTitle.Text = 'Simple Help'
$helpTitle.Location = New-Object System.Drawing.Point(22, 18)
$helpTitle.Size = New-Object System.Drawing.Size(400, 30)
$helpTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$helpTitle.ForeColor = $Ui.Text
$helpTab.Controls.Add($helpTitle)

$firstHelp = New-UiCard -X 22 -Y 62 -Width 420 -Height 205
[void](Add-CardTitle -Parent $firstHelp -Text 'First time')
$firstText = New-Object System.Windows.Forms.Label
$firstText.Text = "1. Click Prepare Relay`r`n`r`n2. Click Allow Firewall`r`n`r`n3. Click Send to Phone`r`n`r`n4. Import the profile in SFA`r`n   Select BPSR only`r`n`r`n5. Click Start Relay, then play"
$firstText.Location = New-Object System.Drawing.Point(16, 40)
$firstText.Size = New-Object System.Drawing.Size(380, 155)
$firstText.ForeColor = $Ui.Neutral
$firstHelp.Controls.Add($firstText)
$helpTab.Controls.Add($firstHelp)

$dailyHelp = New-UiCard -X 455 -Y 62 -Width 420 -Height 120
[void](Add-CardTitle -Parent $dailyHelp -Text 'Next time')
$dailyText = New-Object System.Windows.Forms.Label
$dailyText.Text = "1. Open BPSR Android Relay`r`n`r`n2. Click Start Relay`r`n`r`n3. Play BPSR"
$dailyText.Location = New-Object System.Drawing.Point(16, 40)
$dailyText.Size = New-Object System.Drawing.Size(380, 70)
$dailyText.ForeColor = $Ui.Neutral
$dailyHelp.Controls.Add($dailyText)
$helpTab.Controls.Add($dailyHelp)

$meterHelp = New-UiCard -X 455 -Y 192 -Width 420 -Height 75
[void](Add-CardTitle -Parent $meterHelp -Text 'DPS meter')
$meterText = New-Object System.Windows.Forms.Label
$meterText.Text = 'Use StarSEA. If asked for Network Device, choose your Wi-Fi or Ethernet.'
$meterText.Location = New-Object System.Drawing.Point(16, 40)
$meterText.Size = New-Object System.Drawing.Size(385, 24)
$meterText.ForeColor = $Ui.Neutral
$meterHelp.Controls.Add($meterText)
$helpTab.Controls.Add($meterHelp)

$problemHelp = New-UiCard -X 22 -Y 280 -Width 853 -Height 220
[void](Add-CardTitle -Parent $problemHelp -Text 'Common problems')
$problemText = New-Object System.Windows.Forms.Label
$problemText.Text = "Old relay found`r`nClose old relay apps, or restart your PC.`r`n`r`nPhone cannot connect`r`nMake sure phone and PC use the same Wi-Fi. Click Allow Firewall again.`r`n`r`nDPS meter shows nothing`r`nSet the meter to StarSEA. If it asks for Network Device, choose your Wi-Fi or Ethernet."
$problemText.Location = New-Object System.Drawing.Point(16, 40)
$problemText.Size = New-Object System.Drawing.Size(815, 165)
$problemText.ForeColor = $Ui.Neutral
$problemHelp.Controls.Add($problemText)
$helpTab.Controls.Add($problemHelp)

# Lightweight UI layout self-test for CI. It does not open a window or start the relay.
if ($env:BPSR_RELAY_UI_SELF_TEST -eq '1') {
    function Assert-Inside {
        param($Control, $Parent, [string]$Name)
        if ($Control.Left -lt 0 -or $Control.Top -lt 0 -or $Control.Right -gt $Parent.ClientSize.Width -or $Control.Bottom -gt $Parent.ClientSize.Height) {
            throw ('UI layout overflow: ' + $Name)
        }
    }

    Assert-Inside -Control $addressCard -Parent $setupPanel -Name 'address card'
    Assert-Inside -Control $step1 -Parent $setupPanel -Name 'step 1'
    Assert-Inside -Control $step2 -Parent $setupPanel -Name 'step 2'
    Assert-Inside -Control $step3 -Parent $setupPanel -Name 'step 3'
    Assert-Inside -Control $step4 -Parent $setupPanel -Name 'step 4'
    Assert-Inside -Control $step5 -Parent $setupPanel -Name 'step 5'
    Assert-Inside -Control $nextCard -Parent $statusPanel -Name 'next action'
    Assert-Inside -Control $quickCard -Parent $statusPanel -Name 'quick guide'
    Assert-Inside -Control $targetCard -Parent $statusPanel -Name 'DPS target'

    if ($tabs.TabPages.Count -ne 3) { throw 'UI must contain exactly Home, Details, and Help tabs.' }
    if ($homeTab.Text -ne 'Home' -or $detailsTab.Text -ne 'Details' -or $helpTab.Text -ne 'Help') { throw 'Simple UI tab names changed unexpectedly.' }
    if ($script:btnStart.Text -ne 'Start Relay' -or $script:btnSetup.Text -ne 'Prepare Relay') { throw 'Primary simple-action wording changed unexpectedly.' }
    if ($dpsText.Text -notmatch 'StarSEA') { throw 'DPS meter target is missing from Home.' }

    Write-Host 'UI SELF-TEST PASS: guided Home layout fits, simple tabs/actions present, StarSEA target visible.'
    return
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-Status })
$timer.Start()

Update-Status
Add-Log ('Ready - manager ' + $ManagerVersion + '.')
Add-Log 'DPS meter target: StarSEA.'
Add-Log ('Tested relay core: sing-box ' + $TestedSingBoxVersion + '.')

[void]$form.ShowDialog()
$timer.Stop()
Stop-ProfileShare
