param(
    [string]$ProjectDir = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
$PythonCandidates = @(
    (Join-Path (Split-Path -Parent $ProjectDir) ".venv\Scripts\python.exe"),
    (Join-Path $ProjectDir ".venv\Scripts\python.exe"),
    "C:\Users\44527\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
)
$Python = $PythonCandidates |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
$Script = Join-Path $ProjectDir "obsidian_bridge.py"
$Config = Join-Path $ProjectDir "bridge.config.json"

if (-not $Python) {
    throw "Python runtime not found. Create $((Split-Path -Parent $ProjectDir))\.venv with uv venv."
}
if (-not (Test-Path -LiteralPath $Script)) {
    throw "Bridge script not found: $Script"
}
if (-not (Test-Path -LiteralPath $Config)) {
    throw "Bridge config not found: $Config"
}

$resolvedScript = [System.IO.Path]::GetFullPath($Script)
$oldBridgeProcesses = Get-CimInstance Win32_Process |
    Where-Object {
        $_.CommandLine -like "*obsidian_bridge.py*" -and
        $_.CommandLine -like "*$resolvedScript*"
    }

foreach ($process in $oldBridgeProcesses) {
    try {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    } catch {
        Write-Warning "Unable to stop old Bridge process $($process.ProcessId): $($_.Exception.Message)"
    }
}

Set-Location -LiteralPath $ProjectDir
& $Python $Script --config $Config
