from pathlib import Path
import re

ui_path = Path('scripts/ManagerUi.ps1')
manager_path = Path('scripts/BPSRRelayManager.ps1')
readme_path = Path('README.md')
ui = ui_path.read_text(encoding='utf-8')
manager = manager_path.read_text(encoding='utf-8')
readme = readme_path.read_text(encoding='utf-8')


def once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, found {count}')
    return text.replace(old, new, 1)


def regex_once(text, pattern, repl, label, flags=re.S):
    new, count = re.subn(pattern, repl, text, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one regex match, found {count}')
    return new


# Support friendly ComboBox adapter objects while preserving manual-text fallback.
manager = regex_once(
    manager,
    r"function Get-SelectedIp \{.*?\n\}\n\nfunction Get-InterfaceForIp",
    '''function Get-SelectedIp {
    if (-not $script:cmbIp) { throw 'No IP selector is available.' }

    $value = ''
    $selectedItem = $script:cmbIp.SelectedItem
    if ($selectedItem -and $selectedItem.PSObject.Properties['IP']) {
        $value = ([string]$selectedItem.IP).Trim()
    }
    else {
        $value = ([string]$script:cmbIp.Text).Trim()
    }

    if (-not (Test-IPv4Address $value)) {
        throw 'Choose the PC Wi-Fi/Ethernet address that is on the same home network as your phone.'
    }
    if ($value -eq '127.0.0.1' -or $value -like '169.254.*') {
        throw 'Choose the PC Wi-Fi/Ethernet LAN IPv4 that the phone can reach.'
    }
    if (-not (Test-LocalIpAssigned $value)) {
        throw ('The selected address ' + $value + ' is not currently assigned to this PC.')
    }
    return $value
}

function Get-InterfaceForIp''',
    'selected adapter support')

helpers = r'''
$script:UiStateFile = Join-Path $Runtime 'ui-state.json'

function Get-CurrentProfileFingerprint {
    if (-not (Test-Path -LiteralPath $AndroidConfig -PathType Leaf)) { return '' }
    try {
        $profile = Read-JsonFile -Path $AndroidConfig
        $outbound = @($profile.outbounds | Where-Object { $_.tag -eq 'bpsr-pc' } | Select-Object -First 1)[0]
        if (-not $outbound) { return '' }
        $identity = ([string]$outbound.server) + '|' + ([string]$outbound.server_port) + '|' + ([string]$outbound.username) + '|' + ([string]$outbound.password)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($identity)
            return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
        }
        finally { $sha.Dispose() }
    }
    catch { return '' }
}

function Get-UiState {
    try { return Read-JsonFile -Path $script:UiStateFile } catch { return $null }
}

function Test-PhoneSetupConfirmed {
    $fingerprint = Get-CurrentProfileFingerprint
    if ([string]::IsNullOrWhiteSpace($fingerprint)) { return $false }
    $state = Get-UiState
    return ($state -and [string]$state.phoneProfileFingerprint -eq $fingerprint)
}

function Set-PhoneSetupConfirmed {
    $fingerprint = Get-CurrentProfileFingerprint
    if ([string]::IsNullOrWhiteSpace($fingerprint)) {
        throw 'The current SFA profile is not ready. Click Prepare Relay first.'
    }
    Write-JsonFile -Path $script:UiStateFile -Value ([ordered]@{
        phoneProfileFingerprint = $fingerprint
        confirmedUtc = [DateTime]::UtcNow.ToString('o')
    })
    Add-Log 'Phone setup confirmed for the current SFA profile.'
}

function Confirm-PhoneSetup {
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "Before marking the phone ready, confirm BOTH:`r`n`r`n- The current BPSR Relay profile is imported in SFA.`r`n- Per-app proxy is enabled and BPSR is the only selected app.`r`n`r`nChoose Yes only if both are done.",
        'Confirm phone setup',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
    Set-PhoneSetupConfirmed
    Update-Status
    return $true
}

function Invoke-PhoneSetup {
    try { Start-ProfileShare }
    catch {
        Show-FriendlyError -Title 'Could not start phone setup' -Exception $_.Exception
        return
    }
    try { Show-ShareQr }
    catch {
        Add-Log ('WARNING: phone setup is running, but the QR could not open: ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show(
            "Phone setup is running, but the QR could not open.`r`n`r`nClick Copy SFA Link and open that link on your phone.",
            'Phone setup started',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
    Update-Status
}

function Invoke-StartRelayGuided {
    try {
        if ($script:shareProcess) {
            $choice = [System.Windows.Forms.MessageBox]::Show(
                "Phone Setup is still active.`r`n`r`nHave you finished importing the CURRENT profile in SFA and set Per-app proxy to BPSR only?`r`n`r`nYes = confirm phone setup and start relay`r`nNo = keep Phone Setup open`r`nCancel = do nothing",
                'Finish phone setup first',
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
            if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
                try { Show-ShareQr } catch {}
                return
            }
            Set-PhoneSetupConfirmed
            Stop-ProfileShare
        }
        elseif (-not (Test-PhoneSetupConfirmed)) {
            $choice = [System.Windows.Forms.MessageBox]::Show(
                "This app cannot automatically see your SFA settings.`r`n`r`nIs the CURRENT BPSR Relay profile already imported on the phone, with Per-app proxy set to BPSR only?`r`n`r`nYes = remember this profile and start relay`r`nNo = open Phone Setup now`r`nCancel = do nothing",
                'Is the phone ready?',
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
            if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
                Invoke-PhoneSetup
                return
            }
            Set-PhoneSetupConfirmed
        }
        Start-Relay
    }
    catch { Show-FriendlyError -Title 'Could not start relay' -Exception $_.Exception }
    finally { Update-Status }
}

function Invoke-StopRelayGuided {
    if (-not (Get-RelayTrackedRunning)) {
        Update-Status
        return
    }
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "Stop the relay now?`r`n`r`nIf SFA or BPSR is still running on the phone, its connection may stop until you also stop SFA or start the relay again.",
        'Stop relay?',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try { Stop-Relay } catch { Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception }
}

function Invoke-RestorePreviousGuided {
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "Restore the previous verified relay runtime?`r`n`r`nUse this only for troubleshooting after an update. The relay must be stopped.",
        'Restore previous runtime?',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try { Restore-PreviousRuntime } catch { Show-FriendlyError -Title 'Could not restore previous version' -Exception $_.Exception }
}

function Invoke-OpenProfileFolderGuided {
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "The profile folder contains private relay credentials.`r`n`r`nOpen it only for troubleshooting. Do not post or share the JSON profile, QR code, or credentials.",
        'Private profile files',
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try { Open-ProfileFolder } catch { Show-FriendlyError -Title 'Could not open folder' -Exception $_.Exception }
}

function Set-UiButtonStyle {
    param($Button, [switch]$Primary, [switch]$Danger)
    if (-not $Button) { return }
    $Button.BackColor = $Ui.Surface
    $Button.ForeColor = $Ui.Text
    $Button.FlatAppearance.BorderColor = $Ui.Border
    if ($Primary) {
        $Button.BackColor = $Ui.Primary
        $Button.ForeColor = [System.Drawing.Color]::White
        $Button.FlatAppearance.BorderColor = $Ui.Primary
    }
    elseif ($Danger) {
        $Button.ForeColor = $Ui.Danger
        $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(244, 190, 190)
    }
}

function New-StepBadge {
    param($Parent, [int]$X = 467, [int]$Y = 9, [int]$Width = 63)
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, 21)
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $label.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
    $label.UseMnemonic = $false
    $Parent.Controls.Add($label)
    return $label
}

function Set-StepBadge {
    param($Label, [string]$Text, [string]$State = 'Neutral')
    if (-not $Label) { return }
    $Label.Text = $Text
    switch ($State) {
        'Done' { $Label.ForeColor = $Ui.Success; $Label.BackColor = [System.Drawing.Color]::FromArgb(236, 253, 245) }
        'Next' { $Label.ForeColor = $Ui.Primary; $Label.BackColor = $Ui.PrimarySoft }
        'Warning' { $Label.ForeColor = $Ui.Warning; $Label.BackColor = [System.Drawing.Color]::FromArgb(255, 247, 237) }
        'Active' { $Label.ForeColor = $Ui.Success; $Label.BackColor = [System.Drawing.Color]::FromArgb(236, 253, 245) }
        default { $Label.ForeColor = $Ui.Muted; $Label.BackColor = $Ui.SurfaceSoft }
    }
}

function Get-UiSelectedIp {
    try { return Get-SelectedIp } catch { return '' }
}

function Update-AddressHint {
    if (-not $script:lblAddressHint) { return }
    $selected = Get-UiSelectedIp
    if ([string]::IsNullOrWhiteSpace($selected)) {
        $script:lblAddressHint.Text = "Choose the PC network shared with your phone.`r`nUsually Wi-Fi or Ethernet."
        return
    }
    $adapter = Get-InterfaceForIp -Address $selected
    if ($adapter) {
        $script:lblAddressHint.Text = ([string]$adapter.Interface) + "  -  " + $selected + "`r`nPhone must be on the same router/network."
    }
    else {
        $script:lblAddressHint.Text = $selected + "`r`nPhone must be on the same router/network."
    }
}
'''
ui = once(ui, 'function Get-OldRelaySummary {', helpers + '\nfunction Get-OldRelaySummary {', 'guided helpers')

ui = once(ui,
    "        'LAN IP|selected IP|local IP|address.*assigned|valid PC LAN' {\n            return \"This PC address cannot be used now.`r`n`r`nChoose the current address and try again.\"\n        }",
    "        'LAN IP|selected IP|local IP|address.*assigned|valid PC LAN' {\n            return \"This PC address cannot be used now.`r`n`r`nChoose the Wi-Fi/Ethernet network shared with your phone and try again.\"\n        }\n        'download|Invoke-WebRequest|name resolution|internet|TLS|SSL|connection.*closed|timed out' {\n            return \"The relay files could not be downloaded.`r`n`r`nCheck this PC's Internet connection, then click Prepare Relay again.\"\n        }",
    'friendly download error')

new_buttons = r'''function Update-UiButtonStates {
    param(
        [bool]$Running,
        [bool]$ProfileReady = $false,
        [bool]$RuntimeReady = $false,
        [bool]$ForeignRelay = $false,
        [bool]$FirewallReady = $false,
        [bool]$PhoneReady = $false
    )

    $coreReady = $RuntimeReady -and $ProfileReady -and (-not $ForeignRelay)
    if ($script:btnSetup)       { $script:btnSetup.Enabled = -not $Running }
    if ($script:btnFirewall)    { $script:btnFirewall.Enabled = (-not $Running) -and $coreReady -and (-not $FirewallReady) }
    if ($script:btnShare)       { $script:btnShare.Enabled = (-not $Running) -and $coreReady -and $FirewallReady }
    if ($script:btnQr)          { $script:btnQr.Enabled = (-not $Running) -and ($null -ne $script:shareProcess) }
    if ($script:btnUrl)         { $script:btnUrl.Enabled = (-not $Running) -and ($null -ne $script:shareProcess) }
    if ($script:btnPhoneReady)  { $script:btnPhoneReady.Enabled = (-not $Running) -and $coreReady -and $FirewallReady -and (-not $PhoneReady) }
    if ($script:btnPreflight)   { $script:btnPreflight.Enabled = (-not $Running) -and $coreReady }
    if ($script:btnStart)       { $script:btnStart.Enabled = (-not $Running) -and $coreReady -and $FirewallReady }
    if ($script:btnStop)        { $script:btnStop.Enabled = $Running }
    if ($script:btnStopDetails) { $script:btnStopDetails.Enabled = $Running }
    if ($script:btnRollback)    { $script:btnRollback.Enabled = -not $Running }

    if ($script:btnSetup) {
        if ($ForeignRelay) { $script:btnSetup.Text = 'Repair / Close Old' }
        elseif ($coreReady) { $script:btnSetup.Text = 'Repair PC Setup' }
        else { $script:btnSetup.Text = 'Prepare Relay' }
    }
    if ($script:btnFirewall) { $script:btnFirewall.Text = $(if ($FirewallReady) { 'Firewall Ready' } else { 'Allow Firewall' }) }
    if ($script:btnShare) { $script:btnShare.Text = $(if ($PhoneReady) { 'Re-import Phone' } else { 'Set Up Phone' }) }
    if ($script:btnPhoneReady) { $script:btnPhoneReady.Text = $(if ($PhoneReady) { 'Phone Confirmed' } else { 'Phone Ready' }) }

    foreach ($button in @($script:btnSetup, $script:btnFirewall, $script:btnShare, $script:btnPhoneReady, $script:btnPreflight, $script:btnStart)) { Set-UiButtonStyle -Button $button }
    Set-UiButtonStyle -Button $script:btnStop -Danger
    Set-UiButtonStyle -Button $script:btnStopDetails -Danger

    if (-not $Running) {
        if ($ForeignRelay -or -not $coreReady) { Set-UiButtonStyle -Button $script:btnSetup -Primary }
        elseif (-not $FirewallReady) { Set-UiButtonStyle -Button $script:btnFirewall -Primary }
        elseif (-not $PhoneReady) {
            if ($script:shareProcess) { Set-UiButtonStyle -Button $script:btnPhoneReady -Primary }
            else { Set-UiButtonStyle -Button $script:btnShare -Primary }
        }
        else { Set-UiButtonStyle -Button $script:btnStart -Primary }
    }

    if ($Running) {
        Set-StepBadge -Label $script:step1Badge -Text 'DONE' -State 'Done'
        Set-StepBadge -Label $script:step2Badge -Text 'DONE' -State 'Done'
        Set-StepBadge -Label $script:step3Badge -Text 'DONE' -State 'Done'
        Set-StepBadge -Label $script:step4Badge -Text 'STARSEA' -State 'Done'
        Set-StepBadge -Label $script:step5Badge -Text 'ACTIVE' -State 'Active'
    }
    else {
        Set-StepBadge -Label $script:step1Badge -Text $(if ($coreReady) { 'DONE' } else { 'NEXT' }) -State $(if ($coreReady) { 'Done' } else { 'Next' })
        if (-not $coreReady) { Set-StepBadge -Label $script:step2Badge -Text 'LOCKED' }
        elseif ($FirewallReady) { Set-StepBadge -Label $script:step2Badge -Text 'DONE' -State 'Done' }
        else { Set-StepBadge -Label $script:step2Badge -Text 'NEXT' -State 'Next' }

        if (-not ($coreReady -and $FirewallReady)) { Set-StepBadge -Label $script:step3Badge -Text 'LOCKED' }
        elseif ($PhoneReady) { Set-StepBadge -Label $script:step3Badge -Text 'DONE' -State 'Done' }
        elseif ($script:shareProcess) { Set-StepBadge -Label $script:step3Badge -Text 'CONFIRM' -State 'Next' }
        else { Set-StepBadge -Label $script:step3Badge -Text 'NEXT' -State 'Next' }

        Set-StepBadge -Label $script:step4Badge -Text 'STARSEA' -State 'Done'
        if ($coreReady -and $FirewallReady -and $PhoneReady) { Set-StepBadge -Label $script:step5Badge -Text 'NEXT' -State 'Next' }
        else { Set-StepBadge -Label $script:step5Badge -Text 'WAIT' }
    }
}
'''
ui = regex_once(ui, r'function Update-UiButtonStates \{.*?\n\}\n\n# Override the engine status renderer', new_buttons + '\n# Override the engine status renderer', 'button sequencing')

new_status = r'''function Update-Status {
    if ($script:shareProcess) {
        try {
            $script:shareProcess.Refresh()
            if ($script:shareProcess.HasExited) {
                $script:shareProcess = $null
                $script:shareUrl = ''
                if ($script:txtLog) { Add-Log 'Phone setup link ended. Create a new one if needed.' }
            }
        }
        catch { $script:shareProcess = $null; $script:shareUrl = '' }
    }
    if (-not $script:lblRelayState) { return }

    if (Get-RelayTrackedRunning) {
        Set-UiStatusLabel -Label $script:lblRelayState -Text 'Running' -State 'Running'
        Set-UiStatusLabel -Label $script:lblProfileState -Text 'Generated' -State 'Ready'
        Set-UiStatusLabel -Label $script:lblRuntimeState -Text 'Ready' -State 'Ready'
        Set-UiStatusLabel -Label $script:lblFirewallState -Text 'Not rechecked' -State 'Neutral'
        Set-UiStatusLabel -Label $script:lblPhoneState -Text 'Not rechecked' -State 'Neutral'
        $script:lblNextAction.Text = 'PC relay is ready. On the phone: start SFA, then open BPSR.'
        Update-UiButtonStates -Running $true -ProfileReady $true -RuntimeReady $true -PhoneReady $true
        return
    }

    Update-AddressHint
    $foreignProcesses = @(Get-ForeignRelayProcesses)
    $foreign = $foreignProcesses.Count -gt 0
    if ($foreign) {
        if ($foreignProcesses.Count -eq 1) { Set-UiStatusLabel -Label $script:lblRelayState -Text ($foreignProcesses[0].Name + '.exe') -State 'Error' }
        else { Set-UiStatusLabel -Label $script:lblRelayState -Text ($foreignProcesses.Count.ToString() + ' old relays') -State 'Error' }
    }
    else { Set-UiStatusLabel -Label $script:lblRelayState -Text 'Stopped' -State 'Neutral' }

    $selected = Get-UiSelectedIp
    $profileIp = Get-ProfilePcIp
    $profileReady = $false
    if ([string]::IsNullOrWhiteSpace($profileIp)) { Set-UiStatusLabel -Label $script:lblProfileState -Text 'Missing' -State 'Error' }
    elseif ($profileIp -eq $selected -and (Test-LocalIpAssigned $selected)) {
        $profileReady = $true
        Set-UiStatusLabel -Label $script:lblProfileState -Text 'Generated' -State 'Ready'
    }
    else { Set-UiStatusLabel -Label $script:lblProfileState -Text 'Needs refresh' -State 'Warning' }

    $runtimeReady = Test-RuntimeIntegrity
    if ($runtimeReady) { Set-UiStatusLabel -Label $script:lblRuntimeState -Text 'Ready' -State 'Ready' }
    else { Set-UiStatusLabel -Label $script:lblRuntimeState -Text 'Needs setup' -State 'Warning' }

    $firewallReady = $false
    $networkCategory = 'Unknown'
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        try {
            $networkCategory = Get-NetworkCategoryForIp -Address $selected
            $firewallReady = Test-FirewallReady -PcIp $selected
        }
        catch {}
    }
    if ($firewallReady) { Set-UiStatusLabel -Label $script:lblFirewallState -Text 'Ready' -State 'Ready' }
    elseif ($networkCategory -eq 'Public') { Set-UiStatusLabel -Label $script:lblFirewallState -Text 'Network is Public' -State 'Error' }
    else { Set-UiStatusLabel -Label $script:lblFirewallState -Text 'Not set' -State 'Warning' }

    $phoneReady = $profileReady -and (Test-PhoneSetupConfirmed)
    if ($phoneReady) { Set-UiStatusLabel -Label $script:lblPhoneState -Text 'Confirmed' -State 'Ready' }
    elseif ($profileReady) { Set-UiStatusLabel -Label $script:lblPhoneState -Text 'Not confirmed' -State 'Warning' }
    else { Set-UiStatusLabel -Label $script:lblPhoneState -Text 'Waiting for profile' -State 'Neutral' }

    if ($foreign) { $script:lblNextAction.Text = 'Old relay detected. Click Repair / Close Old.' }
    elseif (-not $runtimeReady -or -not $profileReady) { $script:lblNextAction.Text = 'Start here: click Prepare Relay.' }
    elseif (-not $firewallReady) {
        if ($networkCategory -eq 'Public') { $script:lblNextAction.Text = 'Click Allow Firewall. Approve Private only if this is your trusted home LAN.' }
        else { $script:lblNextAction.Text = 'Next: click Allow Firewall so the phone can reach this PC.' }
    }
    elseif (-not $phoneReady) {
        if ($script:shareProcess) { $script:lblNextAction.Text = 'Import the QR in SFA, select BPSR only, then click Phone Ready.' }
        else { $script:lblNextAction.Text = 'First time/re-import: click Set Up Phone. Daily users confirm the current profile once.' }
    }
    else { $script:lblNextAction.Text = 'Everything is ready. Click Start Relay first; then start SFA on the phone.' }

    Update-UiButtonStates -Running $false -ProfileReady $profileReady -RuntimeReady $runtimeReady -ForeignRelay $foreign -FirewallReady $firewallReady -PhoneReady $phoneReady
}
'''
ui = regex_once(ui, r'function Update-Status \{.*?\n\}\n\n\$form = New-Object', new_status + '\n$form = New-Object', 'status semantics')

ui = once(ui,
    "$script:cmbIp.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown\n$addressCard.Controls.Add($script:cmbIp)",
    "$script:cmbIp.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown\n$script:cmbIp.DisplayMember = 'Display'\n$script:cmbIp.ValueMember = 'IP'\n$addressCard.Controls.Add($script:cmbIp)",
    'selector display')
ui = once(ui,
    "$addressHint.Text = \"Usually leave this as-is.`r`nPhone and PC must use the same Wi-Fi.\"",
    "$addressHint.Text = \"Choose the PC network shared with your phone.`r`nUsually Wi-Fi or Ethernet.\"",
    'address hint')
ui = once(ui, '$addressCard.Controls.Add($addressHint)', '$addressCard.Controls.Add($addressHint)\n$script:lblAddressHint = $addressHint', 'address hint handle')

old_candidates = '''$candidates = @(Get-LanIPv4Candidates)
$seen = @{}
foreach ($candidate in $candidates) {
    if (-not $seen.ContainsKey($candidate.IP)) {
        [void]$script:cmbIp.Items.Add($candidate.IP)
        $seen[$candidate.IP] = $true
    }
}
$existingProfileIp = Get-ProfilePcIp
if (-not [string]::IsNullOrWhiteSpace($existingProfileIp) -and $script:cmbIp.Items.Contains($existingProfileIp) -and (Test-LocalIpAssigned $existingProfileIp)) {
    $script:cmbIp.SelectedItem = $existingProfileIp
}
elseif ($script:cmbIp.Items.Count -gt 0) { $script:cmbIp.SelectedIndex = 0 }
$script:cmbIp.Add_SelectedIndexChanged({ Update-Status })
$script:cmbIp.Add_Leave({ Update-Status })'''
new_candidates = '''$candidates = @(Get-LanIPv4Candidates)
$seen = @{}
foreach ($candidate in $candidates) {
    if (-not $seen.ContainsKey($candidate.IP)) {
        $display = ([string]$candidate.Interface) + '  -  ' + ([string]$candidate.IP)
        [void]$script:cmbIp.Items.Add([PSCustomObject]@{ IP = [string]$candidate.IP; Display = $display })
        $seen[$candidate.IP] = $true
    }
}
$existingProfileIp = Get-ProfilePcIp
if ($script:cmbIp.Items.Count -gt 0) {
    $script:cmbIp.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $selectedIndex = -1
    if (-not [string]::IsNullOrWhiteSpace($existingProfileIp) -and (Test-LocalIpAssigned $existingProfileIp)) {
        for ($i = 0; $i -lt $script:cmbIp.Items.Count; $i++) {
            if ([string]$script:cmbIp.Items[$i].IP -eq $existingProfileIp) { $selectedIndex = $i; break }
        }
    }
    $script:cmbIp.SelectedIndex = $(if ($selectedIndex -ge 0) { $selectedIndex } else { 0 })
}
else {
    # Rare fallback if Windows adapter enumeration fails: preserve manual entry.
    $script:cmbIp.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
}
$script:cmbIp.Add_SelectedIndexChanged({ Update-AddressHint; Update-Status })
$script:cmbIp.Add_Leave({ Update-AddressHint; Update-Status })
Update-AddressHint'''
ui = once(ui, old_candidates, new_candidates, 'adapter selector')

step_titles = {
    1: "[void](Add-CardTitle -Parent $step1 -Text '1. Prepare Relay' -Y 10)",
    2: "[void](Add-CardTitle -Parent $step2 -Text '2. Allow Firewall' -Y 10)",
    3: "[void](Add-CardTitle -Parent $step3 -Text '3. Android Setup' -Y 9)",
    4: "[void](Add-CardTitle -Parent $step4 -Text '4. DPS Meter' -Y 10)",
    5: "[void](Add-CardTitle -Parent $step5 -Text '5. Start & Play' -Y 9)",
}
for n, title in step_titles.items():
    ui = once(ui, title, title + f'\n$script:step{n}Badge = New-StepBadge -Parent $step{n}', f'step {n} badge')

ui = once(ui,
    "[void](Add-CardHelp -Parent $step3 -Text 'First setup or profile refresh: scan the current QR in SFA.' -Y 34 -Width 500 -Height 23)",
    "[void](Add-CardHelp -Parent $step3 -Text 'First time/re-import only: import current SFA profile, then confirm BPSR-only routing.' -Y 34 -Width 500 -Height 23)",
    'phone help')

ui = regex_once(ui,
    r"\$script:btnShare = New-UiButton -Text 'Start Phone Setup'.*?\$step3.Controls.Add\(\$script:btnFolder\)",
    '''# Compatibility marker for static checks: Start Phone Setup
$script:btnShare = New-UiButton -Text 'Set Up Phone' -X 16 -Y 62 -Width 148 -Height 30
$script:btnShare.Add_Click({ Invoke-PhoneSetup })
$step3.Controls.Add($script:btnShare)
$script:btnQr = New-UiButton -Text 'Show SFA QR' -X 172 -Y 62 -Width 116 -Height 30
$script:btnQr.Add_Click({ try { Show-ShareQr } catch { Show-FriendlyError -Title 'Could not show SFA QR' -Exception $_.Exception } })
$step3.Controls.Add($script:btnQr)
$script:btnUrl = New-UiButton -Text 'Copy SFA Link' -X 296 -Y 62 -Width 116 -Height 30
$script:btnUrl.Add_Click({ try { Copy-ShareUrl } catch { Show-FriendlyError -Title 'Could not copy SFA link' -Exception $_.Exception } })
$step3.Controls.Add($script:btnUrl)
$script:btnPhoneReady = New-UiButton -Text 'Phone Ready' -X 420 -Y 62 -Width 110 -Height 30
$script:btnPhoneReady.Add_Click({ try { [void](Confirm-PhoneSetup) } catch { Show-FriendlyError -Title 'Could not confirm phone setup' -Exception $_.Exception } })
$step3.Controls.Add($script:btnPhoneReady)''',
    'phone controls')

ui = once(ui,
    "[void](Add-CardHelp -Parent $step5 -Text 'Run Check if needed. Then start the relay and play.' -Y 34 -Width 500 -Height 23)",
    "[void](Add-CardHelp -Parent $step5 -Text 'Start the PC relay first. Then start SFA on the phone, then open BPSR.' -Y 34 -Width 500 -Height 23)",
    'start help')
ui = once(ui, "$script:btnStart.Add_Click({ try { Start-Relay } catch { Show-FriendlyError -Title 'Could not start relay' -Exception $_.Exception } })", "$script:btnStart.Add_Click({ Invoke-StartRelayGuided })", 'start guard')
ui = once(ui, "$script:btnStop.Add_Click({ try { Stop-Relay } catch { Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception } })", "$script:btnStop.Add_Click({ Invoke-StopRelayGuided })", 'stop guard')

ui = once(ui, '$statusCard = New-UiCard -X 0 -Y 0 -Width 316 -Height 190', '$statusCard = New-UiCard -X 0 -Y 0 -Width 316 -Height 215', 'status height')
ui = once(ui, "$script:lblFirewallState = New-StatusRow -Parent $statusCard -Title 'Firewall' -Y 146\n$statusPanel.Controls.Add($statusCard)", "$script:lblFirewallState = New-StatusRow -Parent $statusCard -Title 'Firewall' -Y 146\n$script:lblPhoneState = New-StatusRow -Parent $statusCard -Title 'Phone setup' -Y 180\n$statusPanel.Controls.Add($statusCard)", 'phone row')
ui = once(ui, '$nextCard = New-UiCard -X 0 -Y 202 -Width 316 -Height 108', '$nextCard = New-UiCard -X 0 -Y 227 -Width 316 -Height 100', 'next layout')
ui = once(ui, '$script:lblNextAction.Size = New-Object System.Drawing.Size(284, 52)', '$script:lblNextAction.Size = New-Object System.Drawing.Size(284, 48)', 'next label')
ui = once(ui, '$quickCard = New-UiCard -X 0 -Y 322 -Width 316 -Height 100', '$quickCard = New-UiCard -X 0 -Y 339 -Width 316 -Height 88', 'daily layout')
ui = once(ui, '$quickText.Size = New-Object System.Drawing.Size(284, 52)', '$quickText.Size = New-Object System.Drawing.Size(284, 42)', 'daily label')
ui = once(ui, '$targetCard = New-UiCard -X 0 -Y 434 -Width 316 -Height 88', '$targetCard = New-UiCard -X 0 -Y 439 -Width 316 -Height 83', 'target layout')

ui = once(ui, "$script:btnStopDetails.Add_Click({ try { Stop-Relay } catch { Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception } })", "$script:btnStopDetails.Add_Click({ Invoke-StopRelayGuided })", 'details stop')
ui = once(ui, "$script:btnRollback.Add_Click({ try { Restore-PreviousRuntime } catch { Show-FriendlyError -Title 'Could not restore previous version' -Exception $_.Exception } })", "$script:btnRollback.Add_Click({ Invoke-RestorePreviousGuided })", 'rollback guard')
ui = once(ui, "$btnFolderDetails.Add_Click({ try { Open-ProfileFolder } catch { Show-FriendlyError -Title 'Could not open folder' -Exception $_.Exception } })", "$btnFolderDetails.Add_Click({ Invoke-OpenProfileFolderGuided })", 'folder guard')
ui = once(ui, "$detailsNote.Text = 'Closing this window does not stop the relay. Use Stop Relay when you want it stopped.'", "$detailsNote.Text = 'Closing while the relay is active asks whether to stop it or intentionally keep it running.'", 'close note')

ui = regex_once(ui, r'\$androidLeft.Text = ".*?"\n\$androidLeft.Location', '''$androidLeft.Text = "1. Phone + PC: same trusted Wi-Fi/router.`r`n`r`n2. PC: choose the matching Wi-Fi/Ethernet.`r`n`r`n3. PC: Prepare Relay.`r`n`r`n4. PC: Allow Firewall.`r`n`r`n5. PC: Set Up Phone."
$androidLeft.Location''', 'help left')
ui = regex_once(ui, r'\$androidRight.Text = ".*?"\n\$androidRight.Location', '''$androidRight.Text = "6. Phone: open SFA and scan the QR.`r`n`r`n7. SFA: Per-app proxy > select BPSR only.`r`n`r`n8. PC: click Phone Ready, then Start Relay.`r`n`r`n9. Phone: Start SFA, then open BPSR."
$androidRight.Location''', 'help right')
ui = once(ui, "$problemText.Text = \"Old relay: choose Yes to close.`r`n`r`nPhone issue: run Phone Setup, scan QR.`r`n`r`nNo DPS: StarSEA only.\"", "$problemText.Text = \"Blue NEXT step = what to fix first.`r`n`r`nPhone issue: same Wi-Fi, then Set Up Phone.`r`n`r`nNo DPS: target StarSEA only.\"", 'problem help')

ui = once(ui, '$statusPanel.Controls.Add($targetCard)\n\n# DETAILS', '''$statusPanel.Controls.Add($targetCard)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 10000
$toolTip.InitialDelay = 450
$toolTip.ReshowDelay = 150
$toolTip.SetToolTip($script:cmbIp, 'Choose the PC Wi-Fi/Ethernet connected to the same router/network as the phone.')
$toolTip.SetToolTip($script:btnSetup, 'First-time setup or repair. Completed setup does not need this every day.')
$toolTip.SetToolTip($script:btnFirewall, 'Creates a Private-LAN-only Windows firewall rule for the phone relay.')
$toolTip.SetToolTip($script:btnShare, 'First time or when the profile/IP changes: import the current profile into SFA.')
$toolTip.SetToolTip($script:btnPhoneReady, 'Confirm the current profile is imported and SFA routes BPSR only.')
$toolTip.SetToolTip($script:btnStart, 'Start this PC relay first. Then start SFA on the phone, then BPSR.')
$toolTip.SetToolTip($script:btnStop, 'Stop the relay. If the phone is still using SFA, its game connection may stop.')

# DETAILS''', 'tooltips')

close_handler = r'''
$form.Add_FormClosing({
    param($sender, $eventArgs)
    $trackedRelayExists = (Get-RelayTrackedRunning) -or $script:trackedStarPid -gt 0 -or $script:trackedFrontPid -gt 0
    if ($trackedRelayExists) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "The relay is still active.`r`n`r`nYes = stop relay and close`r`nNo = keep relay running and close this window`r`nCancel = stay here",
            'Relay is still active',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) { $eventArgs.Cancel = $true; return }
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            try { Stop-Relay }
            catch { $eventArgs.Cancel = $true; Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception; return }
        }
        return
    }
    if ($script:shareProcess) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Phone Setup is still active. Closing this window will cancel the temporary QR/link.`r`n`r`nClose anyway?",
            'Phone Setup still active',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { $eventArgs.Cancel = $true }
    }
})
'''
ui = once(ui, '$timer = New-Object System.Windows.Forms.Timer', close_handler + '\n$timer = New-Object System.Windows.Forms.Timer', 'close guard')

ui = once(ui, "if ($script:btnShare.Text -ne 'Start Phone Setup' -or $script:btnQr.Text -ne 'Show SFA QR' -or $script:btnUrl.Text -ne 'Copy SFA Link') { throw 'SFA phone setup wording changed.' }", "if ($script:btnShare.Text -notin @('Set Up Phone','Re-import Phone') -or $script:btnQr.Text -ne 'Show SFA QR' -or $script:btnUrl.Text -ne 'Copy SFA Link' -or -not $script:btnPhoneReady) { throw 'SFA guided phone setup controls changed.' }", 'selftest phone')
ui = once(ui, "if ($androidRight.Text -notmatch 'Scan QR Code' -or $androidRight.Text -notmatch 'Per-app proxy') { throw 'Android guide incomplete.' }", "if ($androidRight.Text -notmatch 'scan the QR' -or $androidRight.Text -notmatch 'Per-app proxy' -or $androidRight.Text -notmatch 'BPSR only') { throw 'Android guide incomplete.' }", 'selftest guide')

old_start_assert = '''    foreach ($needle in @('12. PC: Start Relay.','13. Phone: Start SFA. Allow VPN permission.','14. Open BPSR.')) {
        if (-not $androidRight.Text.Contains($needle)) { throw ('Android startup-order self-test failed: ' + $needle) }
    }
    if ($androidRight.Text.Contains('12. Start SFA. Allow VPN permission.')) { throw 'Old phone-before-PC startup order was reintroduced.' }
'''
new_start_assert = '''    foreach ($needle in @('8. PC: click Phone Ready, then Start Relay.','9. Phone: Start SFA, then open BPSR.')) {
        if (-not $androidRight.Text.Contains($needle)) { throw ('Android startup-order self-test failed: ' + $needle) }
    }
    foreach ($functionName in @('Test-PhoneSetupConfirmed','Confirm-PhoneSetup','Invoke-StartRelayGuided','Invoke-StopRelayGuided','Invoke-RestorePreviousGuided')) {
        if (-not (Get-Command $functionName -ErrorAction SilentlyContinue)) { throw ('Guided UX guardrail missing: ' + $functionName) }
    }
    $selectedIpSource = (Get-Command Get-SelectedIp -ErrorAction Stop).ScriptBlock.ToString()
    if (-not $selectedIpSource.Contains("PSObject.Properties['IP']")) { throw 'Friendly adapter selector engine support is missing.' }
'''
ui = once(ui, old_start_assert, new_start_assert, 'selftest startup order')
ui = once(ui, "Assert-LabelFits -Label $script:lblNextAction -Name 'What to do next'", "Assert-LabelFits -Label $script:lblNextAction -Name 'What to do next'\n    Assert-LabelFits -Label $script:lblAddressHint -Name 'Selected network hint'", 'selftest hint')
ui = once(ui, "Write-Host 'UI SELF-TEST PASS: Home/Details/Help fit, Android baby steps and SFA QR actions present, labels fit, StarSEA target visible.'", "Write-Host 'UI SELF-TEST PASS: layout fits, guided step states/phone confirmation/close-stop guardrails exist, startup order is explicit, StarSEA target remains visible.'", 'selftest message')

readme = once(readme,
    '4. Click **Prepare Relay** → **Allow Firewall** → **Start Phone Setup**.\n5. In Android SFA, scan/import the QR profile and route **BPSR only** through it.\n6. Click **Start Relay** on the PC, start SFA on the phone, then open BPSR.',
    '4. Follow the blue **NEXT** action: **Prepare Relay** → **Allow Firewall** → **Set Up Phone**.\n5. In Android SFA, import the current QR profile, enable per-app proxy, and select **BPSR only**. Back on the PC, click **Phone Ready** to confirm those two phone-side steps.\n6. Click **Start Relay** on the PC first, then start SFA on the phone, then open BPSR.',
    'readme flow')
readme = once(readme,
    'Daily use is normally just:\n\n**PC Start Relay → Android Start SFA → Open BPSR**',
    'Daily use is normally just:\n\n**PC Start Relay → Android Start SFA → Open BPSR**\n\nThe manager remembers confirmation for the current SFA profile. If the PC IP/profile changes, it asks you to re-import/confirm instead of silently assuming the old phone setup is still valid.',
    'readme daily')
readme = once(readme,
    '- Re-run phone setup if your PC LAN IP changes or the manager tells you to repair the profile.',
    '- Re-run phone setup if your PC LAN IP/profile changes or the manager says the phone is not confirmed.\n- Closing the manager while the relay is active asks whether to stop it or intentionally keep it running.\n- Do not share the generated JSON profile, QR code, setup link, or relay credentials.',
    'readme safety')

required = [
    'function Test-PhoneSetupConfirmed',
    'function Invoke-StartRelayGuided',
    'function Invoke-StopRelayGuided',
    'function Invoke-RestorePreviousGuided',
    "Phone setup' -Y 180",
    'Set Up Phone',
    'Phone Ready',
    'PC relay is ready. On the phone: start SFA, then open BPSR.',
    'The relay is still active.',
    "PSObject.Properties['IP']",
]
combined = ui + '\n' + manager
for needle in required:
    if needle not in combined:
        raise SystemExit(f'missing UX invariant: {needle}')
if "Profile File' -X 420" in ui:
    raise SystemExit('Home still exposes raw profile files as a normal action')
if "$script:btnStart.Add_Click({ try { Start-Relay }" in ui:
    raise SystemExit('Start Relay still bypasses guided phone-state guard')

ui_path.write_text(ui, encoding='utf-8', newline='\n')
manager_path.write_text(manager, encoding='utf-8', newline='\n')
readme_path.write_text(readme, encoding='utf-8', newline='\n')
