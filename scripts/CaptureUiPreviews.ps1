param(
    [string]$Executable = '.build\native\BPSR Relay Manager.exe',
    [string]$OutputDirectory = '.build\ui-previews'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
$assembly = [System.Reflection.Assembly]::LoadFrom((Resolve-Path $Executable).Path)
$engineType = $assembly.GetType('BpsrRelayManager.RelayEngine', $true)
$formType = $assembly.GetType('BpsrRelayManager.MainForm', $true)
$flags = [System.Reflection.BindingFlags]'Instance,Public,NonPublic'
$testRoot = Join-Path $env:TEMP ('relay-ui-preview-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = (Resolve-Path $OutputDirectory).Path

function Save-Preview([System.Windows.Forms.Form]$Window, [string]$Name) {
    $Window.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $bitmap = New-Object System.Drawing.Bitmap($Window.Width, $Window.Height)
    try {
        $Window.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $Window.Width, $Window.Height)))
        $bitmap.Save((Join-Path $output ($Name + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose(); $Window.Hide() }
}

try {
    $engineConstructor = $engineType.GetConstructor([type[]]@([string], [Action[string]]))
    $engine = $engineConstructor.Invoke([object[]]@([string]$testRoot, $null))
    $formConstructor = $formType.GetConstructor([type[]]@($engineType, [bool]))
    $form = $formConstructor.Invoke([object[]]@($engine, $true))
    $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Resolve-Path $Executable).Path)
    try {
        $formType.GetMethod('RunUiSelfTest', $flags).Invoke($form, @()) | Out-Null
        Save-Preview $form 'home-100'
        $prompt = $formType.GetMethod('CreatePhoneSetupPrompt', $flags).Invoke($form, @($false))
        try {
            Save-Preview $prompt 'phone-setup-100'
            $prompt.Scale((New-Object System.Drawing.SizeF(1.25, 1.25)))
            Save-Preview $prompt 'phone-setup-125'
        }
        finally { $prompt.Dispose() }
        $form.Scale((New-Object System.Drawing.SizeF(1.25, 1.25)))
        Save-Preview $form 'home-125'
    }
    finally { $form.Dispose() }
}
finally {
    if (Test-Path $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
Write-Host 'UI previews captured at 100% and 125% scale.'
