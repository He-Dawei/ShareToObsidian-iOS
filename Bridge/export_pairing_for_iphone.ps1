param(
    [string]$ConfigPath = ".\bridge.config.json",
    [string]$OutputPath = ".\pairing.iphone.json",
    [switch]$ShowSecret
)

$ErrorActionPreference = "Stop"

$ConfigFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
$Config = Get-Content -LiteralPath $ConfigFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($Config.token)) {
    throw "Bridge token is empty. Run Bridge\write_pairing_config.ps1 -RotateToken first."
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

$VaultPairingPath = Join-Path (Join-Path $Config.obsidian_vault $Config.notes_subdir) "pairing.iphone.json"
[System.IO.File]::WriteAllText($VaultPairingPath, $Json, $Utf8NoBom)

try {
    Set-Clipboard -Value $Json
    $ClipboardStatus = "copied"
} catch {
    $ClipboardStatus = "failed: $($_.Exception.Message)"
}

Write-Host "Wrote iPhone pairing config:"
Write-Host $OutputFullPath
Write-Host $VaultPairingPath
Write-Host "Bridge URL: $BridgeURL"
Write-Host "Clipboard: $ClipboardStatus"
Write-Host "Token: hidden. Use -ShowSecret only if you need to inspect the JSON."

if ($ShowSecret) {
    Write-Host ""
    Write-Host $Json
}
