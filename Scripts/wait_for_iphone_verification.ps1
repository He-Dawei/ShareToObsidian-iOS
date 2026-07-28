param(
    [string]$ConfigPath = "",
    [int]$TimeoutSeconds = 180,
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
$needleURL = "https://example.com/share-to-obsidian-ios-verify"
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

function Find-VerificationFile {
    foreach ($dir in $noteDirs) {
        if (-not (Test-Path -LiteralPath $dir)) {
            continue
        }
        $recentFiles = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $startedAt } |
            Sort-Object LastWriteTime -Descending
        foreach ($file in $recentFiles) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($text -and $text.Contains($needleURL)) {
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
Write-Host "Waiting for iPhone verification capture."
Write-Host "On iPhone: open ShareToObsidian -> Sync settings -> tap Send Verification Capture."
Write-Host "Timeout seconds: $TimeoutSeconds"

while ((Get-Date) -lt $deadline) {
    $found = Find-VerificationFile
    if ($found) {
        Write-Host "IPHONE_VERIFICATION_OK"
        Write-Host $found
        exit 0
    }
    Start-Sleep -Seconds $PollSeconds
}

throw "IPHONE_VERIFICATION_TIMEOUT. No recent Obsidian file contained $needleURL"
