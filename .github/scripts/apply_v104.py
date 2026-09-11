from pathlib import Path
import re
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text(encoding='utf-8')


def write(path, text):
    p = ROOT / path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding='utf-8', newline='\n')


def replace_one(text, old, new, label):
    if old not in text:
        raise RuntimeError(f'missing patch target: {label}')
    if text.count(old) != 1:
        raise RuntimeError(f'patch target not unique: {label} count={text.count(old)}')
    return text.replace(old, new, 1)


# Vendor a pinned MIT QR encoder so QR payloads never leave the PC.
PIN = '04f46c6a0708418cb7b96fc563eacae0fbf77674'
for remote, local in [
    (f'https://raw.githubusercontent.com/davidshimjs/qrcodejs/{PIN}/qrcode.min.js', 'scripts/vendor/qrcode.min.js'),
    (f'https://raw.githubusercontent.com/davidshimjs/qrcodejs/{PIN}/LICENSE', 'scripts/vendor/LICENSE-qrcodejs.txt'),
]:
    with urllib.request.urlopen(remote, timeout=30) as r:
        data = r.read()
    p = ROOT / local
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)

# Engine polish.
p = 'scripts/BPSRRelayManager.ps1'
s = read(p)
s = replace_one(s, "$ManagerVersion = '1.0.3'", "$ManagerVersion = '1.0.4'", 'manager version')
s = replace_one(s, "$LogFile = Join-Path $Runtime 'manager.log'", "$LogFile = Join-Path $Runtime 'manager.log'\n$QrHtmlFile = Join-Path $OutputDir 'sfa-setup-qr.html'", 'QR html path')
s = replace_one(s,
"""        if ($state -and [string]$state.profileId -eq $profileId) { return $true }""",
"""        if ($state -and [string]$state.profileId -eq $profileId) {
            $reason = if ($state.PSObject.Properties['reason']) { [string]$state.reason } else { '' }
            if (@('confirmed', 'user-confirmed-manual-import', 'preserved-unchanged-profile') -contains $reason) { return $true }
        }""", 'phone confirmation semantics')
s = replace_one(s, 'function Set-PhoneProfileConfirmed {', """function Test-PhoneProfileDownloaded {
    $profileId = Get-CurrentPhoneProfileId
    if ([string]::IsNullOrWhiteSpace($profileId)) { return $false }
    try {
        $state = Read-JsonFile -Path $PhoneProfileStateFile
        return ($state -and [string]$state.profileId -eq $profileId -and [string]$state.reason -eq 'profile-downloaded')
    }
    catch { return $false }
}

function Set-PhoneProfileConfirmed {""", 'download state helper')
s = s.replace('IMPORTANT FOR v1.0.2:\nIf upgrading from an older test build, remove its old BPSR Relay profile and import this newly generated profile.\nv1.0.2 keeps the field-tested Clean v4 routing shape unchanged.', 'IMPORTANT:\nIf upgrading from an incompatible older test build, remove its old BPSR Relay profile and import this newly generated profile.\nThis release keeps the field-tested Clean v4 routing shape unchanged.')
s = s.replace("Add-Log 'Setup / Repair complete. v1.0.2 keeps the original Clean v4 two-stage SOCKS5 route.'", "Add-Log ('Setup / Repair complete. Manager v' + $ManagerVersion + ' keeps the original Clean v4 two-stage SOCKS5 route.')")
s = s.replace("Add-Log 'If upgrading from an older test build, remove its old SFA profile and import the newly generated v1.0.2 profile.'", "Add-Log 'If upgrading from an incompatible older test build, remove its old SFA profile and import the newly generated current profile.'")
s = s.replace("Add-Log 'Next: Allow Firewall -> Send to Phone -> SFA BPSR-only per-app proxy -> DPS target StarSEA -> Start Relay.'", "Add-Log 'Next: Allow Firewall -> Start Phone Setup -> SFA BPSR-only per-app proxy -> DPS target StarSEA -> Start Relay.'")
s = s.replace("('v1.0.2 v4-compatible profile matches ' + $PcIp)", "('Current v4-compatible profile matches ' + $PcIp)")
s = s.replace("'v1.0.2 profile is not generated. Click Prepare Relay, then import the new profile into SFA.'", "'Current profile is not generated. Click Prepare Relay, then import the new profile into SFA.'")
s = s.replace("Add-Log 'v1.0.2 two-stage relay is already running.'", "Add-Log ('Manager v' + $ManagerVersion + ' two-stage relay is already running.')")
s = s.replace('Phone-to-PC encryption: DISABLED in v1.0.2 compatibility mode', 'Phone-to-PC encryption: DISABLED (authenticated SOCKS5 on trusted Private LAN)')
s = replace_one(s, "$script:shareUrl = ''\n}", "$script:shareUrl = ''\n    Remove-Item -LiteralPath $QrHtmlFile -Force -ErrorAction SilentlyContinue\n}", 'share cleanup')
old_qr = """function Show-ShareQr {
    if ([string]::IsNullOrWhiteSpace($script:shareUrl) -or -not $script:shareProcess) { throw 'Start Phone Setup first.' }
    $script:shareProcess.Refresh()
    if ($script:shareProcess.HasExited) { throw 'Phone setup expired. Start Phone Setup again.' }
    $sfaImportUrl = Get-SfaImportUrl
    $qrUrl = 'https://quickchart.io/qr?size=420&margin=2&text=' + [Uri]::EscapeDataString($sfaImportUrl)
    Start-Process $qrUrl | Out-Null
    Add-Log 'Opened SFA-ready QR. On Android: SFA > + > Scan QR Code.'
}
"""
new_qr = """function Show-ShareQr {
    if ([string]::IsNullOrWhiteSpace($script:shareUrl) -or -not $script:shareProcess) { throw 'Start Phone Setup first.' }
    $script:shareProcess.Refresh()
    if ($script:shareProcess.HasExited) { throw 'Phone setup expired. Start Phone Setup again.' }

    $qrLibrary = Join-Path $PSScriptRoot 'vendor\\qrcode.min.js'
    if (-not (Test-Path -LiteralPath $qrLibrary -PathType Leaf)) {
        throw 'Local QR component is missing. Re-extract the complete release ZIP.'
    }

    $sfaImportUrl = Get-SfaImportUrl
    $payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($sfaImportUrl))
    $qrJs = Get-Content -LiteralPath $qrLibrary -Raw
    $html = @\"
<!doctype html>
<html lang=\"en\">
<head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>BPSR Relay - SFA QR</title>
<style>body{font-family:Segoe UI,system-ui,sans-serif;background:#f4f7fb;color:#0f172a;margin:0;padding:32px}.card{max-width:520px;margin:auto;background:#fff;border:1px solid #dae1eb;border-radius:14px;padding:24px;box-sizing:border-box}h1{font-size:22px;margin:0 0 8px}.muted,.note{color:#64748b}.note{font-size:13px}#qrcode{display:flex;justify-content:center;padding:16px;background:#fff}</style></head>
<body><div class=\"card\"><h1>BPSR Relay - SFA setup</h1><p class=\"muted\">On Android: SFA &gt; + &gt; Scan QR Code</p><div id=\"qrcode\"></div><p class=\"note\">Generated locally on this PC. No QR data is sent to an external service.</p></div>
<script>
$qrJs
var value=window.atob('$payload');
new QRCode(document.getElementById('qrcode'),{text:value,width:420,height:420,colorDark:'#000000',colorLight:'#ffffff',correctLevel:QRCode.CorrectLevel.M});
</script></body></html>
\"@
    Write-Utf8NoBom -Path $QrHtmlFile -Text $html
    Start-Process -FilePath $QrHtmlFile | Out-Null
    Add-Log 'Opened locally generated SFA-ready QR. No QR payload was sent to an external service.'
}
"""
s = replace_one(s, old_qr, new_qr, 'local QR')
if 'v1.0.2' in s:
    raise RuntimeError('stale v1.0.2 text remains in engine')
if 'quickchart.io' in s:
    raise RuntimeError('QuickChart reference remains in engine')
write(p, s)

# UI: distinguish downloaded from truly confirmed/imported.
p = 'scripts/ManagerUi.ps1'
s = read(p)
s = replace_one(s, '    $phoneConfirmed = $false\n', '    $phoneConfirmed = $false\n    $phoneDownloaded = $false\n', 'downloaded state init')
s = replace_one(s,
"""        $phoneConfirmed = Test-PhoneProfileConfirmed
        if ($phoneConfirmed) {
            Set-UiStatusLabel -Label $script:lblProfileState -Text 'Ready' -State 'Ready'
        }
        else {
            Set-UiStatusLabel -Label $script:lblProfileState -Text 'Import needed' -State 'Warning'
        }""",
"""        $phoneConfirmed = Test-PhoneProfileConfirmed
        $phoneDownloaded = Test-PhoneProfileDownloaded
        if ($phoneConfirmed) {
            Set-UiStatusLabel -Label $script:lblProfileState -Text 'Ready' -State 'Ready'
        }
        elseif ($phoneDownloaded) {
            Set-UiStatusLabel -Label $script:lblProfileState -Text 'Downloaded - confirm' -State 'Warning'
        }
        else {
            Set-UiStatusLabel -Label $script:lblProfileState -Text 'Import needed' -State 'Warning'
        }""", 'profile status')
s = replace_one(s,
"""    elseif (-not $phoneConfirmed) {
        if ($script:shareProcess) {
            $script:lblNextAction.Text = 'Phone setup is open. Scan the QR and import BPSR Relay in SFA.'
        }
        else {
            $script:lblNextAction.Text = 'Click Start Phone Setup and import the current BPSR Relay profile in SFA.'
        }
    }""",
"""    elseif (-not $phoneConfirmed) {
        if ($phoneDownloaded) {
            $script:lblNextAction.Text = 'Profile downloaded. Confirm it is imported in SFA, then click Start Relay.'
        }
        elseif ($script:shareProcess) {
            $script:lblNextAction.Text = 'Phone setup is open. Scan the QR and import BPSR Relay in SFA.'
        }
        else {
            $script:lblNextAction.Text = 'Click Start Phone Setup and import the current BPSR Relay profile in SFA.'
        }
    }""", 'next action')
s = replace_one(s,
"""        if (-not (Test-PhoneProfileConfirmed)) {
            $choice = [System.Windows.Forms.MessageBox]::Show(
                \"This PC cannot confirm that the current BPSR Relay profile is imported in SFA.`r`n`r`nYes: open Phone Setup now (recommended).`r`nNo: I already imported this exact current profile; remember it and start.`r`nCancel: do nothing.\",
                'Finish phone setup first',""",
"""        if (-not (Test-PhoneProfileConfirmed)) {
            $downloaded = Test-PhoneProfileDownloaded
            $promptText = if ($downloaded) {
                \"The current profile was downloaded, but Windows cannot verify that SFA imported it.`r`n`r`nYes: open Phone Setup again.`r`nNo: I checked SFA and this exact current profile is imported; remember it and start.`r`nCancel: do nothing.\"
            }
            else {
                \"This PC cannot confirm that the current BPSR Relay profile is imported in SFA.`r`n`r`nYes: open Phone Setup now (recommended).`r`nNo: I already imported this exact current profile; remember it and start.`r`nCancel: do nothing.\"
            }
            $choice = [System.Windows.Forms.MessageBox]::Show(
                $promptText,
                'Finish phone setup first',""", 'guided start prompt')
write(p, s)

# Launcher metadata source is neutral; builder injects the current manager version.
p = 'launcher/BPSRRelayManagerLauncher.cs'
s = read(p)
s = s.replace('[assembly: AssemblyVersion("1.0.0.0")]', '[assembly: AssemblyVersion("0.0.0.0")]')
s = s.replace('[assembly: AssemblyFileVersion("1.0.0.0")]', '[assembly: AssemblyFileVersion("0.0.0.0")]')
write(p, s)

# Release builder: inject real EXE metadata and include vendored QR files.
p = 'scripts/BuildRelease.ps1'
s = read(p)
s = replace_one(s, "$launcherExe = Join-Path $launcherBuildRoot 'BPSR Relay Manager.exe'", "$launcherExe = Join-Path $launcherBuildRoot 'BPSR Relay Manager.exe'\n$launcherCompileSource = Join-Path $launcherBuildRoot 'BPSRRelayManagerLauncher.cs'", 'launcher temp source')
s = replace_one(s, "New-Item -ItemType Directory -Path (Join-Path $stage 'scripts') -Force | Out-Null", "New-Item -ItemType Directory -Path (Join-Path $stage 'scripts') -Force | Out-Null\nNew-Item -ItemType Directory -Path (Join-Path $stage 'scripts\\vendor') -Force | Out-Null\n\n$versionNumeric = (($version -split '-', 2)[0] + '.0')\n$launcherSource = Get-Content -LiteralPath $launcherSourcePath -Raw\n$launcherSource = $launcherSource.Replace('[assembly: AssemblyVersion(\"0.0.0.0\")]', '[assembly: AssemblyVersion(\"' + $versionNumeric + '\")]')\n$launcherSource = $launcherSource.Replace('[assembly: AssemblyFileVersion(\"0.0.0.0\")]', '[assembly: AssemblyFileVersion(\"' + $versionNumeric + '\")]')\n[System.IO.File]::WriteAllText($launcherCompileSource, $launcherSource, (New-Object System.Text.UTF8Encoding($false)))", 'version injection')
s = s.replace('$launcherSourcePath 2>&1', '$launcherCompileSource 2>&1')
s = replace_one(s, "Copy-Item -LiteralPath $launcherExe -Destination (Join-Path $stage 'BPSR Relay Manager.exe') -Force", "Copy-Item -LiteralPath $launcherExe -Destination (Join-Path $stage 'BPSR Relay Manager.exe') -Force\n$launcherInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($launcherExe)\nif ([string]$launcherInfo.FileVersion -ne $versionNumeric) { throw ('Launcher file version mismatch: expected ' + $versionNumeric + ', got ' + $launcherInfo.FileVersion) }", 'launcher version verify')
s = replace_one(s, "    @{ Source = 'scripts\\ServeProfile.ps1'; Destination = 'scripts\\ServeProfile.ps1' }", "    @{ Source = 'scripts\\ServeProfile.ps1'; Destination = 'scripts\\ServeProfile.ps1' },\n    @{ Source = 'scripts\\vendor\\qrcode.min.js'; Destination = 'scripts\\vendor\\qrcode.min.js' },\n    @{ Source = 'scripts\\vendor\\LICENSE-qrcodejs.txt'; Destination = 'scripts\\vendor\\LICENSE-qrcodejs.txt' }", 'vendor files package')
s = replace_one(s, "    'scripts\\ServeProfile.ps1'\n)", "    'scripts\\ServeProfile.ps1',\n    'scripts\\vendor\\qrcode.min.js',\n    'scripts\\vendor\\LICENSE-qrcodejs.txt'\n)", 'vendor required files')
write(p, s)

# CI: parse version dynamically instead of hardcoding every patch release.
p = '.github/workflows/validate.yml'
s = read(p)
s = s.replace('Check v1.0.3 firewall topology and latency invariants', 'Check relay security topology and latency invariants')
s = s.replace('            "`$ManagerVersion = \'1.0.3\'",\n', '')
s = s.replace("if (-not $text.Contains($needle)) { throw ('Missing v1.0.3 invariant: ' + $needle) }", "if (-not $text.Contains($needle)) { throw ('Missing relay invariant: ' + $needle) }")
s = s.replace("          # The compatibility fix must never broaden the trusted-LAN firewall rule.", "          $versionMatch = [regex]::Match($text, \"(?m)^`$ManagerVersion\\s*=\\s*'([^']+)'\")\n          if (-not $versionMatch.Success -or $versionMatch.Groups[1].Value -notmatch '^\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'ManagerVersion is missing or invalid.' }\n          if ($text.Contains('quickchart.io')) { throw 'External QR service was reintroduced.' }\n          foreach ($needle in @('vendor\\qrcode.min.js','function Test-PhoneProfileDownloaded')) { if (-not $text.Contains($needle)) { throw ('Polish invariant missing: ' + $needle) } }\n\n          # The compatibility fix must never broaden the trusted-LAN firewall rule.")
s = s.replace("Write-Host 'Static v1.0.3 firewall/topology/latency/UI/package/release guards passed.'", "Write-Host ('Static firewall/topology/latency/UI/package/release guards passed for manager v' + $versionMatch.Groups[1].Value + '.')")
s = s.replace("            'scripts\\ServeProfile.ps1'\n          ))", "            'scripts\\ServeProfile.ps1',\n            'scripts\\vendor\\qrcode.min.js',\n            'scripts\\vendor\\LICENSE-qrcodejs.txt'\n          ))")
write(p, s)

# Release input follows source version, while the human field-test gate remains unchanged.
p = '.github/workflows/release.yml'
s = read(p)
s = s.replace("description: 'Stable version to publish (example: 1.0.3)'", "description: 'Stable version to publish (example: 1.0.4)'")
s = s.replace("default: '1.0.3'", "default: '1.0.4'", 1)
write(p, s)

# Documentation note about local QR privacy.
p = 'README.md'
s = read(p)
s = replace_one(s, '- Re-run phone setup if your PC LAN IP changes or the manager tells you to repair the profile.', '- Re-run phone setup if your PC LAN IP changes or the manager tells you to repair the profile.\n- The SFA QR is generated locally on the PC; the setup payload is not sent to an external QR service.', 'README local QR note')
write(p, s)

# Remove the temporary patch machinery from the resulting branch commit.
for rel in ['.github/scripts/apply_v104.py', '.github/workflows/apply-v104-polish.yml']:
    q = ROOT / rel
    if q.exists():
        q.unlink()

print('v1.0.4 polish patch applied')
