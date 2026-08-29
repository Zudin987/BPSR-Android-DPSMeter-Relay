$ErrorActionPreference = 'Stop'

$path = 'scripts\ManagerUi.ps1'
$text = Get-Content -LiteralPath $path -Raw

$oldCard = @'
    $label.ForeColor = $Ui.Text
    $label.AutoEllipsis = $true
    $Parent.Controls.Add($label)
'@
$newCard = @'
    $label.ForeColor = $Ui.Text
    $label.AutoEllipsis = $true
    $label.UseMnemonic = $false
    $Parent.Controls.Add($label)
'@
if (-not $text.Contains($oldCard)) { throw 'Card-title label block not found.' }
$text = $text.Replace($oldCard, $newCard)

$oldDetails = @'
$detailsTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$detailsTitle.ForeColor = $Ui.Text
$detailsTab.Controls.Add($detailsTitle)
'@
$newDetails = @'
$detailsTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$detailsTitle.ForeColor = $Ui.Text
$detailsTitle.UseMnemonic = $false
$detailsTab.Controls.Add($detailsTitle)
'@
if (-not $text.Contains($oldDetails)) { throw 'Details-title label block not found.' }
$text = $text.Replace($oldDetails, $newDetails)

[System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $path), $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'RC.11 mnemonic rendering fix applied.'
