param(
    [string]$ConfigPath = ".\bridge.config.json",
    [string]$DisplayName = "ShareToObsidian Bridge",
    [string]$Profile = "Private"
)

$ErrorActionPreference = "Stop"

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required to create or update Windows Firewall rules."
}

$ConfigFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
$Config = Get-Content -LiteralPath $ConfigFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Port = [int]$Config.port

if ($Port -lt 1 -or $Port -gt 65535) {
    throw "Invalid bridge port in config: $Port"
}

$ExistingRule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
if ($ExistingRule) {
    $ExistingRule |
        Set-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -Profile $Profile
    $ExistingRule |
        Get-NetFirewallPortFilter |
        Set-NetFirewallPortFilter -Protocol TCP -LocalPort $Port
} else {
    New-NetFirewallRule `
        -DisplayName $DisplayName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -Profile $Profile | Out-Null
}

$Rule = Get-NetFirewallRule -DisplayName $DisplayName
$PortFilter = $Rule | Get-NetFirewallPortFilter

Write-Host "Firewall rule ready:"
Write-Host "DisplayName: $($Rule.DisplayName)"
Write-Host "Enabled: $($Rule.Enabled)"
Write-Host "Direction: $($Rule.Direction)"
Write-Host "Action: $($Rule.Action)"
Write-Host "Profile: $($Rule.Profile)"
Write-Host "Protocol: $($PortFilter.Protocol)"
Write-Host "LocalPort: $($PortFilter.LocalPort)"
