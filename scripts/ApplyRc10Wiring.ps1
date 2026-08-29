$ErrorActionPreference = 'Stop'

$managerPath = 'scripts\BPSRRelayManager.ps1'
$text = Get-Content -LiteralPath $managerPath -Raw

$oldVersion = '$ManagerVersion = ''1.0.0-rc.9'''
$newVersion = '$ManagerVersion = ''1.0.0-rc.10'''
if (-not $text.Contains($oldVersion)) { throw 'Expected RC.9 ManagerVersion was not found.' }
$text = $text.Replace($oldVersion, $newVersion)

$marker = 'Add-Type -AssemblyName System.Windows.Forms'
$index = $text.IndexOf($marker, [System.StringComparison]::Ordinal)
if ($index -lt 0) { throw 'Old UI marker was not found.' }
if ($text.IndexOf($marker, $index + $marker.Length, [System.StringComparison]::Ordinal) -ge 0) {
    throw 'More than one old UI marker was found.'
}

$prefix = $text.Substring(0, $index)
$tail = @'
$UiScript = Join-Path $PSScriptRoot 'ManagerUi.ps1'
if (-not (Test-Path -LiteralPath $UiScript -PathType Leaf)) {
    throw 'ManagerUi.ps1 is missing. Re-extract the full release ZIP.'
}
. $UiScript
'@

$newText = $prefix + $tail + [Environment]::NewLine
[System.IO.File]::WriteAllText(
    (Resolve-Path -LiteralPath $managerPath),
    $newText,
    (New-Object System.Text.UTF8Encoding($false))
)

# Verify the edit itself before allowing a commit.
$verify = Get-Content -LiteralPath $managerPath -Raw
if (-not $verify.Contains("$UiScript = Join-Path $PSScriptRoot 'ManagerUi.ps1'")) {
    throw 'Manager UI module wiring was not written.'
}
if ($verify.Contains('New-Object System.Windows.Forms.Form')) {
    throw 'Old inline UI still exists in the engine after wiring.'
}
if (-not $verify.Contains('$ManagerVersion = ''1.0.0-rc.10''')) {
    throw 'RC.10 version bump was not written.'
}

Write-Host 'RC.10 manager wiring patch applied safely.'
