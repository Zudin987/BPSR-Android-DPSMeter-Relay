$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'ManagerUi.ps1'
$text = Get-Content -LiteralPath $path -Raw
$old = '$quickText.Size = New-Object System.Drawing.Size(284, 44)'
$new = '$quickText.Size = New-Object System.Drawing.Size(284, 52)'
$count = ([regex]::Matches($text, [regex]::Escape($old))).Count
if ($count -ne 1) { throw ('Expected one Daily Use size line; found ' + $count) }
$text = $text.Replace($old, $new)
[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Error $_.Message }; throw 'ManagerUi parse failed.' }
Write-Host 'Daily Use label height set to 52px.'
