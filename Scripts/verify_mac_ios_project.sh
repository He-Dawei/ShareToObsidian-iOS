#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT_NAME="ShareToObsidian"
APP_SCHEME="ShareToObsidian"
APP_BUNDLE_ID="com.hdwei.ShareToObsidian"
EXTENSION_NAME="ShareToObsidianShareExtension"
EXTENSION_BUNDLE_ID="com.hdwei.ShareToObsidian.ShareExtension"
APP_GROUP_ID="group.com.hdwei.ShareToObsidian"
DERIVED_DATA="${DERIVED_DATA:-$(mktemp -d "${TMPDIR:-/tmp}/share-to-obsidian-derived.XXXXXX")}"
PRODUCT_DIR="$DERIVED_DATA/Build/Products/Debug-iphonesimulator"
APP_BUNDLE="$PRODUCT_DIR/$PROJECT_NAME.app"
EXTENSION_BUNDLE="$APP_BUNDLE/PlugIns/$EXTENSION_NAME.appex"
VERIFY_DEVICE="${VERIFY_DEVICE:-0}"
DEVICE_DESTINATION="${DEVICE_DESTINATION:-generic/platform=iOS}"
DEVELOPMENT_TEAM_OVERRIDE="${DEVELOPMENT_TEAM:-}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is missing. Install with: brew install xcodegen" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is missing. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

if [[ ! -x /usr/libexec/PlistBuddy ]]; then
  echo "PlistBuddy is missing at /usr/libexec/PlistBuddy" >&2
  exit 1
fi

APP_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' App/ShareToObsidian.entitlements)"
if [[ "$APP_GROUP" != "$APP_GROUP_ID" ]]; then
  echo "Unexpected app App Group entitlement: $APP_GROUP" >&2
  exit 1
fi

EXTENSION_APP_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' ShareExtension/ShareExtension.entitlements)"
if [[ "$EXTENSION_APP_GROUP" != "$APP_GROUP_ID" ]]; then
  echo "Unexpected extension App Group entitlement: $EXTENSION_APP_GROUP" >&2
  exit 1
fi

APP_BG_MODE="$(/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes:0' App/Info.plist)"
if [[ "$APP_BG_MODE" != "fetch" ]]; then
  echo "App Info.plist must enable background fetch." >&2
  exit 1
fi

APP_BG_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :BGTaskSchedulerPermittedIdentifiers:0' App/Info.plist)"
if [[ "$APP_BG_IDENTIFIER" != "com.hdwei.ShareToObsidian.sync" ]]; then
  echo "App Info.plist has unexpected BG task identifier: $APP_BG_IDENTIFIER" >&2
  exit 1
fi

APP_URL_SCHEME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' App/Info.plist)"
if [[ "$APP_URL_SCHEME" != "sharetoobsidian" ]]; then
  echo "App Info.plist has unexpected pairing URL scheme: $APP_URL_SCHEME" >&2
  exit 1
fi

APP_LOCAL_NETWORK_TEXT="$(/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' App/Info.plist)"
EXT_LOCAL_NETWORK_TEXT="$(/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' ShareExtension/Info.plist)"
if [[ -z "$APP_LOCAL_NETWORK_TEXT" || -z "$EXT_LOCAL_NETWORK_TEXT" ]]; then
  echo "Both app and share extension must declare NSLocalNetworkUsageDescription." >&2
  exit 1
fi

SOURCE_EXTENSION_POINT="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' ShareExtension/Info.plist)"
if [[ "$SOURCE_EXTENSION_POINT" != "com.apple.share-services" ]]; then
  echo "ShareExtension Info.plist has unexpected extension point: $SOURCE_EXTENSION_POINT" >&2
  exit 1
fi

echo "Source plist and entitlement checks passed."

xcodegen generate

if [[ ! -d "$PROJECT_NAME.xcodeproj" ]]; then
  echo "$PROJECT_NAME.xcodeproj was not generated" >&2
  exit 1
fi

LIST_OUTPUT="$(xcodebuild -list -project "$PROJECT_NAME.xcodeproj")"
if ! grep -q "^[[:space:]]*$APP_SCHEME$" <<<"$LIST_OUTPUT"; then
  echo "Missing app scheme: $APP_SCHEME" >&2
  echo "$LIST_OUTPUT" >&2
  exit 1
fi

xcodebuild \
  -project "$PROJECT_NAME.xcodeproj" \
  -scheme "$APP_SCHEME" \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing built app bundle: $APP_BUNDLE" >&2
  exit 1
fi

if [[ ! -d "$EXTENSION_BUNDLE" ]]; then
  echo "Share Extension was not embedded at: $EXTENSION_BUNDLE" >&2
  exit 1
fi

BUILT_APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Info.plist")"
if [[ "$BUILT_APP_BUNDLE_ID" != "$APP_BUNDLE_ID" ]]; then
  echo "Unexpected app bundle id: $BUILT_APP_BUNDLE_ID" >&2
  exit 1
fi

BUILT_APP_URL_SCHEME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$APP_BUNDLE/Info.plist")"
if [[ "$BUILT_APP_URL_SCHEME" != "sharetoobsidian" ]]; then
  echo "Built app has unexpected pairing URL scheme: $BUILT_APP_URL_SCHEME" >&2
  exit 1
fi

BUILT_EXTENSION_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXTENSION_BUNDLE/Info.plist")"
if [[ "$BUILT_EXTENSION_BUNDLE_ID" != "$EXTENSION_BUNDLE_ID" ]]; then
  echo "Unexpected extension bundle id: $BUILT_EXTENSION_BUNDLE_ID" >&2
  exit 1
fi

EXTENSION_POINT="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$EXTENSION_BUNDLE/Info.plist")"
if [[ "$EXTENSION_POINT" != "com.apple.share-services" ]]; then
  echo "Unexpected extension point: $EXTENSION_POINT" >&2
  exit 1
fi

echo "Mac iOS simulator build passed."
echo "Verified app bundle: $APP_BUNDLE"
echo "Verified embedded Share Extension: $EXTENSION_BUNDLE"

if [[ "$VERIFY_DEVICE" == "1" ]]; then
  if [[ -z "$DEVELOPMENT_TEAM_OVERRIDE" ]]; then
    echo "VERIFY_DEVICE=1 requires DEVELOPMENT_TEAM=<Apple Team ID>." >&2
    exit 1
  fi

  xcodebuild \
    -project "$PROJECT_NAME.xcodeproj" \
    -scheme "$APP_SCHEME" \
    -configuration Debug \
    -destination "$DEVICE_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_OVERRIDE" \
    CODE_SIGNING_ALLOWED=YES \
    build

  DEVICE_PRODUCT_DIR="$DERIVED_DATA/Build/Products/Debug-iphoneos"
  DEVICE_APP_BUNDLE="$DEVICE_PRODUCT_DIR/$PROJECT_NAME.app"
  DEVICE_EXTENSION_BUNDLE="$DEVICE_APP_BUNDLE/PlugIns/$EXTENSION_NAME.appex"

  if [[ ! -d "$DEVICE_APP_BUNDLE" ]]; then
    echo "Missing device app bundle: $DEVICE_APP_BUNDLE" >&2
    exit 1
  fi
  if [[ ! -d "$DEVICE_EXTENSION_BUNDLE" ]]; then
    echo "Share Extension was not embedded for device build: $DEVICE_EXTENSION_BUNDLE" >&2
    exit 1
  fi

  echo "Mac iOS device build passed."
  echo "Verified device app bundle: $DEVICE_APP_BUNDLE"
  echo "Verified device Share Extension: $DEVICE_EXTENSION_BUNDLE"
fi
