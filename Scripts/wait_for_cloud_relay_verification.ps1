param(
    [string]$ConfigPath = "",
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
$relayRoot = [System.IO.Path]::GetFullPath([string]$config.cloud_relay_dir)
$noteDirs = @(
    (Join-Path $notesRoot "10_Notes"),
    (Join-Path $notesRoot ([string]$config.inbox_subdir))
)
$needleURL = "https://example.com/share-to-obsidian-icloud-relay-verify"
$startedAt = (Get-Date).AddSeconds(-2)
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

function Find-VerificationFile {
    foreach ($dir in $noteDirs) {
        if (-not (Test-Path -LiteralPath $dir)) {
            continue
        }
        foreach ($file in (Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $startedAt } |
            Sort-Object LastWriteTime -Descending)) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($text -and $text.Contains($needleURL)) {
                return $file.FullName
            }
        }
    }
    return $null
}

if (-not (Test-Path -LiteralPath $relayRoot)) {
    throw "iCloud relay root does not exist: $relayRoot"
}
if (-not $SkipTaskStart) {
    $task = Get-ScheduledTask -TaskName "ShareToObsidianBridge" -ErrorAction SilentlyContinue
    if ($task -and $task.State -ne "Running") {
        Start-ScheduledTask -TaskName "ShareToObsidianBridge"
        Start-Sleep -Seconds 3
    }
}

Write-Host "iCloud relay: $relayRoot"
Write-Host "Waiting for iPhone offline relay verification."
Write-Host "On iPhone: ShareToObsidian -> Sync settings -> Send Offline Relay Verification."
Write-Host "Timeout seconds: $TimeoutSeconds"

while ((Get-Date) -lt $deadline) {
    $found = Find-VerificationFile
    if ($found) {
        Write-Host "ICLOUD_RELAY_VERIFICATION_OK"
        Write-Host $found
        exit 0
    }
    Start-Sleep -Seconds $PollSeconds
}

throw "ICLOUD_RELAY_VERIFICATION_TIMEOUT. No recent Obsidian file contained $needleURL"
