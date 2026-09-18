param(
    [string]$OutputDirectory = '',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $root 'dist' }
elseif (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory = Join-Path $root $OutputDirectory }

$versionPath = Join-Path $root 'src\BpsrRelayManager\VersionInfo.cs'
if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { throw 'Native manager VersionInfo.cs was not found.' }
$versionText = Get-Content -LiteralPath $versionPath -Raw
$match = [regex]::Match($versionText, 'public const string Version\s*=\s*"([^"]+)"')
if (-not $match.Success) { throw 'Could not read native manager version.' }
$version = $match.Groups[1].Value.Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw ('Native manager version is invalid: ' + $version) }
$versionNumeric = (($version -split '-', 2)[0] + '.0')

$packageBase = 'BPSR-Android-DPSMeter-Relay'
$zipPath = Join-Path $OutputDirectory ($packageBase + '.zip')
$hashPath = $zipPath + '.sha256'
$buildRoot = Join-Path $root '.build'
$stageRoot = Join-Path $buildRoot 'release'
$stage = Join-Path $stageRoot $packageBase
$nativeExe = Join-Path $buildRoot 'native\BPSR Relay Manager.exe'

if ($Clean) {
    foreach ($path in @($OutputDirectory, $buildRoot)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $stage -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'assets') -Force | Out-Null

powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'BuildNativeManager.ps1') -OutputPath $nativeExe
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $nativeExe -PathType Leaf)) { throw 'Native manager build failed.' }
Copy-Item -LiteralPath $nativeExe -Destination (Join-Path $stage 'BPSR Relay Manager.exe') -Force
$exeInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($nativeExe)
if ([string]$exeInfo.FileVersion -ne $versionNumeric) { throw ('Native EXE file version mismatch: expected ' + $versionNumeric + ', got ' + $exeInfo.FileVersion) }

$files = @(
    @{ Source = 'README.md'; Destination = 'README.md' },
    @{ Source = 'scripts\vendor\qrcode.min.js'; Destination = 'assets\qrcode.min.js' },
    @{ Source = 'scripts\vendor\LICENSE-qrcodejs.txt'; Destination = 'assets\LICENSE-qrcodejs.txt' }
)
foreach ($file in $files) {
    $source = Join-Path $root $file.Source
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('Required release file is missing: ' + $file.Source) }
    $destination = Join-Path $stage $file.Destination
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

$requiredRelative = @('BPSR Relay Manager.exe','README.md','assets\qrcode.min.js','assets\LICENSE-qrcodejs.txt')
foreach ($relative in $requiredRelative) { if (-not (Test-Path -LiteralPath (Join-Path $stage $relative) -PathType Leaf)) { throw ('Release staging is missing: ' + $relative) } }

$exeFiles = @(Get-ChildItem -LiteralPath $stage -Filter '*.exe' -File -Recurse)
if ($exeFiles.Count -ne 1 -or $exeFiles[0].Name -ne 'BPSR Relay Manager.exe') { throw 'Release package must contain exactly one executable: BPSR Relay Manager.exe.' }
$powerShellPayload = @(Get-ChildItem -LiteralPath $stage -Filter '*.ps1' -File -Recurse)
if ($powerShellPayload.Count -ne 0) { throw 'Native release package must not ship PowerShell runtime scripts.' }
$privateForbidden = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Where-Object {
    $_.Name -ieq 'relay-credentials.json' -or $_.Name -ieq 'pids.json' -or $_.Name -ieq 'sing-box.exe' -or $_.Name -ieq 'StarSEA.exe' -or $_.Name -ieq 'BPSRMobileFront.exe' -or $_.FullName -match '[\\/]\.runtime[\\/]' -or $_.FullName -match '[\\/]output[\\/]'
})
if ($privateForbidden.Count -gt 0) { throw ('Release staging contains runtime/private files: ' + (($privateForbidden.FullName) -join ', ')) }

$uiTest = Start-Process -FilePath (Join-Path $stage 'BPSR Relay Manager.exe') -ArgumentList '--ui-self-test' -NoNewWindow -Wait -PassThru
if ($uiTest.ExitCode -ne 0) { throw ('Native packaged UI self-test failed with exit code ' + $uiTest.ExitCode + '.') }

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
if (Test-Path -LiteralPath $hashPath) { Remove-Item -LiteralPath $hashPath -Force }
Compress-Archive -LiteralPath $stage -DestinationPath $zipPath -CompressionLevel Optimal -Force
if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or (Get-Item $zipPath).Length -le 0) { throw 'Release ZIP was not created correctly.' }
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText($hashPath, ($hash + '  ' + [System.IO.Path]::GetFileName($zipPath) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))

$verifyRoot = Join-Path $buildRoot 'verify-release'
if (Test-Path -LiteralPath $verifyRoot) { Remove-Item -LiteralPath $verifyRoot -Recurse -Force }
New-Item -ItemType Directory -Path $verifyRoot -Force | Out-Null
try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $verifyRoot -Force
    $archiveRoot = Join-Path $verifyRoot $packageBase
    foreach ($relative in $requiredRelative) { if (-not (Test-Path -LiteralPath (Join-Path $archiveRoot $relative) -PathType Leaf)) { throw ('Final release ZIP is missing: ' + $relative) } }
    if (@(Get-ChildItem -LiteralPath $archiveRoot -Filter '*.exe' -File -Recurse).Count -ne 1) { throw 'Final release ZIP must contain exactly one executable.' }
    if (@(Get-ChildItem -LiteralPath $archiveRoot -Filter '*.ps1' -File -Recurse).Count -ne 0) { throw 'Final native release ZIP unexpectedly contains PowerShell scripts.' }
    $uiTest = Start-Process -FilePath (Join-Path $archiveRoot 'BPSR Relay Manager.exe') -ArgumentList '--ui-self-test' -NoNewWindow -Wait -PassThru
    if ($uiTest.ExitCode -ne 0) { throw ('Final packaged native UI self-test failed with exit code ' + $uiTest.ExitCode + '.') }
}
finally {
    if (Test-Path -LiteralPath $verifyRoot) { Remove-Item -LiteralPath $verifyRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ('Release package: ' + $zipPath)
Write-Host ('SHA256 file:    ' + $hashPath)
Write-Host ('SHA256:         ' + $hash)
Write-Host ('Version metadata: v' + $version)
Write-Host 'User entry point: native BPSR Relay Manager.exe (no PowerShell runtime dependency)'

[PSCustomObject]@{ Version = $version; ZipPath = $zipPath; Sha256Path = $hashPath; Sha256 = $hash; EntryPoint = 'BPSR Relay Manager.exe' }
