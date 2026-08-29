$ErrorActionPreference = 'Stop'

$path = 'scripts\ManagerUi.ps1'
$text = Get-Content -LiteralPath $path -Raw
$old = @'
    if (-not [string]::IsNullOrWhiteSpace($env:BPSR_RELAY_UI_CAPTURE_DIR)) {
        $captureDir = $env:BPSR_RELAY_UI_CAPTURE_DIR
        New-Item -ItemType Directory -Path $captureDir -Force | Out-Null
        foreach ($entry in @(
            @($homeTab, 'home.png'),
            @($detailsTab, 'details.png'),
            @($helpTab, 'help.png')
        )) {
            $tabs.SelectedTab = $entry[0]
            $form.PerformLayout()
            $tabs.PerformLayout()
            $entry[0].PerformLayout()
            [System.Windows.Forms.Application]::DoEvents()
            $bitmap = New-Object System.Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
            try {
                $form.DrawToBitmap($bitmap, $form.ClientRectangle)
                $bitmap.Save((Join-Path $captureDir $entry[1]), [System.Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $bitmap.Dispose() }
        }
        $tabs.SelectedTab = $homeTab
        Write-Host ('UI preview PNGs saved to ' + $captureDir)
    }
'@
$new = @'
    if (-not [string]::IsNullOrWhiteSpace($env:BPSR_RELAY_UI_CAPTURE_DIR)) {
        $captureDir = $env:BPSR_RELAY_UI_CAPTURE_DIR
        New-Item -ItemType Directory -Path $captureDir -Force | Out-Null
        $form.ShowInTaskbar = $false
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Location = New-Object System.Drawing.Point(0, 0)
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        try {
            Update-Status
            foreach ($entry in @(
                @($homeTab, 'home.png'),
                @($detailsTab, 'details.png'),
                @($helpTab, 'help.png')
            )) {
                $tabs.SelectedTab = $entry[0]
                $form.PerformLayout()
                $tabs.PerformLayout()
                $entry[0].PerformLayout()
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 150
                $bitmap = New-Object System.Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
                try {
                    $form.DrawToBitmap($bitmap, $form.ClientRectangle)
                    $bitmap.Save((Join-Path $captureDir $entry[1]), [System.Drawing.Imaging.ImageFormat]::Png)
                }
                finally { $bitmap.Dispose() }
            }
            $tabs.SelectedTab = $homeTab
        }
        finally {
            $form.Hide()
        }
        Write-Host ('UI preview PNGs saved to ' + $captureDir)
    }
'@
if (-not $text.Contains($old)) { throw 'Current RC.11 capture block not found.' }
$text = $text.Replace($old, $new)
[System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $path), $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'RC.11 materialized-form capture fix applied.'
