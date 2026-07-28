param(
    [string]$ConfigPath = ".\bridge.config.json",
    [string]$OutputPath = ".\pairing.local.json",
    [switch]$RotateToken
)

$ErrorActionPreference = "Stop"

$ConfigFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
$Config = Get-Content -LiteralPath $ConfigFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($RotateToken -or [string]::IsNullOrWhiteSpace($Config.token)) {
    $Bytes = New-Object byte[] 32
    $Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $Rng.GetBytes($Bytes)
    } finally {
        $Rng.Dispose()
    }
    $Config.token = [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $ConfigJson = $Config | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($ConfigFullPath, $ConfigJson, $Utf8NoBom)
}
$Ip = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -notlike "127.*" -and
        $_.IPAddress -notlike "169.254.*" -and
        $_.PrefixOrigin -ne "WellKnown"
    } |
    Sort-Object InterfaceMetric |
    Select-Object -First 1 -ExpandProperty IPAddress)

if (-not $Ip) {
    $Ip = "127.0.0.1"
}

$BridgeURL = "http://$Ip`:$($Config.port)"
$Pairing = [ordered]@{
    bridgeURL = $BridgeURL
    token = $Config.token
    notesRoot = (Join-Path $Config.obsidian_vault $Config.notes_subdir)
    createdAt = (Get-Date).ToUniversalTime().ToString("o")
}

$Json = $Pairing | ConvertTo-Json -Depth 4
$OutputFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
[System.IO.File]::WriteAllText($OutputFullPath, $Json, $Utf8NoBom)

$VaultPairingPath = Join-Path (Join-Path $Config.obsidian_vault $Config.notes_subdir) "pairing.local.json"
[System.IO.File]::WriteAllText($VaultPairingPath, $Json, $Utf8NoBom)

Write-Host "Wrote pairing config:"
Write-Host $OutputFullPath
Write-Host $VaultPairingPath
Write-Host ""
Write-Host $Json
