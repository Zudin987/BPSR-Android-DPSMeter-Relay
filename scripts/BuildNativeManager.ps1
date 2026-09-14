param(
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $root 'src\BpsrRelayManager'
$versionPath = Join-Path $sourceDir 'VersionInfo.cs'
if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { throw 'Native manager VersionInfo.cs is missing.' }

$versionText = Get-Content -LiteralPath $versionPath -Raw
$match = [regex]::Match($versionText, 'public const string Version\s*=\s*"([^"]+)"')
if (-not $match.Success) { throw 'Could not read native manager version.' }
$version = $match.Groups[1].Value.Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw ('Native manager version is invalid: ' + $version) }
$versionNumeric = (($version -split '-', 2)[0] + '.0')

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $root '.build\native\BPSR Relay Manager.exe'
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $root $OutputPath
}
$outputDir = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$compileDir = Join-Path $root '.build\native-compile'
if (Test-Path -LiteralPath $compileDir) { Remove-Item -LiteralPath $compileDir -Recurse -Force }
New-Item -ItemType Directory -Path $compileDir -Force | Out-Null

$programSource = Get-Content -LiteralPath (Join-Path $sourceDir 'Program.cs') -Raw
$programSource = $programSource.Replace('[assembly: AssemblyVersion("0.0.0.0")]', '[assembly: AssemblyVersion("' + $versionNumeric + '")]')
$programSource = $programSource.Replace('[assembly: AssemblyFileVersion("0.0.0.0")]', '[assembly: AssemblyFileVersion("' + $versionNumeric + '")]')
$generatedProgram = Join-Path $compileDir 'Program.cs'
[System.IO.File]::WriteAllText($generatedProgram, $programSource, (New-Object System.Text.UTF8Encoding($false)))

$sources = @(
    $generatedProgram,
    (Join-Path $sourceDir 'VersionInfo.cs'),
    (Join-Path $sourceDir 'WindowsIntegration.cs'),
    (Join-Path $sourceDir 'RelayEngine.cs'),
    (Join-Path $sourceDir 'ProfileServer.cs'),
    (Join-Path $sourceDir 'MainForm.cs')
)
foreach ($source in $sources) { if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('Native manager source missing: ' + $source) } }

$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = @($cscCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)[0]
if ([string]::IsNullOrWhiteSpace([string]$csc)) { throw 'Windows .NET Framework C# compiler was not found.' }

$args = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/platform:anycpu',
    '/reference:System.dll',
    '/reference:System.Core.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Web.Extensions.dll',
    '/reference:System.IO.Compression.dll',
    '/reference:System.IO.Compression.FileSystem.dll',
    '/reference:Microsoft.CSharp.dll',
    ('/out:' + $OutputPath)
) + $sources

$compilerOutput = & $csc @args 2>&1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw ('Native manager compilation failed:' + [Environment]::NewLine + (($compilerOutput | Out-String).Trim()))
}

$info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($OutputPath)
if ([string]$info.FileVersion -ne $versionNumeric) { throw ('Native manager file version mismatch: expected ' + $versionNumeric + ', got ' + $info.FileVersion) }

Write-Host ('Native manager: ' + $OutputPath)
Write-Host ('Version: v' + $version)

[PSCustomObject]@{
    Version = $version
    VersionNumeric = $versionNumeric
    OutputPath = $OutputPath
}
