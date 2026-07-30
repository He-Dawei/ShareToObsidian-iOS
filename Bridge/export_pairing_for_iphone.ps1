param(
    [string]$ConfigPath = ".\bridge.config.json",
    [string]$OutputPath = ".\pairing.iphone.json",
    [string]$OutputURLPath = ".\pairing.iphone.url.txt",
    [string]$OutputHTMLPath = ".\pairing.iphone.html",
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
$PairingURL = "sharetoobsidian://pair?bridgeURL=$([System.Uri]::EscapeDataString($BridgeURL))&token=$([System.Uri]::EscapeDataString([string]$Config.token))"
$OutputFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$OutputURLFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputURLPath)
$OutputHTMLFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputHTMLPath)
$PairingURLHtml = [System.Net.WebUtility]::HtmlEncode($PairingURL)
$JsonHtml = [System.Net.WebUtility]::HtmlEncode($Json)
$BridgeURLHtml = [System.Net.WebUtility]::HtmlEncode($BridgeURL)
$Html = @"
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ShareToObsidian iPhone Pairing</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 24px; line-height: 1.45; }
    a.button { display: inline-block; padding: 12px 16px; background: #0a7cff; color: white; border-radius: 8px; text-decoration: none; font-weight: 600; }
    code, pre { background: #f3f4f6; border-radius: 6px; }
    pre { padding: 12px; overflow-x: auto; }
    .warning { color: #9a3412; font-weight: 600; }
  </style>
</head>
<body>
  <h1>ShareToObsidian iPhone Pairing</h1>
  <p>Bridge URL: <code>$BridgeURLHtml</code></p>
  <p><a class="button" href="$PairingURLHtml">Open ShareToObsidian pairing link</a></p>
  <p class="warning">This file contains your Bridge token. Only send it to your own iPhone.</p>
  <h2>Fallback JSON</h2>
  <p>If the pairing link cannot open the app, copy this JSON into the app Sync settings.</p>
  <pre>$JsonHtml</pre>
</body>
</html>
"@
[System.IO.File]::WriteAllText($OutputFullPath, $Json, $Utf8NoBom)
[System.IO.File]::WriteAllText($OutputURLFullPath, $PairingURL, $Utf8NoBom)
[System.IO.File]::WriteAllText($OutputHTMLFullPath, $Html, $Utf8NoBom)

try {
    Set-Clipboard -Value $PairingURL
    $ClipboardStatus = "copied"
} catch {
    $ClipboardStatus = "failed: $($_.Exception.Message)"
}

Write-Host "Wrote iPhone pairing config:"
Write-Host $OutputFullPath
Write-Host $OutputURLFullPath
Write-Host $OutputHTMLFullPath
Write-Host "Bridge URL: $BridgeURL"
Write-Host "Clipboard pairing link: $ClipboardStatus"
Write-Host "Token: hidden. Pairing JSON/URL/HTML files contain the token. Use -ShowSecret only if you need to inspect them."

if ($ShowSecret) {
    Write-Host ""
    Write-Host $Json
    Write-Host ""
    Write-Host $PairingURL
}
