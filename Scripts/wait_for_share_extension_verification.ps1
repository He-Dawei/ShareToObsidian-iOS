param(
    [string]$ConfigPath = "",
    [string]$ExpectedURL = "https://example.com/share-to-obsidian-share-extension-verify",
    [int]$TimeoutSeconds = 300,
    [int]$PollSeconds = 3,
    [switch]$SkipTaskStart
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot "Bridge\bridge.config.json"
}
$configFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
$config = Get-Content -LiteralPath $configFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
$notesRoot = [System.IO.Path]::GetFullPath((Join-Path ([string]$config.obsidian_vault) ([string]$config.notes_subdir)))
$noteDirs = @(
    (Join-Path $notesRoot "10_Notes"),
    (Join-Path $notesRoot ([string]$config.inbox_subdir))
)
$bridgeURL = "http://127.0.0.1:$($config.port)"
$startedAt = (Get-Date).AddSeconds(-2)
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

function Test-BridgeHealth {
    try {
        $health = Invoke-RestMethod -Method GET -Uri "$bridgeURL/health" -TimeoutSec 5
        return [bool]$health.ok
    } catch {
        return $false
    }
}

function Find-SharedFile {
    foreach ($dir in $noteDirs) {
        if (-not (Test-Path -LiteralPath $dir)) {
            continue
        }
        $recentFiles = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $startedAt } |
            Sort-Object LastWriteTime -Descending
        foreach ($file in $recentFiles) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($text -and $text.Contains($ExpectedURL)) {
                return $file.FullName
            }
        }
    }
    return $null
}

if (-not (Test-Path -LiteralPath $notesRoot)) {
    throw "Notes root does not exist: $notesRoot"
}

if (-not $SkipTaskStart) {
    try {
        $task = Get-ScheduledTask -TaskName "ShareToObsidianBridge" -ErrorAction SilentlyContinue
        if ($task -and $task.State -ne "Running") {
            Start-ScheduledTask -TaskName "ShareToObsidianBridge"
            Start-Sleep -Seconds 3
        }
    } catch {
        Write-Warning "Unable to start ShareToObsidianBridge task: $($_.Exception.Message)"
    }
}

if (-not (Test-BridgeHealth)) {
    throw "Bridge health check failed: $bridgeURL/health"
}

Write-Host "Bridge OK: $bridgeURL"
Write-Host "Notes root: $notesRoot"
Write-Host "Waiting for Share Extension verification capture."
Write-Host "On iPhone: open Safari -> open or type $ExpectedURL -> Share -> Save to Obsidian."
Write-Host "Timeout seconds: $TimeoutSeconds"

while ((Get-Date) -lt $deadline) {
    $found = Find-SharedFile
    if ($found) {
        Write-Host "SHARE_EXTENSION_VERIFICATION_OK"
        Write-Host $found
        exit 0
    }
    Start-Sleep -Seconds $PollSeconds
}

throw "SHARE_EXTENSION_VERIFICATION_TIMEOUT. No recent Obsidian file contained $ExpectedURL"
