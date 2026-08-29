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

Replace-Exact $manager "`$ManagerVersion = '1.0.0-rc.8'" "`$ManagerVersion = '1.0.0-rc.9'"

Replace-Exact $readme @'
Download/extract the repository and double-click:

```text
BPSR Relay Manager.bat
```

The manager tries to select the most likely physical Wi-Fi/Ethernet IPv4 automatically. If needed, choose the PC LAN address the phone can reach.

A small launcher wrapper keeps the PowerShell console hidden during normal use but shows a visible error dialog if the manager fails before its UI can open.
'@ @'
Download the release ZIP, extract it, and double-click:

```text
BPSR Relay Manager.exe
```

That EXE is the normal user-facing entry point. It is a tiny open-source Windows launcher that starts the existing manager GUI with the PowerShell console hidden; it does not proxy traffic, stay in the gameplay data path, or bundle sing-box.

The manager tries to select the most likely physical Wi-Fi/Ethernet IPv4 automatically. If needed, choose the PC LAN address the phone can reach.

The repository still keeps the BAT launcher as a developer/troubleshooting fallback, but the normal release package is EXE-first so users do not need to open a BAT file.
'@

Replace-Exact $readme @'
- clean end-user ZIP contents and SHA256 generation
'@ @'
- native `BPSR Relay Manager.exe` launcher compilation and packaged self-test
- clean end-user ZIP contents and SHA256 generation
'@

Replace-Exact $readme @'
- no sing-box executable is committed to this repository
'@ @'
- the release package contains one small user-facing `BPSR Relay Manager.exe` launcher; it does not contain sing-box or `StarSEA.exe`
- no sing-box executable is committed to this repository
'@

Write-Host 'RC.9 EXE UX patch applied.'
