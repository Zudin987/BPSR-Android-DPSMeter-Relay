$ErrorActionPreference = 'Stop'

function Replace-Exact {
    param([string]$Path, [string]$Old, [string]$New)
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Old)) { throw ('Expected text not found in ' + $Path) }
    $text = $text.Replace($Old, $New)
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path), $text, (New-Object System.Text.UTF8Encoding($false)))
}

$oldInside = @'
    function Assert-Inside {
        param($Control, $Parent, [string]$Name)
        if ($Control.Left -lt 0 -or $Control.Top -lt 0 -or $Control.Right -gt $Parent.ClientSize.Width -or $Control.Bottom -gt $Parent.ClientSize.Height) {
            throw ('UI layout overflow: ' + $Name)
        }
    }
'@
$newInside = @'
    function Get-LayoutSize {
        param($Parent)
        if ($Parent -is [System.Windows.Forms.TabPage]) {
            return $tabs.DisplayRectangle.Size
        }
        return $Parent.ClientSize
    }

    function Assert-Inside {
        param($Control, $Parent, [string]$Name)
        $layoutSize = Get-LayoutSize -Parent $Parent
        if ($Control.Left -lt 0 -or $Control.Top -lt 0 -or $Control.Right -gt $layoutSize.Width -or $Control.Bottom -gt $layoutSize.Height) {
            throw ('UI layout overflow: ' + $Name + ' (control=' + $Control.Bounds + ', parent=' + $layoutSize + ')')
        }
    }
'@
Replace-Exact -Path 'scripts\ManagerUi.ps1' -Old $oldInside -New $newInside

$oldPass = @'
    Write-Host 'UI SELF-TEST PASS: Home/Details/Help fit, key labels have measured text room, simple actions present, StarSEA target visible.'
    return
'@
$newPass = @'
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

    Write-Host 'UI SELF-TEST PASS: Home/Details/Help fit, key labels have measured text room, simple actions present, StarSEA target visible.'
    return
'@
Replace-Exact -Path 'scripts\ManagerUi.ps1' -Old $oldPass -New $newPass

$validatePath = '.github\workflows\validate.yml'
$validate = Get-Content -LiteralPath $validatePath -Raw
$oldStep = @'
      - name: Test simple manager UI layout
        shell: powershell
        run: |
          $env:BPSR_RELAY_UI_SELF_TEST = '1'
          try {
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\scripts\BPSRRelayManager.ps1'
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
          }
          finally {
            Remove-Item Env:BPSR_RELAY_UI_SELF_TEST -ErrorAction SilentlyContinue
          }
'@
$newStep = @'
      - name: Test and render simple manager UI
        shell: powershell
        run: |
          $env:BPSR_RELAY_UI_SELF_TEST = '1'
          $env:BPSR_RELAY_UI_CAPTURE_DIR = Join-Path $env:RUNNER_TEMP 'bpsr-ui-preview'
          try {
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\scripts\BPSRRelayManager.ps1'
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
          }
          finally {
            Remove-Item Env:BPSR_RELAY_UI_SELF_TEST -ErrorAction SilentlyContinue
            Remove-Item Env:BPSR_RELAY_UI_CAPTURE_DIR -ErrorAction SilentlyContinue
          }

      - name: Upload UI preview
        uses: actions/upload-artifact@v4
        with:
          name: ui-preview
          path: ${{ runner.temp }}/bpsr-ui-preview/*.png
          if-no-files-found: error
          retention-days: 7
'@
if (-not $validate.Contains($oldStep)) { throw 'Validate UI test step was not found.' }
$validate = $validate.Replace($oldStep, $newStep)
[System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $validatePath), $validate, (New-Object System.Text.UTF8Encoding($false)))

Write-Host 'RC.11 visual audit patch applied.'
