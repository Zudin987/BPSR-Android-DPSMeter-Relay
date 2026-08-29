$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'ManagerUi.ps1'
$text = Get-Content -LiteralPath $path -Raw
$old = 'Phone issue: run Phone Setup and re-import the current QR.'
$new = 'Phone issue: run Phone Setup, scan QR.'
$count = ([regex]::Matches($text, [regex]::Escape($old))).Count
if ($count -ne 1) { throw ('Expected one problem-help line; found ' + $count) }
$text = $text.Replace($old, $new)
[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Error $_.Message }; throw 'ManagerUi parse failed.' }
Write-Host 'Problem Help wording shortened for the existing card.'
