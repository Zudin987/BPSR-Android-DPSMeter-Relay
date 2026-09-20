$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Replace-ExactlyOnce([string]$text, [string]$before, [string]$after, [string]$label) {
    $i = $text.IndexOf($before, [StringComparison]::Ordinal)
    if ($i -lt 0 -or $text.IndexOf($before, $i + $before.Length, [StringComparison]::Ordinal) -ge 0) { throw ('Missing or ambiguous ' + $label) }
    return $text.Substring(0, $i) + $after + $text.Substring($i + $before.Length)
}
$enginePath = Join-Path $root 'src\BpsrRelayManager\RelayEngine.cs'
$engine = [IO.File]::ReadAllText($enginePath).Replace("`r`n", "`n")
$engine = Replace-ExactlyOnce $engine "            AssertFrontPortFree(ip);`n            AssertFrontPortFree(ip);" '            AssertFrontPortFree(ip);' 'duplicate port preflight'
$engine = Replace-ExactlyOnce $engine "        public void MarkPhoneProfileDownloaded()`n        {`n            string id = GetCurrentProfileId();`n            if (string.IsNullOrWhiteSpace(id)) return;" "        public void MarkPhoneProfileDownloaded()`n        {`n            string id = GetCurrentProfileId();`n            // Repeated browser/SFA fetches cannot revoke explicit confirmation for this profile.`n            if (string.IsNullOrWhiteSpace(id) || PhoneProfileConfirmed()) return;" 'phone import confirmation preservation'
[IO.File]::WriteAllText($enginePath, $engine, $utf8)
$readinessPath = Join-Path $root 'scripts\TestNativeReadiness.ps1'
$readiness = [IO.File]::ReadAllText($readinessPath).Replace("`r`n", "`n")
$readiness = Replace-ExactlyOnce $readiness 'info.Invoke(engine, new object[] { argument });' 'info.Invoke(engine, info.GetParameters().Length == 0 ? null : new object[] { argument });' 'reflection zero-argument invocation'
[IO.File]::WriteAllText($readinessPath, $readiness, $utf8)
$smokePath = Join-Path $root 'scripts\TestRelaySmoke.ps1'
$smoke = [IO.File]::ReadAllText($smokePath).Replace("`r`n", "`n")
$lines = @(
    '    $udpScript = Join-Path $scriptDir ''TestSocksUdp.ps1'''
    '    if (-not (Test-Path -LiteralPath $udpScript -PathType Leaf)) { throw ''Authenticated SOCKS5 UDP smoke test is missing.'' }'
    '    & $udpScript -FrontPort $frontPort -Username $frontUsername -Password $frontPassword'
    '    $frontProcess.Refresh()'
    '    $backProcess.Refresh()'
    '    Write-Host (''LOCAL SYNTHETIC RESOURCE SNAPSHOT: front/back working set MB '' + [Math]::Round($frontProcess.WorkingSet64 / 1MB, 1) + ''/'' + [Math]::Round($backProcess.WorkingSet64 / 1MB, 1) + ''; handles '' + $frontProcess.HandleCount + ''/'' + $backProcess.HandleCount + ''. Not real gameplay benchmarking.'')'
    '    $curl = Get-Command curl.exe -ErrorAction Stop'
)
$smoke = Replace-ExactlyOnce $smoke '    $curl = Get-Command curl.exe -ErrorAction Stop' ([string]::Join("`n", [string[]]$lines)) 'two-stage UDP and resource smoke'
[IO.File]::WriteAllText($smokePath, $smoke, $utf8)
foreach ($path in @('.github\workflows\finalize-audit-once.yml', '.github\workflows\finalize-audit-patch.yml', 'scripts\FinalizeAuditPatch.ps1')) {
    $full = Join-Path $root $path
    if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force }
}
Write-Host 'FINAL NATIVE AUDIT PATCH APPLIED: confirmation, duplicate guard, reflection test, UDP smoke; temporary files removed.'
