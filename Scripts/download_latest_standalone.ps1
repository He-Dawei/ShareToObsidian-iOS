param(
    [string]$OutputDirectory = "",
    [string]$OutputName = "ShareToObsidian-standalone-latest.ipa"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function New-TextFromCodePoints {
    param([int[]]$CodePoints)
    -join ($CodePoints | ForEach-Object { [char]$_ })
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = "E:\claude code" + (New-TextFromCodePoints @(29983,25104,25991,20214))
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$release = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/He-Dawei/ShareToObsidian-iOS/releases/tags/standalone-latest" `
    -Headers @{ "User-Agent" = "Codex" }

$asset = $release.assets |
    Where-Object { $_.name -eq "ShareToObsidian-standalone.ipa" } |
    Select-Object -First 1

if (-not $asset) {
    throw "Release asset not found: ShareToObsidian-standalone.ipa"
}

$outputPath = Join-Path $OutputDirectory $OutputName
Invoke-WebRequest -Uri $asset.browser_download_url -Headers @{ "User-Agent" = "Codex" } -OutFile $outputPath

$file = Get-Item -LiteralPath $outputPath
[pscustomobject]@{
    ipa = $file.FullName
    bytes = $file.Length
    release = $release.html_url
    download = $asset.browser_download_url
} | ConvertTo-Json -Depth 3
