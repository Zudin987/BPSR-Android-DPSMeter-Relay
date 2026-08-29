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

$launcherSourcePath = Join-Path $root 'launcher\BPSRRelayManagerLauncher.cs'
if (-not (Test-Path -LiteralPath $launcherSourcePath -PathType Leaf)) {
    throw 'launcher\BPSRRelayManagerLauncher.cs was not found.'
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
$buildRoot = Join-Path $root '.build'
$stageRoot = Join-Path $buildRoot 'release'
$stage = Join-Path $stageRoot $packageBase
$launcherBuildRoot = Join-Path $buildRoot 'launcher'
$launcherExe = Join-Path $launcherBuildRoot 'BPSR Relay Manager.exe'

if ($Clean) {
    foreach ($path in @($OutputDirectory, $buildRoot)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
if (Test-Path -LiteralPath $launcherBuildRoot) {
    Remove-Item -LiteralPath $launcherBuildRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $launcherBuildRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'scripts') -Force | Out-Null

# Build a tiny managed WinExe launcher. It only starts the existing PowerShell GUI hidden;
# it does not sit in the gameplay traffic path and does not bundle sing-box.
$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = @($cscCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)[0]
if ([string]::IsNullOrWhiteSpace([string]$csc)) {
    throw 'Windows .NET Framework C# compiler was not found; cannot build BPSR Relay Manager.exe.'
}

$compilerOutput = & $csc `
    '/nologo' `
    '/target:winexe' `
    '/optimize+' `
    '/platform:anycpu' `
    '/reference:System.dll' `
    '/reference:System.Windows.Forms.dll' `
    ('/out:' + $launcherExe) `
    $launcherSourcePath 2>&1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $launcherExe -PathType Leaf)) {
    throw ('Native launcher compilation failed: ' + (($compilerOutput | Out-String).Trim()))
}

Copy-Item -LiteralPath $launcherExe -Destination (Join-Path $stage 'BPSR Relay Manager.exe') -Force

$files = @(
    @{ Source = 'README.md'; Destination = 'README.md' },
    @{ Source = 'scripts\LaunchManager.ps1'; Destination = 'scripts\LaunchManager.ps1' },
    @{ Source = 'scripts\BPSRRelayManager.ps1'; Destination = 'scripts\BPSRRelayManager.ps1' },
    @{ Source = 'scripts\ManagerUi.ps1'; Destination = 'scripts\ManagerUi.ps1' },
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

$allowedLauncher = [System.IO.Path]::GetFullPath((Join-Path $stage 'BPSR Relay Manager.exe'))
$exeFiles = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Where-Object { $_.Extension -ieq '.exe' })
if ($exeFiles.Count -ne 1 -or -not ([System.IO.Path]::GetFullPath($exeFiles[0].FullName)).Equals($allowedLauncher, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ('Release staging must contain exactly one executable: BPSR Relay Manager.exe. Found: ' + (($exeFiles.FullName) -join ', '))
}

$privateForbidden = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Where-Object {
    $_.Name -ieq 'relay-credentials.json' -or
    $_.Name -ieq 'pids.json' -or
    $_.Name -ieq 'sing-box.exe' -or
    $_.Name -ieq 'StarSEA.exe' -or
    $_.FullName -match '[\\/]\.runtime[\\/]' -or
    $_.FullName -match '[\\/]output[\\/]'
})
if ($privateForbidden.Count -gt 0) {
    throw ('Release staging contains forbidden runtime/private files: ' + (($privateForbidden.FullName) -join ', '))
}

$requiredRelative = @(
    'BPSR Relay Manager.exe',
    'README.md',
    'scripts\LaunchManager.ps1',
    'scripts\BPSRRelayManager.ps1',
    'scripts\ManagerUi.ps1',
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
$verifyRoot = Join-Path $buildRoot 'verify-release'
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

    $archiveExeFiles = @(Get-ChildItem -LiteralPath $archiveRoot -File -Recurse | Where-Object { $_.Extension -ieq '.exe' })
    $expectedArchiveLauncher = [System.IO.Path]::GetFullPath((Join-Path $archiveRoot 'BPSR Relay Manager.exe'))
    if ($archiveExeFiles.Count -ne 1 -or -not ([System.IO.Path]::GetFullPath($archiveExeFiles[0].FullName)).Equals($expectedArchiveLauncher, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Final release ZIP must contain only the native BPSR Relay Manager.exe launcher executable.'
    }

    $archivePrivateForbidden = @(Get-ChildItem -LiteralPath $archiveRoot -File -Recurse | Where-Object {
        $_.Name -ieq 'relay-credentials.json' -or
        $_.Name -ieq 'pids.json' -or
        $_.Name -ieq 'sing-box.exe' -or
        $_.Name -ieq 'StarSEA.exe' -or
        $_.FullName -match '[\\/]\.runtime[\\/]' -or
        $_.FullName -match '[\\/]output[\\/]'
    })
    if ($archivePrivateForbidden.Count -gt 0) {
        throw 'Final release ZIP unexpectedly contains runtime/private files.'
    }

    & (Join-Path $archiveRoot 'BPSR Relay Manager.exe') '--launcher-self-test'
    if ($LASTEXITCODE -ne 0) {
        throw ('Packaged BPSR Relay Manager.exe self-test failed with exit code ' + $LASTEXITCODE + '.')
    }
}
finally {
    if (Test-Path -LiteralPath $verifyRoot) { Remove-Item -LiteralPath $verifyRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $launcherBuildRoot) { Remove-Item -LiteralPath $launcherBuildRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ('Release package: ' + $zipPath)
Write-Host ('SHA256 file:    ' + $hashPath)
Write-Host ('SHA256:         ' + $hash)
Write-Host 'User entry point: BPSR Relay Manager.exe'

[PSCustomObject]@{
    Version = $version
    ZipPath = $zipPath
    Sha256Path = $hashPath
    Sha256 = $hash
    EntryPoint = 'BPSR Relay Manager.exe'
}
