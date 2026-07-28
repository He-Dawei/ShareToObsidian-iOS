param(
    [string]$TaskName = "ShareToObsidianBridge",
    [string]$ProjectDir = "C:\Users\44527\Documents\Codex\2026-07-24\codex-reconnecting-codex-env-3\outputs\share-to-obsidian-ios\Bridge"
)

$ErrorActionPreference = "Stop"
$Launcher = Join-Path $ProjectDir "start_bridge.ps1"

$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Launcher`" -ProjectDir `"$ProjectDir`""
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
$Settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
Write-Host "Installed scheduled task: $TaskName"
