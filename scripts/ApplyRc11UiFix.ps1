$ErrorActionPreference = 'Stop'

function Replace-Exact {
    param([string]$Path, [string]$Old, [string]$New)
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Old)) { throw ('Expected text not found in ' + $Path) }
    $text = $text.Replace($Old, $New)
    [System.IO.File]::WriteAllText(
        (Resolve-Path -LiteralPath $Path),
        $text,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

$oldStatus = @'
    $title = New-Object System.Windows.Forms.Label
    $title.Text = $Title
    $title.Location = New-Object System.Drawing.Point(16, $Y)
    $title.Size = New-Object System.Drawing.Size(135, 23)
    $title.ForeColor = $Ui.Muted
    $Parent.Controls.Add($title)
'@
$newStatus = @'
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Location = New-Object System.Drawing.Point(16, $Y)
    $titleLabel.Size = New-Object System.Drawing.Size(135, 23)
    $titleLabel.ForeColor = $Ui.Muted
    $Parent.Controls.Add($titleLabel)
'@
Replace-Exact -Path 'scripts\ManagerUi.ps1' -Old $oldStatus -New $newStatus

Replace-Exact -Path 'scripts\BPSRRelayManager.ps1' `
    -Old '$ManagerVersion = ''1.0.0-rc.10''' `
    -New '$ManagerVersion = ''1.0.0-rc.11'''

Write-Host 'RC.11 status-row collision fix and version bump applied.'
