param(
    [string]$ConfigPath = ".\Bridge\bridge.config.json",
    [string]$BaseUrl = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Resolve-RepoPath([string]$PathValue) {
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return (Resolve-Path -LiteralPath $PathValue).Path
    }
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\$PathValue")).Path
}

function Invoke-JsonRequest {
    param(
        [string]$Method,
        [string]$Uri,
        [object]$Body = $null,
        [hashtable]$Headers = @{}
    )

    $params = @{
        Method = $Method
        Uri = $Uri
        TimeoutSec = 15
        Headers = $Headers
    }
    if ($null -ne $Body) {
        $params.ContentType = "application/json; charset=utf-8"
        $params.Body = ($Body | ConvertTo-Json -Depth 12)
    }
    Invoke-RestMethod @params
}

function Get-StatusCode {
    param([scriptblock]$Request)
    try {
        & $Request | Out-Null
        return 200
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            return [int]$_.Exception.Response.StatusCode
        }
        throw
    }
}

function Invoke-ErrorJsonRequest {
    param(
        [string]$Method,
        [string]$Uri,
        [object]$Body = $null
    )

    try {
        $params = @{
            Method = $Method
            Uri = $Uri
            TimeoutSec = 15
            UseBasicParsing = $true
        }
        if ($null -ne $Body) {
            $params.ContentType = "application/json; charset=utf-8"
            $params.Body = ($Body | ConvertTo-Json -Depth 12)
        }
        Invoke-WebRequest @params | Out-Null
        throw "Expected an HTTP error response from $Uri"
    } catch {
        if (-not $_.Exception.Response) {
            throw
        }
        $bodyText = [string]$_.ErrorDetails.Message
        if (-not $bodyText) {
            throw "Expected a JSON error body from $Uri"
        }
        return [pscustomobject]@{
            StatusCode = [int]$_.Exception.Response.StatusCode
            ContentType = [string]$_.Exception.Response.ContentType
            Body = $bodyText
            Json = $bodyText | ConvertFrom-Json
        }
    }
}

function New-TextFromCodePoints {
    param([int[]]$CodePoints)
    -join ($CodePoints | ForEach-Object { [char]$_ })
}

$repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")
$configFullPath = Resolve-RepoPath $ConfigPath
$config = Get-Content -LiteralPath $configFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pythonPath = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
if (-not (Test-Path -LiteralPath $pythonPath)) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCommand) {
        throw "Unable to find Python for bridge logic verification."
    }
    $pythonPath = $pythonCommand.Source
}

if (-not $BaseUrl) {
    $BaseUrl = "http://127.0.0.1:$($config.port)"
}
$BaseUrl = $BaseUrl.TrimEnd("/")
$token = [string]$config.token
$notesRoot = Join-Path ([string]$config.obsidian_vault) ([string]$config.notes_subdir)

Write-Host "Repo: $repoRoot"
Write-Host "Bridge: $BaseUrl"
Write-Host "Notes root: $notesRoot"

$oldTask = Get-ScheduledTask -TaskName "DouyinFavoritesToObsidian" -ErrorAction SilentlyContinue
$newTask = Get-ScheduledTask -TaskName "ShareToObsidianBridge" -ErrorAction SilentlyContinue
if ($oldTask) {
    throw "Old scheduled task still exists: DouyinFavoritesToObsidian"
}
if (-not $newTask) {
    throw "Missing scheduled task: ShareToObsidianBridge"
}
if ($newTask.State -ne "Running") {
    throw "ShareToObsidianBridge is not running: $($newTask.State)"
}
$taskActionText = ($newTask.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join "`n"
if (-not $taskActionText.Contains("start_bridge.ps1")) {
    throw "ShareToObsidianBridge task must launch Bridge\start_bridge.ps1."
}
if ([string]$newTask.Settings.MultipleInstances -ne "IgnoreNew") {
    throw "ShareToObsidianBridge task MultipleInstances must be IgnoreNew."
}
$bridgePythonProcesses = Get-CimInstance Win32_Process |
    Where-Object {
        $_.CommandLine -like "*python.exe*" -and
        $_.CommandLine -like "*obsidian_bridge.py*"
    }
if (($bridgePythonProcesses | Measure-Object).Count -ne 1) {
    throw "Expected exactly one Python obsidian_bridge.py process."
}
Write-Host "Scheduled task check passed."

$firewallRule = Get-NetFirewallRule -DisplayName "ShareToObsidian Bridge" -ErrorAction SilentlyContinue
if (-not $firewallRule) {
    throw "Missing firewall rule: ShareToObsidian Bridge"
}
$firewallPortFilter = $firewallRule | Get-NetFirewallPortFilter
if ($firewallRule.Enabled -ne "True" -or
    $firewallRule.Direction -ne "Inbound" -or
    $firewallRule.Action -ne "Allow" -or
    $firewallPortFilter.Protocol -ne "TCP" -or
    [string]$firewallPortFilter.LocalPort -ne [string]$config.port) {
    throw "Firewall rule ShareToObsidian Bridge must allow inbound TCP port $($config.port)."
}
Write-Host "Firewall check passed."

$health = Invoke-JsonRequest -Method "GET" -Uri "$BaseUrl/health"
if (-not $health.ok) {
    throw "Bridge health is not ok."
}
if (-not $health.queueWritable) {
    throw "Bridge notes root is not writable."
}
Write-Host "Health check passed."

$statusWithoutAuth = Get-StatusCode {
    Invoke-JsonRequest -Method "POST" -Uri "$BaseUrl/metadata" -Body @{ url = "https://example.com/no-auth-check" }
}
if ($token -and $statusWithoutAuth -ne 401) {
    throw "Expected 401 without bearer token, got $statusWithoutAuth"
}
if ($token) {
    $authError = Invoke-ErrorJsonRequest -Method "POST" -Uri "$BaseUrl/metadata" -Body @{ url = "https://example.com/no-auth-check" }
    if ($authError.StatusCode -ne 401 -or
        $authError.ContentType -notlike "application/json*" -or
        -not $authError.Json.error -or
        $authError.Json.error.code -ne "UNAUTHORIZED" -or
        $authError.Json.error.message -notlike "*token*") {
        throw "Expected JSON 401 UNAUTHORIZED error response from Bridge."
    }
}
Write-Host "Auth check passed."

$headers = @{}
if ($token) {
    $headers.Authorization = "Bearer $token"
}

$id = [guid]::NewGuid().ToString("N")
$title = "Windows Bridge Verify $id"
$coreContent = New-TextFromCodePoints @(26680,24515,20869,23481)
$videoIntro = New-TextFromCodePoints @(35270,39057,20171,32461)
$nextActions = New-TextFromCodePoints @(21518,32493,34892,21160)
$pendingSummary = New-TextFromCodePoints @(24453,25552,28860)
$mobileFavorites = New-TextFromCodePoints @(31227,21160,25910,34255)
$pendingDeleteLabel = New-TextFromCodePoints @(24453,21024,38500)
$pendingDeleteQueued = New-TextFromCodePoints @(24050,21152,20837,24453,21024,38500,38431,21015)
$pendingDeleteInProgress = New-TextFromCodePoints @(35813,26465,30446,27491,22312,31561,24453,21024,38500,36828,31471,31508,35760)
$knowledgeDir = New-TextFromCodePoints @(57,48,95,75,110,111,119,108,101,100,103,101)
$frameworkFile = (New-TextFromCodePoints @(25910,34255,30693,35782,26694,26550)) + ".md"
$aiContextFile = (New-TextFromCodePoints @(65,73,23398,20064,19978,19979,25991)) + ".md"
$payload = @{
    id = $id
    url = "https://example.com/share-to-obsidian-verify-$id"
    platform = "web"
    title = $title
    summary = "Verification item created by Scripts/verify_windows_bridge.ps1."
    draftMarkdown = "# $title`n`n## $coreContent`n`nVerification item. Safe to delete.`n"
    alternativeDrafts = @()
    tags = @("verify", "share-to-obsidian")
    status = "queued"
    isUserEdited = $true
    createdAt = (Get-Date).ToUniversalTime().ToString("o")
    updatedAt = (Get-Date).ToUniversalTime().ToString("o")
    sourceApp = "windows-verifier"
}

$draft = Invoke-JsonRequest -Method "POST" -Uri "$BaseUrl/drafts" -Body $payload -Headers $headers
if (-not $draft.summary -or -not $draft.markdown -or -not $draft.alternatives -or $draft.alternatives.Count -lt 3) {
    throw "Draft endpoint did not return summary + markdown + 3 alternatives."
}
foreach ($needle in @("## $coreContent", "## $videoIntro", "## $nextActions")) {
    if ([string]$draft.markdown -notlike "*$needle*") {
        throw "Draft markdown missing readable Chinese section: $needle"
    }
}
Write-Host "Draft generation check passed."

$push = Invoke-JsonRequest -Method "POST" -Uri "$BaseUrl/captures?fast=1" -Body $payload -Headers $headers
if (-not $push.ok -or -not $push.relativePath) {
    throw "Fast capture did not return ok + relativePath."
}
if (-not $push.item -or $push.item.id -ne $payload.id -or -not $push.item.tags) {
    throw "Fast capture did not return the enriched capture item."
}

$notePath = Join-Path $notesRoot ([string]$push.relativePath)
if (-not (Test-Path -LiteralPath $notePath)) {
    throw "Expected note was not written: $notePath"
}
Write-Host "Fast capture check passed: $($push.relativePath)"

$payload["remoteNotePath"] = $push.relativePath
$payload["draftMarkdown"] = "# $title`n`n## $coreContent`n`nVerification overwrite update.`n"
$overwrite = Invoke-JsonRequest -Method "POST" -Uri "$BaseUrl/captures" -Body $payload -Headers $headers
if (-not $overwrite.ok -or $overwrite.relativePath -ne $push.relativePath) {
    throw "Expected overwrite to keep the same remote note path."
}
$overwrittenText = Get-Content -LiteralPath $notePath -Raw -Encoding UTF8
if (-not $overwrittenText.Contains("Verification overwrite update.")) {
    throw "Overwrite capture did not update the existing note content."
}
$frameworkPath = Join-Path (Join-Path $notesRoot $knowledgeDir) $frameworkFile
if (Test-Path -LiteralPath $frameworkPath) {
    $frameworkText = Get-Content -LiteralPath $frameworkPath -Raw -Encoding UTF8
    $escapedRel = [regex]::Escape(([string]$push.relativePath).Replace(".md", ""))
    $matchCount = ([regex]::Matches($frameworkText, $escapedRel)).Count
    if ($matchCount -ne 1) {
        throw "Expected exactly one framework index reference after overwrite, got $matchCount."
    }
}
$aiContextPath = Join-Path (Join-Path $notesRoot $knowledgeDir) $aiContextFile
if (-not (Test-Path -LiteralPath $aiContextPath)) {
    throw "Missing AI learning context file: $aiContextPath"
}
$aiContextText = Get-Content -LiteralPath $aiContextPath -Raw -Encoding UTF8
if (-not $aiContextText.Contains("Codex/Claude") -or -not $aiContextText.Contains(([string]$push.relativePath).Replace(".md", ""))) {
    throw "AI learning context does not reference the verifier note."
}
Write-Host "Overwrite capture check passed."

$deleteResult = Invoke-JsonRequest -Method "POST" -Uri "$BaseUrl/captures/delete" -Body @{ path = $push.relativePath } -Headers $headers
if (-not $deleteResult.ok) {
    throw "Delete endpoint did not return ok."
}
if (Test-Path -LiteralPath $notePath) {
    throw "Note still exists after delete: $notePath"
}
Write-Host "Delete check passed."

foreach ($movedPath in @($deleteResult.moved)) {
    if (-not $movedPath) {
        continue
    }
    $resolvedMoved = [System.IO.Path]::GetFullPath([string]$movedPath)
    $resolvedRoot = [System.IO.Path]::GetFullPath($notesRoot)
    if (-not $resolvedMoved.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove verifier cleanup outside notes root: $resolvedMoved"
    }
    if (Test-Path -LiteralPath $resolvedMoved) {
        Remove-Item -LiteralPath $resolvedMoved -Force
    }
}
Write-Host "Verifier cleanup passed."

& $pythonPath (Join-Path $repoRoot "Scripts\verify_bridge_logic.py")
if ($LASTEXITCODE -ne 0) {
    throw "Bridge logic verification failed."
}

$requiredFiles = @(
    "project.yml",
    "App\Info.plist",
    "App\CaptureThumbnailView.swift",
    "App\ShareToObsidianApp.swift",
    "App\BackgroundSyncScheduler.swift",
    "App\ShareToObsidian.entitlements",
    "Bridge\start_bridge.ps1",
    "Bridge\ensure_firewall_rule.ps1",
    "Bridge\export_pairing_for_iphone.ps1",
    "Scripts\export_mac_build_package.ps1",
    "ShareExtension\Info.plist",
    "ShareExtension\ShareExtension.entitlements",
    "Shared\CaptureItem.swift",
    "Shared\CaptureFileStore.swift",
    "Shared\CaptureSettingsStore.swift",
    "Shared\CaptureSyncRunner.swift",
    "Shared\SupportedShareURL.swift",
    "Shared\SyncClient.swift",
    "Scripts\verify_mac_ios_project.sh",
    "Docs\MAC_VALIDATION.md"
)
foreach ($relative in $requiredFiles) {
    $path = Join-Path $repoRoot $relative
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing iOS project file: $relative"
    }
}

$projectText = Get-Content -LiteralPath (Join-Path $repoRoot "project.yml") -Raw -Encoding UTF8
foreach ($needle in @(
    "ShareToObsidianShareExtension",
    "deploymentTarget",
    "embed: true",
    "codeSign: true",
    "APPLICATION_EXTENSION_API_ONLY: YES",
    "SKIP_INSTALL: YES"
)) {
    if ($projectText -notlike "*$needle*") {
        throw "project.yml missing expected value: $needle"
    }
}

$macPackageText = Get-Content -LiteralPath (Join-Path $repoRoot "Scripts\export_mac_build_package.ps1") -Raw -Encoding UTF8
foreach ($needle in @(
    "New-TextFromCodePoints",
    "claude code",
    "share-to-obsidian-ios-mac-",
    "Scripts\verify_mac_ios_project.sh",
    "Compress-Archive",
    "Package intentionally excludes Bridge config",
    "Refusing to remove staging directory outside temp"
)) {
    if (-not $macPackageText.Contains($needle)) {
        throw "Mac package export script missing expected safe packaging behavior: $needle"
    }
}

$macVerifyText = Get-Content -LiteralPath (Join-Path $repoRoot "Scripts\verify_mac_ios_project.sh") -Raw -Encoding UTF8
foreach ($needle in @(
    "APP_GROUP_ID",
    "Print :com.apple.security.application-groups:0",
    "Print :UIBackgroundModes:0",
    "Print :BGTaskSchedulerPermittedIdentifiers:0",
    "Print :CFBundleURLTypes:0:CFBundleURLSchemes:0",
    "sharetoobsidian",
    "NSLocalNetworkUsageDescription",
    "Print :NSExtension:NSExtensionPointIdentifier",
    "VERIFY_DEVICE",
    "DEVICE_DESTINATION",
    "DEVELOPMENT_TEAM",
    "Debug-iphoneos",
    "CODE_SIGNING_ALLOWED=YES",
    "Share Extension was not embedded for device build"
)) {
    if (-not $macVerifyText.Contains($needle)) {
        throw "Mac validation script missing expected build gate: $needle"
    }
}

$macValidationDocText = Get-Content -LiteralPath (Join-Path $repoRoot "Docs\MAC_VALIDATION.md") -Raw -Encoding UTF8
foreach ($needle in @(
    "VERIFY_DEVICE=1",
    "DEVELOPMENT_TEAM",
    "DEVICE_DESTINATION",
    "App Group",
    "Local Network",
    "Share Extension"
)) {
    if (-not $macValidationDocText.Contains($needle)) {
        throw "Mac validation doc missing expected device verification guidance: $needle"
    }
}

$firewallScriptText = Get-Content -LiteralPath (Join-Path $repoRoot "Bridge\ensure_firewall_rule.ps1") -Raw -Encoding UTF8
foreach ($needle in @(
    "New-NetFirewallRule",
    "Set-NetFirewallRule",
    "Set-NetFirewallPortFilter",
    "Administrator privileges",
    "ShareToObsidian Bridge"
)) {
    if (-not $firewallScriptText.Contains($needle)) {
        throw "Firewall helper script missing expected behavior: $needle"
    }
}

$pairingExportText = Get-Content -LiteralPath (Join-Path $repoRoot "Bridge\export_pairing_for_iphone.ps1") -Raw -Encoding UTF8
foreach ($needle in @(
    "pairing.iphone.json",
    "pairing.iphone.url.txt",
    "sharetoobsidian://pair?bridgeURL=",
    "[System.Uri]::EscapeDataString",
    "Set-Clipboard -Value `$PairingURL",
    "Clipboard pairing link:",
    "Token: hidden",
    "ShowSecret",
    "Bridge URL:"
)) {
    if (-not $pairingExportText.Contains($needle)) {
        throw "iPhone pairing export script missing expected safe export behavior: $needle"
    }
}

$readmeText = Get-Content -LiteralPath (Join-Path $repoRoot "README.md") -Raw -Encoding UTF8
$quickPairingText = New-TextFromCodePoints @(24555,36895,37197,23545)
$doNotShareText = New-TextFromCodePoints @(19981,35201,20844,24320,20998,20139)
foreach ($needle in @(
    ".\Scripts\export_mac_build_package.ps1",
    "claude code",
    "Bridge token",
    ".\export_pairing_for_iphone.ps1",
    ".\ensure_firewall_rule.ps1",
    "pairing.iphone.json",
    "pairing.iphone.url.txt",
    "sharetoobsidian://pair?...",
    $quickPairingText,
    $doNotShareText
)) {
    if (-not $readmeText.Contains($needle)) {
        throw "README missing iPhone pairing instructions: $needle"
    }
}

$settingsViewText = Get-Content -LiteralPath (Join-Path $repoRoot "App\SettingsView.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "import UIKit",
    "UIPasteboard.general.string",
    'systemImage: "doc.on.clipboard"',
    "await model.importPairing(text: pairingText)"
)) {
    if (-not $settingsViewText.Contains($needle)) {
        throw "SettingsView missing iPhone clipboard pairing import support: $needle"
    }
}

$captureSettingsStoreText = Get-Content -LiteralPath (Join-Path $repoRoot "Shared\CaptureSettingsStore.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "applyPairingText",
    "applyPairingURL",
    "sharetoobsidian",
    "URLComponents(url: url",
    "queryItems",
    '["http", "https"].contains',
    "url.host != nil",
    "bridgeToken = `"`"",
    "config.token ?? `"`""
)) {
    if (-not $captureSettingsStoreText.Contains($needle)) {
        throw "CaptureSettingsStore missing safe pairing import behavior: $needle"
    }
}

$appEntitlements = Get-Content -LiteralPath (Join-Path $repoRoot "App\ShareToObsidian.entitlements") -Raw -Encoding UTF8
$extensionEntitlements = Get-Content -LiteralPath (Join-Path $repoRoot "ShareExtension\ShareExtension.entitlements") -Raw -Encoding UTF8
foreach ($text in @($appEntitlements, $extensionEntitlements)) {
    if ($text -notlike "*group.com.hdwei.ShareToObsidian*") {
        throw "Entitlements missing App Group: group.com.hdwei.ShareToObsidian"
    }
}

$extensionPlist = Get-Content -LiteralPath (Join-Path $repoRoot "ShareExtension\Info.plist") -Raw -Encoding UTF8
$appPlist = Get-Content -LiteralPath (Join-Path $repoRoot "App\Info.plist") -Raw -Encoding UTF8
foreach ($needle in @("CFBundleExecutable", "CFBundleIdentifier", '$(PRODUCT_BUNDLE_IDENTIFIER)', "CFBundlePackageType", "APPL", "CFBundleShortVersionString", "CFBundleVersion", "NSAppTransportSecurity", "NSLocalNetworkUsageDescription", "UIBackgroundModes", "BGTaskSchedulerPermittedIdentifiers", "com.hdwei.ShareToObsidian.sync", "CFBundleURLTypes", "CFBundleURLSchemes", "sharetoobsidian")) {
    if (-not $appPlist.Contains($needle)) {
        throw "App Info.plist missing expected network permission value: $needle"
    }
}
foreach ($needle in @("CFBundleExecutable", "CFBundleIdentifier", '$(PRODUCT_BUNDLE_IDENTIFIER)', "CFBundlePackageType", "XPC!", "CFBundleShortVersionString", "CFBundleVersion", "NSAppTransportSecurity", "NSLocalNetworkUsageDescription", "NSExtensionActivationSupportsWebURLWithMaxCount", "NSExtensionActivationSupportsWebPageWithMaxCount", "NSExtensionActivationSupportsText")) {
    if ($extensionPlist -notlike "*$needle*") {
        throw "ShareExtension Info.plist missing expected value: $needle"
    }
}
$webURLLimitPattern = [regex]::Escape("<key>NSExtensionActivationSupportsWebURLWithMaxCount</key>") + "\s*" + [regex]::Escape("<integer>10</integer>")
if (-not [regex]::IsMatch($extensionPlist, $webURLLimitPattern)) {
    throw "ShareExtension Info.plist must allow up to 10 shared web URLs."
}
$webPageLimitPattern = [regex]::Escape("<key>NSExtensionActivationSupportsWebPageWithMaxCount</key>") + "\s*" + [regex]::Escape("<integer>10</integer>")
if (-not [regex]::IsMatch($extensionPlist, $webPageLimitPattern)) {
    throw "ShareExtension Info.plist must allow up to 10 shared web pages."
}

$appEntryText = Get-Content -LiteralPath (Join-Path $repoRoot "App\ShareToObsidianApp.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "@main",
    "@State private var model: CaptureListModel",
    "@MainActor",
    "_model = State(initialValue: CaptureListModel())",
    "BackgroundSyncScheduler.register()",
    "BackgroundSyncScheduler.schedule()",
    "ContentView(model: model)"
)) {
    if (-not $appEntryText.Contains($needle)) {
        throw "ShareToObsidianApp missing background scheduler registration: $needle"
    }
}

$backgroundSchedulerText = Get-Content -LiteralPath (Join-Path $repoRoot "App\BackgroundSyncScheduler.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "import BackgroundTasks",
    'static let identifier = "com.hdwei.ShareToObsidian.sync"',
    "BGTaskScheduler.shared.register",
    "BGAppRefreshTaskRequest(identifier: identifier)",
    "request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)",
    "CaptureSyncRunner.syncQueued",
    "enrichSyncedMissingMetadata: true",
    "task.expirationHandler",
    "BackgroundTaskCompletion",
    "completion.complete(success: summary.lastError == nil && !Task.isCancelled)",
    "syncTask.cancel()",
    "completion.complete(success: false)",
    "guard !didComplete else",
    "task.setTaskCompleted(success: success)"
)) {
    if (-not $backgroundSchedulerText.Contains($needle)) {
        throw "BackgroundSyncScheduler missing expected background refresh behavior: $needle"
    }
}

$syncClientText = Get-Content -LiteralPath (Join-Path $repoRoot "Shared\SyncClient.swift") -Raw -Encoding UTF8
if ($syncClientText -like '*captures?fast=1*') {
    throw "SyncClient must not put query text inside appending(path:)."
}
foreach ($needle in @(
    'URLQueryItem(name: "fast", value: "1")',
    'URLComponents(url: bridgeBaseURL',
    'static let fastPush: TimeInterval = 3',
    'timeoutInterval: fast ? Timeout.fastPush : Timeout.normalPush',
    'request.timeoutInterval = timeoutInterval',
    'validateHTTPResponse(response, data: data)',
    'BridgeErrorEnvelope',
    'JSONDecoder.captureDecoder.decode(BridgeErrorEnvelope.self',
    'bridgeMessage',
    'SyncClientHTTPError',
    'statusCode == 401',
    'Bridge authentication failed (401). Check Bridge Token.',
    'Data(data.prefix(500))',
    'Bridge request failed with HTTP'
)) {
    if ($syncClientText -notlike "*$needle*") {
        throw "SyncClient missing expected URL construction: $needle"
    }
}
foreach ($needle in @(
    "struct SyncPushResult",
    "var item: CaptureItem?"
)) {
    if (-not $syncClientText.Contains($needle)) {
        throw "SyncClient missing enriched push result support: $needle"
    }
}

$captureFileStoreText = Get-Content -LiteralPath (Join-Path $repoRoot "Shared\CaptureFileStore.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "normalizedURLKey",
    "components.fragment = nil",
    "items.remove(at: existingIndex)",
    "FileManager.default.createDirectory",
    "lockURL",
    "withFileLock",
    "flock(handle.fileDescriptor, LOCK_EX)",
    "flock(handle.fileDescriptor, LOCK_UN)",
    "loadUnlocked",
    "saveUnlocked",
    "static func update",
    "@discardableResult",
    "static func append(_ item: CaptureItem) throws -> CaptureItem",
    "if item.status == .queued",
    "existing.status = .queued",
    "existing.syncError = nil",
    "return existing",
    "return item",
    "isPlaceholderTitle"
)) {
    if (-not $captureFileStoreText.Contains($needle)) {
        throw "CaptureFileStore missing queue durability/deduplication logic: $needle"
    }
}
$duplicateQueuedPattern = [regex]::Escape("if let existingIndex = items.firstIndex") + "[\s\S]*?" + [regex]::Escape("if item.status == .queued") + "[\s\S]*?" + [regex]::Escape("existing.status = .queued") + "[\s\S]*?" + [regex]::Escape("existing.syncError = nil") + "[\s\S]*?" + [regex]::Escape("return existing")
if (-not [regex]::IsMatch($captureFileStoreText, $duplicateQueuedPattern)) {
    throw "CaptureFileStore must requeue duplicate shared links before returning existing item."
}

$captureItemText = Get-Content -LiteralPath (Join-Path $repoRoot "Shared\CaptureItem.swift") -Raw -Encoding UTF8
foreach ($needle in @("case deleted", '"' + $pendingDeleteLabel + '"', "lastMetadataRefreshAttemptAt")) {
    if (-not $captureItemText.Contains($needle)) {
        throw "CaptureItem missing pending-delete status support: $needle"
    }
}

$captureSyncRunnerText = Get-Content -LiteralPath (Join-Path $repoRoot "Shared\CaptureSyncRunner.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "enrichSyncedMissingMetadata",
    "shouldEnrichSyncedItem",
    "client.refreshMetadata",
    "lastMetadataRefreshAttemptAt",
    "status == .deleted",
    "client.deleteRemoteNote",
    "items.remove(at: index)",
    "items[index].status != .deleted",
    "reconcileWithLatestStore",
    "var finalItems = items",
    "let merged = reconcileWithLatestStore",
    "finalItems = merged",
    "return merged",
    "let queuedCount = finalItems.filter",
    "items[index] = result.item ?? enriched",
    "items[index] = result.item ?? items[index]",
    "prioritizedIDs: [UUID] = []",
    "private static func prioritize",
    "var seenIDs = Set<UUID>()",
    "let uniqueIDs = ids.filter { seenIDs.insert(`$0).inserted }",
    "let idSet = Set(uniqueIDs)",
    "return prioritized + remaining",
    "CaptureFileStore.update",
    "latestItems: latestItems",
    "latest.updatedAt > original.updatedAt",
    "deletedIDs.contains(latest.id)",
    "merged.append(working)",
    "Task.isCancelled",
    "lastError ="
)) {
    if (-not $captureSyncRunnerText.Contains($needle)) {
        throw "CaptureSyncRunner missing pending-delete sync support: $needle"
    }
}
$finalQueueCountPattern = [regex]::Escape("var finalItems = items") + "[\s\S]*?" + [regex]::Escape("let merged = reconcileWithLatestStore") + "[\s\S]*?" + [regex]::Escape("finalItems = merged") + "[\s\S]*?" + [regex]::Escape("let queuedCount = finalItems.filter")
if (-not [regex]::IsMatch($captureSyncRunnerText, $finalQueueCountPattern)) {
    throw "CaptureSyncRunner queuedCount must be based on the reconciled final store state."
}
$invalidBridgeQueueCountPattern = [regex]::Escape('guard let baseURL = URL(string: bridgeAddress) else {') + "[\s\S]*?" + [regex]::Escape("var finalItems = items") + "[\s\S]*?" + [regex]::Escape("let queuedCount = finalItems.filter") + "[\s\S]*?" + [regex]::Escape("return CaptureSyncSummary(syncedCount: 0, queuedCount: queuedCount, lastError: errorMessage)")
if (-not [regex]::IsMatch($captureSyncRunnerText, $invalidBridgeQueueCountPattern)) {
    throw "CaptureSyncRunner invalid Bridge URL branch must report queuedCount from the reconciled final store state."
}

$bridgeText = Get-Content -LiteralPath (Join-Path $repoRoot "Bridge\obsidian_bridge.py") -Raw -Encoding UTF8
foreach ($needle in @(
    "write_error_json",
    '"ok": False',
    '"item": item',
    '"code": code',
    '"message": message',
    "UNAUTHORIZED",
    "BRIDGE_ERROR",
    "NOT_FOUND",
    "should_replace_summary",
    "ensure_agents_rules",
    "write_ai_learning_context",
    $aiContextFile,
    "Counter(",
    "metadata.get(`"description`") and should_replace_summary",
    "item[`"draftMarkdown`"] = fallback_markdown(item)",
    "remove_note_from_indexes(root_for_indexes, note_path)",
    "matches_domain(host",
    "content_text",
    "transcript_text",
    "metadata.get('transcript')",
    "iesdouyin.com",
    "bili2233.cn",
    "placeholder_markers",
    "summary_text = first_sentence(description)"
)) {
    if (-not $bridgeText.Contains($needle)) {
        throw "Bridge missing placeholder summary replacement support: $needle"
    }
}

$captureMetadataText = Get-Content -LiteralPath (Join-Path $repoRoot "Shared\CaptureMetadata.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "var title: String? = nil",
    "var transcript: String?",
    "var contentText: String?",
    "var transcriptText: String?",
    'case contentText = "content_text"',
    "init(from decoder: Decoder) throws",
    "func encode(to encoder: Encoder) throws",
    "decodeFlexibleDoubleIfPresent",
    "decodeFlexibleIntIfPresent",
    "decodeURLIfPresent",
    "decodeStringIfPresent",
    "thumbnail?.absoluteString",
    "webpageURL?.absoluteString",
    '["http", "https"].contains(scheme)',
    "url.host != nil"
)) {
    if (-not $captureMetadataText.Contains($needle)) {
        throw "CaptureMetadata missing transcript/content text support: $needle"
    }
}
$metadataFlexiblePattern = [regex]::Escape("duration = try container.decodeFlexibleDoubleIfPresent(.duration)") + "[\s\S]*?" + [regex]::Escape("viewCount = try container.decodeFlexibleIntIfPresent(.viewCount)") + "[\s\S]*?" + [regex]::Escape("thumbnail = try container.decodeURLIfPresent(.thumbnail)")
if (-not [regex]::IsMatch($captureMetadataText, $metadataFlexiblePattern)) {
    throw "CaptureMetadata must use flexible decoders for Bridge metadata."
}
$metadataURLPattern = [regex]::Escape("func decodeURLIfPresent(_ key: Key) throws -> URL?") + "[\s\S]*?" + [regex]::Escape('["http", "https"].contains(scheme)') + "[\s\S]*?" + [regex]::Escape("url.host != nil")
if (-not [regex]::IsMatch($captureMetadataText, $metadataURLPattern)) {
    throw "CaptureMetadata must only accept absolute http/https metadata URLs."
}

$captureListModelText = Get-Content -LiteralPath (Join-Path $repoRoot "App\CaptureListModel.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "clearLastError",
    "func add(urlText: String) -> Bool",
    "SupportedShareURL.isSupported(url)",
    "func importPairing(url: URL) async",
    "CaptureSettingsStore.applyPairingURL(url)",
    "return true",
    "return false",
    "var item = CaptureItem(url: url)",
    "try CaptureFileStore.append(item)",
    "private var syncAgainAfterCurrent = false",
    "if isSyncing",
    "syncAgainAfterCurrent = true",
    "repeat {",
    "} while syncAgainAfterCurrent",
    "runForegroundSyncLoop",
    "Task.sleep(for: .seconds(60))",
    "await refreshHealth()",
    "await syncIfPossible()",
    "func delete(ids: [UUID])",
    'items.firstIndex { $0.id == id }',
    "var deletedIDs = Set<UUID>()",
    "deletedIDs.insert(item.id)",
    "persist(deletedIDs: deletedIDs)",
    "CaptureFileStore.update",
    "mergeCurrentSnapshot",
    "let snapshotByID = Dictionary",
    "deletedIDs.contains(latestItem.id)",
    "snapshotItem.updatedAt >= latestItem.updatedAt",
    "merged.append(snapshotItem)",
    "enrichSyncedMissingMetadata: true",
    "metadata == nil",
    "lastMetadataRefreshAttemptAt",
    "item.status == .synced || item.status == .deleted",
    "pendingDelete.status = .deleted",
    $pendingDeleteQueued,
    "items[offset] = pendingDelete",
    $pendingDeleteInProgress,
    "updated.status = .queued",
    "updated.syncError = nil"
)) {
    if (-not $captureListModelText.Contains($needle)) {
        throw "CaptureListModel missing offline delete queue support: $needle"
    }
}
$addQueuedPattern = [regex]::Escape("var item = CaptureItem(url: url)") + "[\s\S]*?" + [regex]::Escape("item.status = .queued") + "[\s\S]*?" + [regex]::Escape("try CaptureFileStore.append(item)")
if (-not [regex]::IsMatch($captureListModelText, $addQueuedPattern)) {
    throw "CaptureListModel must mark manually added links as queued before saving."
}
$metadataQueuedPattern = [regex]::Escape("var updated = try await client.refreshMetadata(for: item)") + "[\s\S]*?" + [regex]::Escape("updated.status = .queued") + "[\s\S]*?" + [regex]::Escape("updated.syncError = nil") + "[\s\S]*?" + [regex]::Escape("save(updated)")
if (-not [regex]::IsMatch($captureListModelText, $metadataQueuedPattern)) {
    throw "CaptureListModel must queue refreshed metadata before saving."
}

$supportedShareURLText = Get-Content -LiteralPath (Join-Path $repoRoot "Shared\SupportedShareURL.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "enum SupportedShareURL",
    "static func isSupported(_ url: URL) -> Bool",
    '["http", "https"].contains(scheme)',
    "url.host != nil"
)) {
    if (-not $supportedShareURLText.Contains($needle)) {
        throw "SupportedShareURL must restrict intake to absolute web URLs: $needle"
    }
}

$contentViewText = Get-Content -LiteralPath (Join-Path $repoRoot "App\ContentView.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "model.lastError",
    "model.clearLastError()",
    "await model.runForegroundSyncLoop()",
    "if model.add(urlText: pastedURL)",
    "model.save(updated)",
    "let updated = await model.regenerateDrafts(for: item)",
    "let updated = await model.refreshMetadata(for: item)",
    ".onOpenURL { url in",
    "await model.importPairing(url: url)",
    "searchText",
    "visibleItems",
    "searchableText(for: item)",
    "deleteVisibleItems",
    "model.delete(ids: ids)",
    "metadata?.transcriptText",
    "Task { await model.syncQueued() }",
    "exclamationmark.triangle",
    "xmark.circle.fill",
    "CaptureThumbnailView(url: thumbnail)",
    "item.metadata?.thumbnail"
)) {
    if (-not $contentViewText.Contains($needle)) {
        throw "ContentView missing global sync error visibility: $needle"
    }
}
$syncQueuedTriggerCount = ([regex]::Matches($contentViewText, [regex]::Escape("Task { await model.syncQueued() }"))).Count
if ($syncQueuedTriggerCount -lt 3) {
    throw "ContentView must trigger immediate sync after add, after editor save, and from toolbar."
}
$regenerateSyncPattern = [regex]::Escape("let updated = await model.regenerateDrafts(for: item)") + "[\s\S]*?" + [regex]::Escape("await model.syncQueued()") + "[\s\S]*?" + [regex]::Escape("return updated")
if (-not [regex]::IsMatch($contentViewText, $regenerateSyncPattern)) {
    throw "ContentView must sync immediately after regenerating drafts."
}
$metadataSyncPattern = [regex]::Escape("let updated = await model.refreshMetadata(for: item)") + "[\s\S]*?" + [regex]::Escape("await model.syncQueued()") + "[\s\S]*?" + [regex]::Escape("return updated")
if (-not [regex]::IsMatch($contentViewText, $metadataSyncPattern)) {
    throw "ContentView must sync immediately after refreshing metadata."
}
if (-not $contentViewText.Contains(".searchable(text: `$searchText")) {
    throw "ContentView missing searchable list support."
}

$thumbnailViewText = Get-Content -LiteralPath (Join-Path $repoRoot "App\CaptureThumbnailView.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "AsyncImage(url: url",
    "scaledToFill()",
    "play.rectangle",
    "aspectRatio(16 / 9"
)) {
    if (-not $thumbnailViewText.Contains($needle)) {
        throw "CaptureThumbnailView missing expected async thumbnail rendering: $needle"
    }
}

$captureEditorViewText = Get-Content -LiteralPath (Join-Path $repoRoot "App\CaptureEditorView.swift") -Raw -Encoding UTF8
$transcriptHeadingText = New-TextFromCodePoints @(35,35,32,35270,39057,20869,23481,47,21475,25773,36716,20889)
$keyPointsHeadingText = New-TextFromCodePoints @(35,35,32,20851,38190,35266,28857)
foreach ($needle in @(
    "DraftDisplayMode",
    "originalSummary",
    'TextEditor(text: $item.summary)',
    "MarkdownPreviewView(markdown: item.draftMarkdown)",
    ".pickerStyle(.segmented)",
    "MarkdownPreviewLine",
    'hasPrefix("## ")',
    'TextEditor(text: $item.draftMarkdown)',
    "CaptureThumbnailView(url: thumbnail)",
    "item.metadata?.webpageURL ?? item.url",
    'systemImage: "safari"',
    "item.metadata?.transcriptText",
    "transcriptBinding",
    "TextEditor(text: transcriptBinding)",
    "CaptureMetadata()",
    "markdownReplacingTranscript",
    "item.draftMarkdown = markdownReplacingTranscript",
    "item.summary != originalSummary",
    $transcriptHeadingText,
    $keyPointsHeadingText
)) {
    if (-not $captureEditorViewText.Contains($needle)) {
        throw "CaptureEditorView missing Markdown preview/edit toggle support: $needle"
    }
}

$shareExtensionText = Get-Content -LiteralPath (Join-Path $repoRoot "ShareExtension\ShareViewController.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "statusLabel",
    "detailLabel",
    "UIActivityIndicatorView",
    "setupStatusView",
    "updateStatus(",
    "summary.lastError == nil",
    "else {",
    "finishAfterStatusDelay",
    "extensionItemTitles(from: extensionItems)",
    "item.attributedTitle?.string",
    "item.attributedContentText?.string",
    "UTType.propertyList.identifier",
    "extractPropertyListContent",
    "urls(in: text)",
    "matches(in: text, range: range)",
    "filter { SupportedShareURL.isSupported(`$0) }",
    "capturedURLs.append(contentsOf: urls)",
    "var savedIDs: [UUID] = []",
    "var item = CaptureItem(url: url, title: title, sourceApp: `"Share Extension`")",
    "item.status = .queued",
    "let savedItem = try CaptureFileStore.append",
    "savedIDs.append(savedItem.id)",
    "syncAndFinish(prioritizedIDs: savedIDs)",
    "let maxItemsToSync = max(3, prioritizedIDs.count)",
    "maxItems: maxItemsToSync",
    "prioritizedIDs: prioritizedIDs",
    "let uniqueURLs = Self.uniqueURLs(capturedURLs)",
    "for (index, url) in uniqueURLs.enumerated()",
    "guard SupportedShareURL.isSupported(url) else",
    "capturedTitles.indices.contains(index)",
    "cleanTitle",
    "uniqueURLs",
    "guard !uniqueURLs.isEmpty else",
    "noURLFoundError",
    "ShareToObsidian.ShareExtension",
    "NSLocalizedDescriptionKey",
    "detectedURLs",
    "urls.append(contentsOf: detectedURLs)",
    "NSExtensionJavaScriptPreprocessingResultsKey",
    "documentURL",
    "webpageURL"
)) {
    if (-not $shareExtensionText.Contains($needle)) {
        throw "Share extension missing property-list webpage share support: $needle"
    }
}
$shareQueuedPattern = [regex]::Escape("var item = CaptureItem(url: url, title: title, sourceApp: `"Share Extension`")") + "[\s\S]*?" + [regex]::Escape("item.status = .queued") + "[\s\S]*?" + [regex]::Escape("let savedItem = try CaptureFileStore.append(item)")
if (-not [regex]::IsMatch($shareExtensionText, $shareQueuedPattern)) {
    throw "Share extension must mark shared links as queued before saving."
}

$platformDetectorText = Get-Content -LiteralPath (Join-Path $repoRoot "Shared\PlatformDetector.swift") -Raw -Encoding UTF8
foreach ($needle in @(
    "matches(host",
    "iesdouyin.com",
    "amemv.com",
    "bili2233.cn",
    "hasSuffix"
)) {
    if (-not $platformDetectorText.Contains($needle)) {
        throw "PlatformDetector missing expected platform domain support: $needle"
    }
}

$markdownGeneratorText = Get-Content -LiteralPath (Join-Path $repoRoot "Shared\MarkdownGenerator.swift") -Raw -Encoding UTF8
foreach ($needle in @($pendingSummary, "## $coreContent", "## $videoIntro", "## $nextActions", $mobileFavorites)) {
    if ($markdownGeneratorText -notlike "*$needle*") {
        throw "MarkdownGenerator missing readable Chinese template text: $needle"
    }
}
$badNeedles = @(
    @(23536,21678,24385),
    @(32457,35826,23017),
    @(37824,24816,26828),
    @(37647,20905,26271),
    @(29785,21979)
)
foreach ($codePoints in $badNeedles) {
    $badNeedle = New-TextFromCodePoints $codePoints
    if ($markdownGeneratorText -like "*$badNeedle*") {
        throw "MarkdownGenerator contains mojibake-looking text: $badNeedle"
    }
}
Write-Host "iOS static project check passed."

Write-Host "VERIFY_WINDOWS_BRIDGE_OK"
