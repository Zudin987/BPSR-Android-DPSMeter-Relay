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

Replace-Exact -Path 'scripts\ManagerUi.ps1' `
    -Old "Set-UiStatusLabel -Label `$script:lblFirewallState -Text 'Active' -State 'Ready'" `
    -New "Set-UiStatusLabel -Label `$script:lblFirewallState -Text 'Not checked' -State 'Neutral'"

Replace-Exact -Path 'scripts\BuildRelease.ps1' `
    -Old "    @{ Source = 'scripts\BPSRRelayManager.ps1'; Destination = 'scripts\BPSRRelayManager.ps1' },`r`n    @{ Source = 'scripts\ServeProfile.ps1'; Destination = 'scripts\ServeProfile.ps1' }" `
    -New "    @{ Source = 'scripts\BPSRRelayManager.ps1'; Destination = 'scripts\BPSRRelayManager.ps1' },`r`n    @{ Source = 'scripts\ManagerUi.ps1'; Destination = 'scripts\ManagerUi.ps1' },`r`n    @{ Source = 'scripts\ServeProfile.ps1'; Destination = 'scripts\ServeProfile.ps1' }"

Replace-Exact -Path 'scripts\BuildRelease.ps1' `
    -Old "    'scripts\BPSRRelayManager.ps1',`r`n    'scripts\ServeProfile.ps1'" `
    -New "    'scripts\BPSRRelayManager.ps1',`r`n    'scripts\ManagerUi.ps1',`r`n    'scripts\ServeProfile.ps1'"

Write-Host 'RC.10 UI status and release packaging fixes applied.'
