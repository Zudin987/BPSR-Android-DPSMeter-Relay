from pathlib import Path


def once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


mgr_path = Path("scripts/BPSRRelayManager.ps1")
ui_path = Path("scripts/ManagerUi.ps1")
server_path = Path("scripts/ServeProfile.ps1")
mgr = mgr_path.read_text(encoding="utf-8")
ui = ui_path.read_text(encoding="utf-8")
server = server_path.read_text(encoding="utf-8")

mgr = once(mgr,
    "$ProfileMeta = Join-Path $OutputDir 'profile-meta.json'\n$FirewallScript = Join-Path $Runtime 'allow-firewall.ps1'",
    "$ProfileMeta = Join-Path $OutputDir 'profile-meta.json'\n$PhoneProfileStateFile = Join-Path $Runtime 'phone-profile-state.json'\n$FirewallScript = Join-Path $Runtime 'allow-firewall.ps1'",
    "phone state path")

helpers = r'''function Get-CurrentPhoneProfileId {
    try {
        if (-not (Test-Path -LiteralPath $AndroidConfig -PathType Leaf)) { return '' }
        $meta = Read-JsonFile -Path $ProfileMeta
        if ($meta -and $meta.PSObject.Properties['profileId'] -and -not [string]::IsNullOrWhiteSpace([string]$meta.profileId)) {
            return [string]$meta.profileId
        }
        return (Get-FileHash -LiteralPath $AndroidConfig -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    catch { return '' }
}

function Test-PhoneProfileConfirmed {
    $profileId = Get-CurrentPhoneProfileId
    if ([string]::IsNullOrWhiteSpace($profileId)) { return $false }
    try {
        $state = Read-JsonFile -Path $PhoneProfileStateFile
        if ($state -and [string]$state.profileId -eq $profileId) { return $true }
    }
    catch {}

    # Profiles from the previous stable build have no profileId metadata.
    # Treat a valid legacy profile as already imported so an update does not
    # force working users through phone setup again.
    try {
        $meta = Read-JsonFile -Path $ProfileMeta
        if ($meta -and -not $meta.PSObject.Properties['profileId'] -and (Test-Path -LiteralPath $AndroidConfig -PathType Leaf)) {
            return $true
        }
    }
    catch {}
    return $false
}

function Set-PhoneProfileConfirmed {
    param([string]$Reason = 'confirmed')
    $profileId = Get-CurrentPhoneProfileId
    if ([string]::IsNullOrWhiteSpace($profileId)) { throw 'The current phone profile is missing or unreadable.' }
    Write-JsonFile -Path $PhoneProfileStateFile -Value ([ordered]@{
        profileId = $profileId
        confirmedUtc = [DateTime]::UtcNow.ToString('o')
        reason = $Reason
    })
}

function Clear-PhoneProfileConfirmed {
    Remove-Item -LiteralPath $PhoneProfileStateFile -Force -ErrorAction SilentlyContinue
}

'''
mgr = mgr.replace("function Get-InstalledVersion {", helpers + "function Get-InstalledVersion {", 1)

mgr = once(mgr,
    "function Write-RelayConfigs {\n    param([string]$PcIp, $Credentials)\n\n    Ensure-Directories\n    $internalPort = Get-FreeInternalPort",
    "function Write-RelayConfigs {\n    param([string]$PcIp, $Credentials)\n\n    Ensure-Directories\n    $previousProfileId = Get-CurrentPhoneProfileId\n    $previousProfileConfirmed = Test-PhoneProfileConfirmed\n    $internalPort = Get-FreeInternalPort",
    "previous profile state")

mgr = once(mgr,
    "    Write-JsonFile -Path $FrontConfig -Value $front\n    Write-JsonFile -Path $StarConfig -Value $star\n    Write-JsonFile -Path $AndroidConfig -Value $android\n    Write-JsonFile -Path $ProfileMeta -Value ([ordered]@{\n        managerVersion = $ManagerVersion",
    "    Write-JsonFile -Path $FrontConfig -Value $front\n    Write-JsonFile -Path $StarConfig -Value $star\n    Write-JsonFile -Path $AndroidConfig -Value $android\n    $profileId = (Get-FileHash -LiteralPath $AndroidConfig -Algorithm SHA256).Hash.ToLowerInvariant()\n    Write-JsonFile -Path $ProfileMeta -Value ([ordered]@{\n        managerVersion = $ManagerVersion\n        profileId = $profileId",
    "profile id metadata")

mgr = once(mgr,
    "        generatedUtc = [DateTime]::UtcNow.ToString('o')\n    })\n\n    $importText = @\"",
    "        generatedUtc = [DateTime]::UtcNow.ToString('o')\n    })\n\n    if ($previousProfileConfirmed -and -not [string]::IsNullOrWhiteSpace($previousProfileId) -and $previousProfileId -eq $profileId) {\n        Set-PhoneProfileConfirmed -Reason 'preserved-unchanged-profile'\n    }\n    else {\n        Clear-PhoneProfileConfirmed\n    }\n\n    $importText = @\"",
    "confirmation preservation")

mgr = once(mgr,
    "            ' -ProfilePath ' + (Quote-Argument $AndroidConfig) + ' -LifetimeSeconds ' + $ShareLifetimeSeconds",
    "            ' -ProfilePath ' + (Quote-Argument $AndroidConfig) +\n            ' -SuccessMarkerPath ' + (Quote-Argument $PhoneProfileStateFile) +\n            ' -ProfileId ' + (Quote-Argument (Get-CurrentPhoneProfileId)) +\n            ' -LifetimeSeconds ' + $ShareLifetimeSeconds",
    "share confirmation args")

server = once(server,
    "    [Parameter(Mandatory = $true)][string]$ProfilePath,\n    [int]$LifetimeSeconds = 300",
    "    [Parameter(Mandatory = $true)][string]$ProfilePath,\n    [string]$SuccessMarkerPath = '',\n    [string]$ProfileId = '',\n    [int]$LifetimeSeconds = 300",
    "server params")

server = once(server,
    "                if (-not $headOnly) { $servedProfile = $true }",
    r'''                if (-not $headOnly) {
                    $servedProfile = $true
                    if (-not [string]::IsNullOrWhiteSpace($SuccessMarkerPath) -and -not [string]::IsNullOrWhiteSpace($ProfileId)) {
                        try {
                            $markerDir = Split-Path -Parent $SuccessMarkerPath
                            if (-not [string]::IsNullOrWhiteSpace($markerDir) -and -not (Test-Path -LiteralPath $markerDir)) {
                                New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
                            }
                            $markerJson = [ordered]@{
                                profileId = $ProfileId
                                confirmedUtc = [DateTime]::UtcNow.ToString('o')
                                reason = 'profile-downloaded'
                            } | ConvertTo-Json -Depth 5
                            $tempMarker = $SuccessMarkerPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
                            [System.IO.File]::WriteAllText($tempMarker, $markerJson, (New-Object System.Text.UTF8Encoding($false)))
                            Move-Item -LiteralPath $tempMarker -Destination $SuccessMarkerPath -Force
                        }
                        catch {}
                    }
                }''',
    "server success marker")

ui = once(ui,
    "$script:cmbIp.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown",
    "$script:cmbIp.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList",
    "safe IP selector")
ui = once(ui,
    "$addressHint.Text = \"Usually leave this as-is.`r`nPhone and PC must use the same Wi-Fi.\"",
    "$addressHint.Text = \"Usually leave this as-is.`r`nPhone and PC must use the same home network/router.\"",
    "address hint")
ui = once(ui,
    "elseif ($script:cmbIp.Items.Count -gt 0) { $script:cmbIp.SelectedIndex = 0 }\n$script:cmbIp.Add_SelectedIndexChanged({ Update-Status })",
    "elseif ($script:cmbIp.Items.Count -gt 0) { $script:cmbIp.SelectedIndex = 0 }\nelse {\n    $script:cmbIp.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown\n    $addressHint.Text = \"No LAN address was detected automatically.`r`nEnter this PC's Wi-Fi/Ethernet IPv4 address.\"\n}\n$script:cmbIp.Add_SelectedIndexChanged({ Update-Status })",
    "manual IP fallback")
ui = once(ui,
    "[void](Add-CardHelp -Parent $step3 -Text 'First setup or profile refresh: scan the current QR in SFA.' -Y 34 -Width 500 -Height 23)",
    "[void](Add-CardHelp -Parent $step3 -Text 'Required when Phone profile says Import needed. Scan the current QR in SFA.' -Y 34 -Width 500 -Height 23)",
    "phone setup help")

old_buttons = r'''$script:btnShare = New-UiButton -Text 'Start Phone Setup' -X 16 -Y 62 -Width 148 -Height 30 -Primary
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
$step3.Controls.Add($script:btnShare)
$script:btnQr = New-UiButton -Text 'Show SFA QR' -X 172 -Y 62 -Width 116 -Height 30
$script:btnQr.Add_Click({ try { Show-ShareQr } catch { Show-FriendlyError -Title 'Could not show SFA QR' -Exception $_.Exception } })
$step3.Controls.Add($script:btnQr)
$script:btnUrl = New-UiButton -Text 'Copy SFA Link' -X 296 -Y 62 -Width 116 -Height 30
$script:btnUrl.Add_Click({ try { Copy-ShareUrl } catch { Show-FriendlyError -Title 'Could not copy SFA link' -Exception $_.Exception } })
$step3.Controls.Add($script:btnUrl)
$script:btnFolder = New-UiButton -Text 'Profile File' -X 420 -Y 62 -Width 110 -Height 30
$script:btnFolder.Add_Click({ try { Open-ProfileFolder } catch { Show-FriendlyError -Title 'Could not open profile file' -Exception $_.Exception } })
$step3.Controls.Add($script:btnFolder)'''
new_buttons = r'''$script:btnShare = New-UiButton -Text 'Start Phone Setup' -X 16 -Y 62 -Width 180 -Height 30 -Primary
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
            "Phone setup is running, but the QR could not open.`r`n`r`nClick Copy SFA Link and open that link on your phone.",
            'Phone setup started',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
})
$step3.Controls.Add($script:btnShare)
$script:btnQr = New-UiButton -Text 'Show SFA QR' -X 204 -Y 62 -Width 150 -Height 30
$script:btnQr.Add_Click({ try { Show-ShareQr } catch { Show-FriendlyError -Title 'Could not show SFA QR' -Exception $_.Exception } })
$step3.Controls.Add($script:btnQr)
$script:btnUrl = New-UiButton -Text 'Copy SFA Link' -X 362 -Y 62 -Width 168 -Height 30
$script:btnUrl.Add_Click({ try { Copy-ShareUrl } catch { Show-FriendlyError -Title 'Could not copy SFA link' -Exception $_.Exception } })
$step3.Controls.Add($script:btnUrl)'''
ui = once(ui, old_buttons, new_buttons, "simplify phone buttons")
ui = once(ui,
    "[void](Add-CardHelp -Parent $step5 -Text 'Run Check if needed. Then start the relay and play.' -Y 34 -Width 500 -Height 23)",
    "[void](Add-CardHelp -Parent $step5 -Text 'Run Check if needed. Start Relay guides you if phone setup is unfinished.' -Y 34 -Width 500 -Height 23)",
    "start help")

guides = r'''function Invoke-StartRelayGuided {
    try {
        if (-not (Test-PhoneProfileConfirmed)) {
            $choice = [System.Windows.Forms.MessageBox]::Show(
                "This PC cannot confirm that the current BPSR Relay profile is imported in SFA.`r`n`r`nYes: open Phone Setup now (recommended).`r`nNo: I already imported this exact current profile; remember it and start.`r`nCancel: do nothing.",
                'Finish phone setup first',
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
                Start-ProfileShare
                Show-ShareQr
                return
            }
            if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
                Set-PhoneProfileConfirmed -Reason 'user-confirmed-manual-import'
            }
            else { return }
        }
        Start-Relay
    }
    catch { Show-FriendlyError -Title 'Could not start relay' -Exception $_.Exception }
    finally { Update-Status }
}

function Invoke-StopRelayGuided {
    if (-not (Get-RelayTrackedRunning)) { return }
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "Stop the relay now?`r`n`r`nIf BPSR is using this relay, stopping it can interrupt the phone's game connection.",
        'Stop relay?',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try { Stop-Relay }
    catch { Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception }
}

function Invoke-RestorePreviousGuided {
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "Restore the previous sing-box runtime?`r`n`r`nThis is a troubleshooting action. Normal users should use Prepare Relay instead.",
        'Restore previous runtime?',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try { Restore-PreviousRuntime }
    catch { Show-FriendlyError -Title 'Could not restore previous version' -Exception $_.Exception }
}

'''
ui = ui.replace("# Override the engine status renderer for the simplified UI.\nfunction Update-Status {", guides + "# Override the engine status renderer for the simplified UI.\nfunction Update-Status {", 1)

ui = once(ui,
    "        [bool]$ForeignRelay = $false,\n        [bool]$FirewallReady = $false\n    )\n\n    if ($script:btnSetup)       { $script:btnSetup.Enabled = -not $Running }\n    if ($script:btnFirewall)    { $script:btnFirewall.Enabled = -not $Running }",
    "        [bool]$ForeignRelay = $false,\n        [bool]$FirewallReady = $false,\n        [bool]$PhoneConfirmed = $false\n    )\n\n    if ($script:btnSetup)       { $script:btnSetup.Enabled = -not $Running }\n    if ($script:btnFirewall)    { $script:btnFirewall.Enabled = (-not $Running) -and $RuntimeReady -and $ProfileReady -and (-not $ForeignRelay) }",
    "button prerequisites")

ui = once(ui,
    "        Set-UiStatusLabel -Label $script:lblFirewallState -Text 'Not checked' -State 'Neutral'",
    "        Set-UiStatusLabel -Label $script:lblFirewallState -Text 'Ready at start' -State 'Ready'",
    "running firewall state")

old_profile = r'''    $profileReady = $false
    if ([string]::IsNullOrWhiteSpace($profileIp)) {
        Set-UiStatusLabel -Label $script:lblProfileState -Text 'Missing' -State 'Error'
    }
    elseif ($profileIp -eq $selected -and (Test-LocalIpAssigned $selected)) {
        $profileReady = $true
        Set-UiStatusLabel -Label $script:lblProfileState -Text 'Ready' -State 'Ready'
    }
    else {
        Set-UiStatusLabel -Label $script:lblProfileState -Text 'Needs update' -State 'Warning'
    }'''
new_profile = r'''    $profileReady = $false
    $phoneConfirmed = $false
    if ([string]::IsNullOrWhiteSpace($profileIp)) {
        Set-UiStatusLabel -Label $script:lblProfileState -Text 'Missing' -State 'Error'
    }
    elseif ($profileIp -eq $selected -and (Test-LocalIpAssigned $selected)) {
        $profileReady = $true
        $phoneConfirmed = Test-PhoneProfileConfirmed
        if ($phoneConfirmed) {
            Set-UiStatusLabel -Label $script:lblProfileState -Text 'Ready' -State 'Ready'
        }
        else {
            Set-UiStatusLabel -Label $script:lblProfileState -Text 'Import needed' -State 'Warning'
        }
    }
    else {
        Set-UiStatusLabel -Label $script:lblProfileState -Text 'Needs update' -State 'Warning'
    }'''
ui = once(ui, old_profile, new_profile, "profile confirmation status")

ui = once(ui,
    "    elseif ($script:shareProcess) {\n        $script:lblNextAction.Text = 'Phone link is ready. Scan the QR code or copy the link.'\n    }\n    else {\n        $script:lblNextAction.Text = 'Setup is ready. Click Start Relay.'\n    }\n\n    Update-UiButtonStates -Running $false -ProfileReady $profileReady -RuntimeReady $runtimeReady -ForeignRelay $foreign -FirewallReady $firewallReady",
    "    elseif (-not $phoneConfirmed) {\n        if ($script:shareProcess) {\n            $script:lblNextAction.Text = 'Phone setup is open. Scan the QR and import BPSR Relay in SFA.'\n        }\n        else {\n            $script:lblNextAction.Text = 'Click Start Phone Setup and import the current BPSR Relay profile in SFA.'\n        }\n    }\n    elseif ($script:shareProcess) {\n        $script:lblNextAction.Text = 'Phone link is ready. Scan the QR code or copy the link.'\n    }\n    else {\n        $script:lblNextAction.Text = 'Setup is ready. Click Start Relay.'\n    }\n\n    Update-UiButtonStates -Running $false -ProfileReady $profileReady -RuntimeReady $runtimeReady -ForeignRelay $foreign -FirewallReady $firewallReady -PhoneConfirmed $phoneConfirmed",
    "next action import state")

ui = once(ui,
    "$script:btnStart.Add_Click({ try { Start-Relay } catch { Show-FriendlyError -Title 'Could not start relay' -Exception $_.Exception } })",
    "$script:btnStart.Add_Click({ Invoke-StartRelayGuided })",
    "guided start")
ui = ui.replace("$script:btnStop.Add_Click({ try { Stop-Relay } catch { Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception } })", "$script:btnStop.Add_Click({ Invoke-StopRelayGuided })", 1)
ui = ui.replace("$script:btnStopDetails.Add_Click({ try { Stop-Relay } catch { Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception } })", "$script:btnStopDetails.Add_Click({ Invoke-StopRelayGuided })", 1)
ui = ui.replace("$script:btnRollback.Add_Click({ try { Restore-PreviousRuntime } catch { Show-FriendlyError -Title 'Could not restore previous version' -Exception $_.Exception } })", "$script:btnRollback.Add_Click({ Invoke-RestorePreviousGuided })", 1)
ui = ui.replace("Phone + PC: same Wi-Fi.", "Phone + PC: same home network/router.")
ui = ui.replace("Phone issue: run Phone Setup, scan QR.", "Phone profile says Import needed: run Phone Setup, scan QR.")

close_guard = r'''$form.Add_FormClosing({
    param($sender, $eventArgs)
    if (Get-RelayTrackedRunning) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "The relay is still running.`r`n`r`nYes: close this window and KEEP the relay running.`r`nNo: STOP the relay, then close.`r`nCancel: keep this window open.",
            'Relay is still running',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
            $eventArgs.Cancel = $true
            return
        }
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
            try { Stop-Relay }
            catch {
                Show-FriendlyError -Title 'Could not stop relay' -Exception $_.Exception
                $eventArgs.Cancel = $true
            }
        }
    }
    elseif ($script:shareProcess) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Phone Setup is still open. Closing the manager will end the temporary setup link.`r`n`r`nClose anyway?",
            'Phone Setup is active',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { $eventArgs.Cancel = $true }
    }
})

'''
ui = ui.replace("$timer = New-Object System.Windows.Forms.Timer", close_guard + "$timer = New-Object System.Windows.Forms.Timer", 1)

ui = once(ui,
    "    if ($targetValue.Text -ne 'StarSEA') { throw 'DPS target card changed unexpectedly.' }",
    "    if ($targetValue.Text -ne 'StarSEA') { throw 'DPS target card changed unexpectedly.' }\n    if ($script:cmbIp.Items.Count -gt 0 -and $script:cmbIp.DropDownStyle -ne [System.Windows.Forms.ComboBoxStyle]::DropDownList) { throw 'Detected LAN addresses must use a non-editable selector.' }\n    $guidedStartSource = (Get-Command Invoke-StartRelayGuided -ErrorAction Stop).ScriptBlock.ToString()\n    foreach ($needle in @('Test-PhoneProfileConfirmed','Start-ProfileShare','Set-PhoneProfileConfirmed')) {\n        if (-not $guidedStartSource.Contains($needle)) { throw ('Guided start safety self-test failed: ' + $needle) }\n    }\n    $stopGuideSource = (Get-Command Invoke-StopRelayGuided -ErrorAction Stop).ScriptBlock.ToString()\n    if (-not $stopGuideSource.Contains('can interrupt the phone')) { throw 'Stop Relay confirmation guard is missing.' }",
    "UI safety self-tests")

for needle in ['phone-profile-state.json', 'profileId = $profileId', 'preserved-unchanged-profile', '-SuccessMarkerPath', 'Test-PhoneProfileConfirmed']:
    if needle not in mgr:
        raise SystemExit('missing manager invariant: ' + needle)
for needle in ['DropDownList', 'Import needed', 'Invoke-StartRelayGuided', 'Invoke-StopRelayGuided', 'Relay is still running', 'same home network/router.']:
    if needle not in ui:
        raise SystemExit('missing UI invariant: ' + needle)
for needle in ['SuccessMarkerPath', "reason = 'profile-downloaded'"]:
    if needle not in server:
        raise SystemExit('missing server invariant: ' + needle)
if "-Text 'Profile File'" in ui:
    raise SystemExit('confusing Home Profile File action still present')

mgr_path.write_text(mgr, encoding='utf-8', newline='\n')
ui_path.write_text(ui, encoding='utf-8', newline='\n')
server_path.write_text(server, encoding='utf-8', newline='\n')
