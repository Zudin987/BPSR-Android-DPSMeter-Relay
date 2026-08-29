$ErrorActionPreference = 'Stop'

$manager = Join-Path $PSScriptRoot 'BPSRRelayManager.ps1'

try {
    if (-not (Test-Path -LiteralPath $manager -PathType Leaf)) {
        throw 'BPSRRelayManager.ps1 was not found next to the launcher.'
    }

    & $manager
}
catch {
    $message = $_.Exception.Message
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'BPSR Relay Manager could not start',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
        Write-Host ('BPSR Relay Manager could not start: ' + $message)
    }
    exit 1
}
