# BPSR Android Relay - user interface
# This file contains UI only. It does not proxy or inspect gameplay traffic.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Ui = @{
    Background   = [System.Drawing.Color]::FromArgb(244, 247, 251)
    Surface      = [System.Drawing.Color]::White
    SurfaceSoft  = [System.Drawing.Color]::FromArgb(248, 250, 252)
    Text         = [System.Drawing.Color]::FromArgb(15, 23, 42)
    Muted        = [System.Drawing.Color]::FromArgb(100, 116, 139)
    Border       = [System.Drawing.Color]::FromArgb(218, 225, 235)
    Primary      = [System.Drawing.Color]::FromArgb(37, 99, 235)
    PrimarySoft  = [System.Drawing.Color]::FromArgb(239, 246, 255)
    Success      = [System.Drawing.Color]::FromArgb(21, 128, 61)
    Warning      = [System.Drawing.Color]::FromArgb(180, 83, 9)
    Danger       = [System.Drawing.Color]::FromArgb(185, 28, 28)
    Neutral      = [System.Drawing.Color]::FromArgb(71, 85, 105)
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
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.UseVisualStyleBackColor = $false
    $button.BackColor = $Ui.Surface
    $button.ForeColor = $Ui.Text
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = $Ui.Border
    $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.25)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.TabStop = $true

    if ($Primary) {
        $button.BackColor = $Ui.Primary
        $button.ForeColor = [System.Drawing.Color]::White
        $button.FlatAppearance.BorderColor = $Ui.Primary
    }
    elseif ($Danger) {
        $button.ForeColor = $Ui.Danger
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(244, 190, 190)
    }

    return $button
}

function New-UiCard {
    param([int]$X, [int]$Y, [int]$Width, [int]$Height)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($Width, $Height)
    $panel.BackColor = $Ui.Surface
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $panel.Add_Paint({
        param($sender, $eventArgs)
        $pen = New-Object System.Drawing.Pen($Ui.Border)
        try {
            $eventArgs.Graphics.DrawRectangle($pen, 0, 0, ($sender.ClientSize.Width - 1), ($sender.ClientSize.Height - 1))
        }
        finally { $pen.Dispose() }
    })
    return $panel
}

function Add-CardTitle {
    param($Parent, [string]$Text, [int]$Y = 10)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point(16, $Y)
    $label.Size = New-Object System.Drawing.Size(($Parent.Width - 32), 22)
    $label.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $label.ForeColor = $Ui.Text
    $label.AutoEllipsis = $true
    $Parent.Controls.Add($label)
    return $label
}

function Add-CardHelp {
    param($Parent, [string]$Text, [int]$Y, [int]$Width = 330, [int]$Height = 34)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point(16, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.ForeColor = $Ui.Muted
    $label.AutoEllipsis = $true
    $Parent.Controls.Add($label)
    return $label
}

function New-StatusRow {
    param($Parent, [string]$Title, [int]$Y)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Location = New-Object System.Drawing.Point(16, $Y)
    $titleLabel.Size = New-Object System.Drawing.Size(135, 23)
    $titleLabel.ForeColor = $Ui.Muted
    $Parent.Controls.Add($titleLabel)

    $value = New-Object System.Windows.Forms.Label
    $value.Text = 'Checking...'
    $value.Location = New-Object System.Drawing.Point(148, $Y)
    $value.Size = New-Object System.Drawing.Size(($Parent.Width - 164), 23)
    $value.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $value.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
    $value.ForeColor = $Ui.Neutral
    $value.AutoEllipsis = $true
    $Parent.Controls.Add($value)

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
            return "Something went wrong.`r`n`r`nOpen Details and check Logs for more information."
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

# Keep full check details in Logs, but show a short result to normal users.
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
        Set-UiStatusLabel -Label $script:lblFirewallState -Text 'Not checked' -State 'Neutral'
        $script:lblNextAction.Text = 'Relay is running. Open BPSR on your phone and play.'
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
        $script:lblNextAction.Text = 'Click Prepare Relay to set up this PC.'
    }
    elseif (-not $profileReady) {
        $script:lblNextAction.Text = 'Click Prepare Relay to refresh the phone profile.'
    }
    elseif (-not $firewallReady) {
        $script:lblNextAction.Text = 'Click Allow Firewall so your phone can connect.'
    }
    elseif ($script:shareProcess) {
        $script:lblNextAction.Text = 'Phone link is ready. Scan the QR code or copy the link.'
    }
    else {
        $script:lblNextAction.Text = 'Setup is ready. Click Start Relay.'
    }

    Update-UiButtonStates -Running $false -ProfileReady $profileReady -RuntimeReady $runtimeReady -ForeignRelay $foreign
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'BPSR Android Relay'
$form.ClientSize = New-Object System.Drawing.Size(964, 690)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.BackColor = $Ui.Background
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.25)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$title = New-Object System.Windows.Forms.Label
$title.Text = 'BPSR Android Relay'
$title.Location = New-Object System.Drawing.Point(24, 16)
$title.Size = New-Object System.Drawing.Size(650, 31)
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 17)
$title.ForeColor = $Ui.Text
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Use your phone with a compatible DPS meter'
$subtitle.Location = New-Object System.Drawing.Point(27, 49)
$subtitle.Size = New-Object System.Drawing.Size(650, 22)
$subtitle.ForeColor = $Ui.Muted
$form.Controls.Add($subtitle)

$versionLabel = New-Object System.Windows.Forms.Label
$versionLabel.Text = 'v' + $ManagerVersion
$versionLabel.Location = New-Object System.Drawing.Point(805, 26)
$versionLabel.Size = New-Object System.Drawing.Size(128, 20)
$versionLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$versionLabel.ForeColor = $Ui.Muted
$form.Controls.Add($versionLabel)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(20, 83)
$tabs.Size = New-Object System.Drawing.Size(924, 585)
$tabs.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$tabs.Appearance = [System.Windows.Forms.TabAppearance]::FlatButtons
$tabs.SizeMode = [System.Windows.Forms.TabSizeMode]::Fixed
$tabs.ItemSize = New-Object System.Drawing.Size(92, 31)
$tabs.Padding = New-Object System.Drawing.Point(14, 5)
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

# HOME - guided setup
$setupPanel = New-Object System.Windows.Forms.Panel
$setupPanel.Location = New-Object System.Drawing.Point(14, 14)
$setupPanel.Size = New-Object System.Drawing.Size(548, 522)
$setupPanel.BackColor = $Ui.Background
$homeTab.Controls.Add($setupPanel)

$addressCard = New-UiCard -X 0 -Y 0 -Width 548 -Height 70
[void](Add-CardTitle -Parent $addressCard -Text 'This PC' -Y 7)
$script:cmbIp = New-Object System.Windows.Forms.ComboBox
$script:cmbIp.Location = New-Object System.Drawing.Point(16, 35)
$script:cmbIp.Size = New-Object System.Drawing.Size(218, 26)
$script:cmbIp.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
$addressCard.Controls.Add($script:cmbIp)
$addressHint = New-Object System.Windows.Forms.Label
$addressHint.Text = "Usually leave this as-is.`r`nPhone and PC must use the same Wi-Fi."
$addressHint.Location = New-Object System.Drawing.Point(250, 30)
$addressHint.Size = New-Object System.Drawing.Size(280, 34)
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

$step1 = New-UiCard -X 0 -Y 80 -Width 548 -Height 70
[void](Add-CardTitle -Parent $step1 -Text '1. Prepare Relay' -Y 10)
[void](Add-CardHelp -Parent $step1 -Text 'Set up the relay on this PC. Do this first.' -Y 36 -Width 338 -Height 24)
$script:btnSetup = New-UiButton -Text 'Prepare Relay' -X 382 -Y 17 -Width 148 -Height 36 -Primary
$script:btnSetup.Add_Click({ try { Setup-Relay } catch { Show-FriendlyError -Title 'Could not prepare relay' -Exception $_.Exception } })
$step1.Controls.Add($script:btnSetup)
$setupPanel.Controls.Add($step1)

$step2 = New-UiCard -X 0 -Y 160 -Width 548 -Height 70
[void](Add-CardTitle -Parent $step2 -Text '2. Allow Firewall' -Y 10)
[void](Add-CardHelp -Parent $step2 -Text 'Allow your phone to reach the relay on this PC.' -Y 36 -Width 338 -Height 24)
$script:btnFirewall = New-UiButton -Text 'Allow Firewall' -X 382 -Y 17 -Width 148 -Height 36
$script:btnFirewall.Add_Click({ try { Allow-Firewall } catch { Show-FriendlyError -Title 'Could not allow connection' -Exception $_.Exception } })
$step2.Controls.Add($script:btnFirewall)
$setupPanel.Controls.Add($step2)

$step3 = New-UiCard -X 0 -Y 240 -Width 548 -Height 102
[void](Add-CardTitle -Parent $step3 -Text '3. Send to Phone' -Y 9)
[void](Add-CardHelp -Parent $step3 -Text 'Import the profile in SFA, then select BPSR only.' -Y 34 -Width 500 -Height 23)
$script:btnShare = New-UiButton -Text 'Send to Phone' -X 16 -Y 62 -Width 128 -Height 30 -Primary
$script:btnShare.Add_Click({ try { Start-ProfileShare } catch { Show-FriendlyError -Title 'Could not send profile' -Exception $_.Exception } })
$step3.Controls.Add($script:btnShare)
$script:btnQr = New-UiButton -Text 'Show QR' -X 152 -Y 62 -Width 92 -Height 30
$script:btnQr.Add_Click({ try { Show-ShareQr } catch { Show-FriendlyError -Title 'Could not show QR' -Exception $_.Exception } })
$step3.Controls.Add($script:btnQr)
$script:btnUrl = New-UiButton -Text 'Copy Link' -X 252 -Y 62 -Width 92 -Height 30
$script:btnUrl.Add_Click({ try { Copy-ShareUrl } catch { Show-FriendlyError -Title 'Could not copy link' -Exception $_.Exception } })
$step3.Controls.Add($script:btnUrl)
$script:btnFolder = New-UiButton -Text 'Open Folder' -X 352 -Y 62 -Width 112 -Height 30
$script:btnFolder.Add_Click({ try { Open-ProfileFolder } catch { Show-FriendlyError -Title 'Could not open folder' -Exception $_.Exception } })
$step3.Controls.Add($script:btnFolder)
$setupPanel.Controls.Add($step3)

$step4 = New-UiCard -X 0 -Y 352 -Width 548 -Height 70
[void](Add-CardTitle -Parent $step4 -Text '4. DPS Meter' -Y 10)
$dpsText = New-Object System.Windows.Forms.Label
$dpsText.Text = 'Set your DPS meter to StarSEA.'
$dpsText.Location = New-Object System.Drawing.Point(16, 37)
$dpsText.Size = New-Object System.Drawing.Size(330, 22)
$dpsText.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$dpsText.ForeColor = $Ui.Text
$step4.Controls.Add($dpsText)
$btnCopyDpsHome = New-UiButton -Text 'Copy Setup Notes' -X 382 -Y 17 -Width 148 -Height 36
$btnCopyDpsHome.Add_Click({ try { Copy-ZdpsSettings } catch { Show-FriendlyError -Title 'Could not copy notes' -Exception $_.Exception } })
$step4.Controls.Add($btnCopyDpsHome)
$setupPanel.Controls.Add($step4)

$step5 = New-UiCard -X 0 -Y 432 -Width 548 -Height 90
[void](Add-CardTitle -Parent $step5 -Text '5. Start & Play' -Y 9)
[void](Add-CardHelp -Parent $step5 -Text 'Run Check if needed. Then start the relay and play.' -Y 34 -Width 500 -Height 23)
$script:btnPreflight = New-UiButton -Text 'Run Check' -X 16 -Y 57 -Width 105 -Height 27
$script:btnPreflight.Add_Click({ try { Show-Preflight } catch { Show-FriendlyError -Title 'Check could not finish' -Exception $_.Exception } })
$step5.Controls.Add($script:btnPreflight)
$script:btnStart = New-UiButton -Text 'Start Relay' -X 129 -Y 57 -Width 134 -Height 27 -Primary
$script:btnStart.Add_Click({ try { Start-Relay } catch { Show-FriendlyError -Title 'Could not start relay' -Exception $_.Exception } })
$step5.Controls.Add($script:btnStart)
$script:btnStop = New-UiButton -Text 'Stop Relay' -X 271 -Y 57 -Width 108 -Height 27 -Danger
$script:btnStop.Add_Click({ try { Stop-Relay } catch { Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception } })
$step5.Controls.Add($script:btnStop)
$setupPanel.Controls.Add($step5)

# HOME - compact status, next action and daily use
$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(578, 14)
$statusPanel.Size = New-Object System.Drawing.Size(316, 522)
$statusPanel.BackColor = $Ui.Background
$homeTab.Controls.Add($statusPanel)

$statusCard = New-UiCard -X 0 -Y 0 -Width 316 -Height 190
[void](Add-CardTitle -Parent $statusCard -Text 'Status' -Y 10)
$script:lblRelayState = New-StatusRow -Parent $statusCard -Title 'Relay' -Y 44
$script:lblRuntimeState = New-StatusRow -Parent $statusCard -Title 'PC setup' -Y 78
$script:lblProfileState = New-StatusRow -Parent $statusCard -Title 'Phone profile' -Y 112
$script:lblFirewallState = New-StatusRow -Parent $statusCard -Title 'Firewall' -Y 146
$statusPanel.Controls.Add($statusCard)

$nextCard = New-UiCard -X 0 -Y 202 -Width 316 -Height 108
[void](Add-CardTitle -Parent $nextCard -Text 'What to do next' -Y 10)
$script:lblNextAction = New-Object System.Windows.Forms.Label
$script:lblNextAction.Text = 'Checking your setup...'
$script:lblNextAction.Location = New-Object System.Drawing.Point(16, 43)
$script:lblNextAction.Size = New-Object System.Drawing.Size(284, 52)
$script:lblNextAction.ForeColor = $Ui.Neutral
$nextCard.Controls.Add($script:lblNextAction)
$statusPanel.Controls.Add($nextCard)

$quickCard = New-UiCard -X 0 -Y 322 -Width 316 -Height 100
[void](Add-CardTitle -Parent $quickCard -Text 'Daily use' -Y 10)
$quickText = New-Object System.Windows.Forms.Label
$quickText.Text = "After the first setup:`r`nOpen app  ->  Start Relay  ->  Play"
$quickText.Location = New-Object System.Drawing.Point(16, 43)
$quickText.Size = New-Object System.Drawing.Size(284, 44)
$quickText.ForeColor = $Ui.Neutral
$quickCard.Controls.Add($quickText)
$statusPanel.Controls.Add($quickCard)

$targetCard = New-UiCard -X 0 -Y 434 -Width 316 -Height 88
$targetTitle = New-Object System.Windows.Forms.Label
$targetTitle.Text = 'DPS meter target'
$targetTitle.Location = New-Object System.Drawing.Point(16, 11)
$targetTitle.Size = New-Object System.Drawing.Size(200, 20)
$targetTitle.ForeColor = $Ui.Muted
$targetCard.Controls.Add($targetTitle)
$targetValue = New-Object System.Windows.Forms.Label
$targetValue.Text = 'StarSEA'
$targetValue.Location = New-Object System.Drawing.Point(16, 38)
$targetValue.Size = New-Object System.Drawing.Size(284, 30)
$targetValue.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$targetValue.ForeColor = $Ui.Text
$targetCard.Controls.Add($targetValue)
$statusPanel.Controls.Add($targetCard)

# DETAILS - advanced tools and technical logs
$detailsTitle = New-Object System.Windows.Forms.Label
$detailsTitle.Text = 'Details & Troubleshooting'
$detailsTitle.Location = New-Object System.Drawing.Point(22, 18)
$detailsTitle.Size = New-Object System.Drawing.Size(500, 28)
$detailsTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$detailsTitle.ForeColor = $Ui.Text
$detailsTab.Controls.Add($detailsTitle)

$detailsHelp = New-Object System.Windows.Forms.Label
$detailsHelp.Text = 'You normally do not need this page.'
$detailsHelp.Location = New-Object System.Drawing.Point(24, 48)
$detailsHelp.Size = New-Object System.Drawing.Size(500, 22)
$detailsHelp.ForeColor = $Ui.Muted
$detailsTab.Controls.Add($detailsHelp)

$toolsCard = New-UiCard -X 22 -Y 76 -Width 850 -Height 74
$toolsLabel = New-Object System.Windows.Forms.Label
$toolsLabel.Text = 'Tools'
$toolsLabel.Location = New-Object System.Drawing.Point(14, 8)
$toolsLabel.Size = New-Object System.Drawing.Size(80, 20)
$toolsLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$toolsLabel.ForeColor = $Ui.Muted
$toolsCard.Controls.Add($toolsLabel)

$btnDiag = New-UiButton -Text 'Copy Report' -X 14 -Y 32 -Width 120 -Height 31
$btnDiag.Add_Click({ try { Copy-Diagnostics } catch { Show-FriendlyError -Title 'Could not copy report' -Exception $_.Exception } })
$toolsCard.Controls.Add($btnDiag)

$btnCopyDps = New-UiButton -Text 'Copy DPS Notes' -X 142 -Y 32 -Width 130 -Height 31
$btnCopyDps.Add_Click({ try { Copy-ZdpsSettings } catch { Show-FriendlyError -Title 'Could not copy notes' -Exception $_.Exception } })
$toolsCard.Controls.Add($btnCopyDps)

$script:btnStopDetails = New-UiButton -Text 'Stop Relay' -X 280 -Y 32 -Width 108 -Height 31 -Danger
$script:btnStopDetails.Add_Click({ try { Stop-Relay } catch { Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception } })
$toolsCard.Controls.Add($script:btnStopDetails)

$script:btnRollback = New-UiButton -Text 'Restore Previous' -X 396 -Y 32 -Width 150 -Height 31
$script:btnRollback.Add_Click({ try { Restore-PreviousRuntime } catch { Show-FriendlyError -Title 'Could not restore previous version' -Exception $_.Exception } })
$toolsCard.Controls.Add($script:btnRollback)

$btnFolderDetails = New-UiButton -Text 'Open Profile Folder' -X 554 -Y 32 -Width 150 -Height 31
$btnFolderDetails.Add_Click({ try { Open-ProfileFolder } catch { Show-FriendlyError -Title 'Could not open folder' -Exception $_.Exception } })
$toolsCard.Controls.Add($btnFolderDetails)
$detailsTab.Controls.Add($toolsCard)

$logsCard = New-UiCard -X 22 -Y 162 -Width 850 -Height 332
$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = 'Logs'
$logLabel.Location = New-Object System.Drawing.Point(14, 11)
$logLabel.Size = New-Object System.Drawing.Size(100, 22)
$logLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$logLabel.ForeColor = $Ui.Text
$logsCard.Controls.Add($logLabel)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Location = New-Object System.Drawing.Point(14, 39)
$script:txtLog.Size = New-Object System.Drawing.Size(820, 278)
$script:txtLog.Multiline = $true
$script:txtLog.ReadOnly = $true
$script:txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:txtLog.BackColor = $Ui.SurfaceSoft
$script:txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$logsCard.Controls.Add($script:txtLog)
$detailsTab.Controls.Add($logsCard)

$detailsNote = New-Object System.Windows.Forms.Label
$detailsNote.Text = 'Closing this window does not stop the relay. Use Stop Relay when you want it stopped.'
$detailsNote.Location = New-Object System.Drawing.Point(24, 507)
$detailsNote.Size = New-Object System.Drawing.Size(840, 22)
$detailsNote.ForeColor = $Ui.Muted
$detailsTab.Controls.Add($detailsNote)

# HELP - concise instructions with room for every line
$helpTitle = New-Object System.Windows.Forms.Label
$helpTitle.Text = 'Simple Help'
$helpTitle.Location = New-Object System.Drawing.Point(22, 18)
$helpTitle.Size = New-Object System.Drawing.Size(400, 30)
$helpTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$helpTitle.ForeColor = $Ui.Text
$helpTab.Controls.Add($helpTitle)

$firstHelp = New-UiCard -X 22 -Y 60 -Width 414 -Height 218
[void](Add-CardTitle -Parent $firstHelp -Text 'First time' -Y 11)
$firstText = New-Object System.Windows.Forms.Label
$firstText.Text = "1. Click Prepare Relay.`r`n`r`n2. Click Allow Firewall.`r`n`r`n3. Click Send to Phone.`r`n`r`n4. Import the profile in SFA and select BPSR only.`r`n`r`n5. Click Start Relay, then play."
$firstText.Location = New-Object System.Drawing.Point(16, 43)
$firstText.Size = New-Object System.Drawing.Size(380, 160)
$firstText.ForeColor = $Ui.Neutral
$firstHelp.Controls.Add($firstText)
$helpTab.Controls.Add($firstHelp)

$dailyHelp = New-UiCard -X 450 -Y 60 -Width 422 -Height 102
[void](Add-CardTitle -Parent $dailyHelp -Text 'Next time' -Y 11)
$dailyText = New-Object System.Windows.Forms.Label
$dailyText.Text = "1. Open BPSR Android Relay.`r`n2. Click Start Relay.`r`n3. Play BPSR."
$dailyText.Location = New-Object System.Drawing.Point(16, 43)
$dailyText.Size = New-Object System.Drawing.Size(388, 50)
$dailyText.ForeColor = $Ui.Neutral
$dailyHelp.Controls.Add($dailyText)
$helpTab.Controls.Add($dailyHelp)

$meterHelp = New-UiCard -X 450 -Y 174 -Width 422 -Height 104
[void](Add-CardTitle -Parent $meterHelp -Text 'DPS meter' -Y 11)
$meterText = New-Object System.Windows.Forms.Label
$meterText.Text = "Capture StarSEA.`r`nIf your meter asks for Network Device, choose your PC Wi-Fi or Ethernet adapter."
$meterText.Location = New-Object System.Drawing.Point(16, 43)
$meterText.Size = New-Object System.Drawing.Size(388, 50)
$meterText.ForeColor = $Ui.Neutral
$meterHelp.Controls.Add($meterText)
$helpTab.Controls.Add($meterHelp)

$problemHelp = New-UiCard -X 22 -Y 292 -Width 850 -Height 220
[void](Add-CardTitle -Parent $problemHelp -Text 'Common problems' -Y 11)
$problemText = New-Object System.Windows.Forms.Label
$problemText.Text = "Old relay found`r`nClose old relay apps, or restart your PC.`r`n`r`nPhone cannot connect`r`nMake sure the phone and PC use the same Wi-Fi, then click Allow Firewall again.`r`n`r`nDPS meter shows nothing`r`nSet the meter to StarSEA. If it asks for Network Device, choose Wi-Fi or Ethernet."
$problemText.Location = New-Object System.Drawing.Point(16, 43)
$problemText.Size = New-Object System.Drawing.Size(818, 164)
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

    function Assert-ChildrenInside {
        param($Parent, [string]$Name)
        foreach ($child in @($Parent.Controls)) {
            Assert-Inside -Control $child -Parent $Parent -Name ($Name + ' > ' + $child.GetType().Name + ' "' + $child.Text + '"')
        }
    }

    function Assert-LabelFits {
        param([System.Windows.Forms.Label]$Label, [string]$Name)
        if (-not $Label -or [string]::IsNullOrWhiteSpace($Label.Text)) { return }
        $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
        $proposed = New-Object System.Drawing.Size($Label.ClientSize.Width, 1000)
        $measured = [System.Windows.Forms.TextRenderer]::MeasureText($Label.Text, $Label.Font, $proposed, $flags)
        if ($measured.Height -gt ($Label.ClientSize.Height + 2)) {
            throw ('UI text clipping: ' + $Name + ' needs ' + $measured.Height + 'px but has ' + $Label.ClientSize.Height + 'px.')
        }
    }

    foreach ($pair in @(
        @($addressCard, $setupPanel, 'address card'),
        @($step1, $setupPanel, 'step 1'),
        @($step2, $setupPanel, 'step 2'),
        @($step3, $setupPanel, 'step 3'),
        @($step4, $setupPanel, 'step 4'),
        @($step5, $setupPanel, 'step 5'),
        @($statusCard, $statusPanel, 'status card'),
        @($nextCard, $statusPanel, 'next action'),
        @($quickCard, $statusPanel, 'daily use'),
        @($targetCard, $statusPanel, 'DPS target'),
        @($toolsCard, $detailsTab, 'details tools'),
        @($logsCard, $detailsTab, 'logs card'),
        @($firstHelp, $helpTab, 'first-time help'),
        @($dailyHelp, $helpTab, 'daily help'),
        @($meterHelp, $helpTab, 'meter help'),
        @($problemHelp, $helpTab, 'problem help')
    )) {
        Assert-Inside -Control $pair[0] -Parent $pair[1] -Name $pair[2]
    }

    foreach ($parent in @($addressCard, $step1, $step2, $step3, $step4, $step5, $statusCard, $nextCard, $quickCard, $targetCard, $toolsCard, $logsCard, $firstHelp, $dailyHelp, $meterHelp, $problemHelp)) {
        Assert-ChildrenInside -Parent $parent -Name $parent.GetType().Name
    }

    Assert-LabelFits -Label $addressHint -Name 'This PC hint'
    Assert-LabelFits -Label $script:lblNextAction -Name 'What to do next'
    Assert-LabelFits -Label $quickText -Name 'Daily use'
    Assert-LabelFits -Label $firstText -Name 'First-time help'
    Assert-LabelFits -Label $dailyText -Name 'Next-time help'
    Assert-LabelFits -Label $meterText -Name 'DPS meter help'
    Assert-LabelFits -Label $problemText -Name 'Common problems'

    if ($tabs.TabPages.Count -ne 3) { throw 'UI must contain exactly Home, Details, and Help tabs.' }
    if ($homeTab.Text -ne 'Home' -or $detailsTab.Text -ne 'Details' -or $helpTab.Text -ne 'Help') { throw 'Simple UI tab names changed unexpectedly.' }
    if ($script:btnStart.Text -ne 'Start Relay' -or $script:btnSetup.Text -ne 'Prepare Relay') { throw 'Primary simple-action wording changed unexpectedly.' }
    if ($dpsText.Text -notmatch 'StarSEA') { throw 'DPS meter target is missing from Home.' }
    if ($targetValue.Text -ne 'StarSEA') { throw 'DPS target card changed unexpectedly.' }

    Write-Host 'UI SELF-TEST PASS: Home/Details/Help fit, key labels have measured text room, simple actions present, StarSEA target visible.'
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
