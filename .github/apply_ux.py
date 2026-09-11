from pathlib import Path
import re

ui_path = Path('scripts/ManagerUi.ps1')
ui = ui_path.read_text(encoding='utf-8')


def once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, found {count}')
    return text.replace(old, new, 1)


def regex_once(text, pattern, repl, label):
    new, count = re.subn(pattern, repl, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one regex match, found {count}')
    return new

new_preflight = r'''function Show-Preflight {
    $pcIp = Get-SelectedIp
    $running = Get-RelayTrackedRunning
    $checks = Get-PreflightChecks -PcIp $pcIp -RequirePortFree:(-not $running)

    foreach ($line in (Format-Checks -Checks $checks) -split [Environment]::NewLine) {
        Add-Log $line
    }

    $fails = @($checks | Where-Object { $_.State -eq 'FAIL' })
    $warnings = @($checks | Where-Object { $_.State -eq 'WARN' })
    $phoneReady = Test-PhoneSetupConfirmed

    if ($fails.Count -eq 0 -and -not $phoneReady) {
        Add-Log '[WARN] Phone setup - Current SFA profile is not confirmed on this PC.'
        [System.Windows.Forms.MessageBox]::Show(
            "The PC side looks ready, but phone setup is not confirmed yet.`r`n`r`nIf the CURRENT profile is already imported in SFA and Per-app proxy is BPSR only, click Phone Ready.`r`n`r`nOtherwise click Set Up Phone first.",
            'Phone setup still needed',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    if ($fails.Count -eq 0) {
        $message = 'Everything important looks ready.'
        if ($warnings.Count -gt 0) {
            $message += "`r`n`r`nThere is a Windows network warning. If your phone cannot connect, click Allow Firewall again."
        }
        else {
            $message += "`r`n`r`nStart Relay on the PC first, then start SFA on the phone, then open BPSR."
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
    if ($names -match 'Duplicate relay|TCP|UDP') {
        $message = "An old relay or another app is still using the relay.`r`n`r`nClose it or restart your PC."
    }
    elseif ($names -match 'LAN IP') {
        $message = "This PC network is not ready.`r`n`r`nChoose the Wi-Fi/Ethernet connected to the same router/network as your phone."
    }
    elseif ($names -match 'Windows network profile|Firewall') {
        $message = "Your Windows network is not ready for the phone connection.`r`n`r`nClick Allow Firewall. If this is your trusted home/private network, approve changing it to Private."
    }
    else {
        $message = "Setup is not ready yet.`r`n`r`nFollow the blue NEXT step on Home, then run the check again."
    }

    [System.Windows.Forms.MessageBox]::Show(
        $message,
        'One thing needs attention',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
}
'''
ui = regex_once(ui, r'function Show-Preflight \{.*?\n\}\n\nfunction Update-UiButtonStates', new_preflight + '\nfunction Update-UiButtonStates', 'phone-aware preflight')
ui = once(ui, "$script:lblProfileState = New-StatusRow -Parent $statusCard -Title 'Phone profile' -Y 112", "$script:lblProfileState = New-StatusRow -Parent $statusCard -Title 'SFA profile' -Y 112", 'truthful SFA profile label')

# Guard the new consistency rule in CI.
needle = "if ($script:btnShare.Text -notin @('Set Up Phone','Re-import Phone')"
insert = "    $preflightSource = (Get-Command Show-Preflight -ErrorAction Stop).ScriptBlock.ToString()\n    foreach ($guard in @('Test-PhoneSetupConfirmed','Phone setup still needed','Start Relay on the PC first')) {\n        if (-not $preflightSource.Contains($guard)) { throw ('Phone-aware preflight guard missing: ' + $guard) }\n    }\n\n"
idx = ui.find('    ' + needle)
if idx < 0:
    raise SystemExit('self-test phone control anchor not found')
ui = ui[:idx] + insert + ui[idx:]

ui_path.write_text(ui, encoding='utf-8', newline='\n')
