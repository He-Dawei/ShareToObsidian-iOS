param(
    [string]$OutputDirectory = "",
    [string]$PackageName = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function New-TextFromCodePoints {
    param([int[]]$CodePoints)
    -join ($CodePoints | ForEach-Object { [char]$_ })
}

if (-not $OutputDirectory) {
    $OutputDirectory = "E:\claude code" + (New-TextFromCodePoints @(29983, 25104, 25991, 20214))
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
if (-not $PackageName) {
    $PackageName = "share-to-obsidian-ios-mac-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".zip"
}
if (-not $PackageName.EndsWith(".zip", [System.StringComparison]::OrdinalIgnoreCase)) {
    $PackageName += ".zip"
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$zipPath = Join-Path $OutputDirectory $PackageName
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("share-to-obsidian-mac-" + [guid]::NewGuid().ToString("N"))
$stageProject = Join-Path $stageRoot "share-to-obsidian-ios"

$includePaths = @(
    "App",
    "Shared",
    "ShareExtension",
    "Docs",
    "Scripts\verify_mac_ios_project.sh",
    "project.yml",
    "README.md"
)

try {
    New-Item -ItemType Directory -Path $stageProject -Force | Out-Null

    foreach ($relative in $includePaths) {
        $source = Join-Path $repoRoot $relative
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Missing package source: $relative"
        }
        $destination = Join-Path $stageProject $relative
        $destinationParent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
    }

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path $stageProject -DestinationPath $zipPath -Force

    Write-Host "Wrote Mac build package:"
    Write-Host $zipPath
    Write-Host "Package intentionally excludes Bridge config, pairing files, tokens, data, and Python caches."
} finally {
    if (Test-Path -LiteralPath $stageRoot) {
        $resolvedStage = [System.IO.Path]::GetFullPath($stageRoot)
        $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if (-not $resolvedStage.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove staging directory outside temp: $resolvedStage"
        }
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
}
