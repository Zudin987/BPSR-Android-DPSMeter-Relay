param(
    [Parameter(Mandatory = $true)][int]$FrontPort,
    [Parameter(Mandatory = $true)][string]$Username,
    [Parameter(Mandatory = $true)][string]$Password
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'TestSocksUdp.cs'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'SOCKS UDP smoke source missing.' }
Add-Type -Path $source
$latency = [SocksUdpSmoke]::Run($FrontPort, $Username, $Password)
Write-Host ('TWO-STAGE UDP SMOKE PASS: authenticated UDP ASSOCIATE, verified echo payload; single local-loopback sample ' + [Math]::Round($latency, 2) + ' ms (not real gameplay latency).')
