param(
    [string]$OutputDirectory = '',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $root 'dist'
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $root $OutputDirectory
}

$managerPath = Join-Path $PSScriptRoot 'BPSRRelayManager.ps1'
if (-not (Test-Path -LiteralPath $managerPath -PathType Leaf)) {
    throw 'scripts\BPSRRelayManager.ps1 was not found.'
}

$managerText = Get-Content -LiteralPath $managerPath -Raw
$match = [regex]::Match(
    $managerText,
    '^\$ManagerVersion\s*=\s*''([^'']+)''',
    [System.Text.RegularExpressions.RegexOptions]::Multiline
)
if (-not $match.Success) {
    throw 'Could not read ManagerVersion from BPSRRelayManager.ps1.'
}
$version = $match.Groups[1].Value.Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
    throw ('ManagerVersion is not a valid release version: ' + $version)
}

$packageBase = 'BPSR-Android-DPSMeter-Relay-v' + $version
$zipPath = Join-Path $OutputDirectory ($packageBase + '.zip')
$hashPath = $zipPath + '.sha256'
$stageRoot = Join-Path $root '.build\release'
$stage = Join-Path $stageRoot $packageBase

if ($Clean) {
    foreach ($path in @($OutputDirectory, $stageRoot)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path (Join-Path $stage 'scripts') -Force | Out-Null

$files = @(
    @{ Source = 'BPSR Relay Manager.bat'; Destination = 'BPSR Relay Manager.bat' },
    @{ Source = 'README.md'; Destination = 'README.md' },
    @{ Source = 'scripts\LaunchManager.ps1'; Destination = 'scripts\LaunchManager.ps1' },
    @{ Source = 'scripts\BPSRRelayManager.ps1'; Destination = 'scripts\BPSRRelayManager.ps1' },
    @{ Source = 'scripts\ServeProfile.ps1'; Destination = 'scripts\ServeProfile.ps1' }
)

foreach ($file in $files) {
    $source = Join-Path $root $file.Source
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw ('Required release file is missing: ' + $file.Source)
    }
    $destination = Join-Path $stage $file.Destination
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

$forbidden = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Where-Object {
    $_.Extension -ieq '.exe' -or
    $_.Name -ieq 'relay-credentials.json' -or
    $_.Name -ieq 'pids.json' -or
    $_.FullName -match '[\\/]\.runtime[\\/]' -or
    $_.FullName -match '[\\/]output[\\/]'
})
if ($forbidden.Count -gt 0) {
    throw ('Release staging contains forbidden runtime/private files: ' + (($forbidden.FullName) -join ', '))
}

$requiredRelative = @(
    'BPSR Relay Manager.bat',
    'README.md',
    'scripts\LaunchManager.ps1',
    'scripts\BPSRRelayManager.ps1',
    'scripts\ServeProfile.ps1'
)
foreach ($relative in $requiredRelative) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $relative) -PathType Leaf)) {
        throw ('Release staging is missing: ' + $relative)
    }
}

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
if (Test-Path -LiteralPath $hashPath) { Remove-Item -LiteralPath $hashPath -Force }

Compress-Archive -LiteralPath $stage -DestinationPath $zipPath -CompressionLevel Optimal -Force
if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw 'Release ZIP was not created.'
}

$zipInfo = Get-Item -LiteralPath $zipPath
if ($zipInfo.Length -le 0) { throw 'Release ZIP is empty.' }

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    $hashPath,
    ($hash + '  ' + [System.IO.Path]::GetFileName($zipPath) + [Environment]::NewLine),
    (New-Object System.Text.UTF8Encoding($false))
)

# Validate the final archive, not just the staging directory.
$verifyRoot = Join-Path $root '.build\verify-release'
if (Test-Path -LiteralPath $verifyRoot) { Remove-Item -LiteralPath $verifyRoot -Recurse -Force }
New-Item -ItemType Directory -Path $verifyRoot -Force | Out-Null
try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $verifyRoot -Force
    $archiveRoot = Join-Path $verifyRoot $packageBase
    foreach ($relative in $requiredRelative) {
        if (-not (Test-Path -LiteralPath (Join-Path $archiveRoot $relative) -PathType Leaf)) {
            throw ('Final release ZIP is missing: ' + $relative)
        }
    }
    $archiveForbidden = @(Get-ChildItem -LiteralPath $archiveRoot -File -Recurse | Where-Object { $_.Extension -ieq '.exe' })
    if ($archiveForbidden.Count -gt 0) {
        throw 'Final release ZIP unexpectedly contains an executable.'
    }
}
finally {
    if (Test-Path -LiteralPath $verifyRoot) { Remove-Item -LiteralPath $verifyRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ('Release package: ' + $zipPath)
Write-Host ('SHA256 file:    ' + $hashPath)
Write-Host ('SHA256:         ' + $hash)

[PSCustomObject]@{
    Version = $version
    ZipPath = $zipPath
    Sha256Path = $hashPath
    Sha256 = $hash
}
