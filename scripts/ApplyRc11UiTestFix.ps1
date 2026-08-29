$ErrorActionPreference = 'Stop'

$path = 'scripts\ManagerUi.ps1'
$text = Get-Content -LiteralPath $path -Raw
$old = @'
# Lightweight UI layout self-test for CI. It does not open a window or start the relay.
if ($env:BPSR_RELAY_UI_SELF_TEST -eq '1') {
    function Assert-Inside {
'@
$new = @'
# Lightweight UI layout self-test for CI. It does not open a window or start the relay.
if ($env:BPSR_RELAY_UI_SELF_TEST -eq '1') {
    # WinForms does not fully size dormant TabPages until they are selected/laid out.
    # Materialize each page before checking bounds so CI measures the rendered geometry.
    [void]$form.CreateControl()
    foreach ($page in @($homeTab, $detailsTab, $helpTab)) {
        $tabs.SelectedTab = $page
        [void]$page.CreateControl()
        $page.PerformLayout()
        $tabs.PerformLayout()
        $form.PerformLayout()
    }
    $tabs.SelectedTab = $homeTab
    $form.PerformLayout()

    function Assert-Inside {
'@
if (-not $text.Contains($old)) { throw 'UI self-test insertion point not found.' }
$text = $text.Replace($old, $new)
[System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $path), $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'RC.11 UI tab-layout self-test fix applied.'
