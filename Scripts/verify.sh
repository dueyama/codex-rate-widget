#!/bin/bash

set -euo pipefail
unset GREP_OPTIONS

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "error: $*" >&2
  exit 1
}

command -v xcodebuild >/dev/null || fail "Xcode command-line tools are required"
command -v plutil >/dev/null || fail "plutil is required"
bash -n \
  Scripts/verify.sh \
  Scripts/test-public-audits.sh \
  Scripts/public-audit-common.sh \
  Scripts/audit-public-tree.sh \
  Scripts/audit-public-history.sh \
  Scripts/configure-local-signing.sh

echo "Checking repository hygiene..."
Scripts/audit-public-tree.sh
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git diff --check
  git diff --cached --check
fi

echo "Testing public audit fail-closed behavior..."
Scripts/test-public-audits.sh

grep -Fq '#include? "Local.xcconfig"' Config/Shared.xcconfig \
  || fail "Shared.xcconfig must retain the optional local signing override"
grep -Eq '^CODEX_RATE_WIDGET_DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*$' Config/Shared.xcconfig \
  || fail "the tracked development Team setting must remain empty"
[[ "$(grep -Fc 'PRODUCT_BUNDLE_IDENTIFIER = "$(CODEX_RATE_WIDGET_BUNDLE_ID)";' CodexRateWidget.xcodeproj/project.pbxproj)" -eq 2 ]] \
  || fail "both app build configurations must use the shared app bundle identifier"
[[ "$(grep -Fc 'PRODUCT_BUNDLE_IDENTIFIER = "$(CODEX_RATE_WIDGET_BUNDLE_ID).Widget";' CodexRateWidget.xcodeproj/project.pbxproj)" -eq 2 ]] \
  || fail "both widget build configurations must derive the extension bundle identifier"
[[ "$(grep -Fc 'PRODUCT_BUNDLE_IDENTIFIER = "$(CODEX_RATE_WIDGET_BUNDLE_ID).Tests";' CodexRateWidget.xcodeproj/project.pbxproj)" -eq 2 ]] \
  || fail "both test build configurations must derive the test bundle identifier"
if grep -Eq '^[[:space:]]+(MARKETING_VERSION|CURRENT_PROJECT_VERSION)[[:space:]]*=' CodexRateWidget.xcodeproj/project.pbxproj; then
  fail "app and widget versions must be defined only in Config/Shared.xcconfig"
fi

MARKETING_VERSION="$(sed -n 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*//p' Config/Shared.xcconfig)"
CURRENT_PROJECT_VERSION="$(sed -n 's/^CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*//p' Config/Shared.xcconfig)"
PUBLIC_BUNDLE_ID="com.example.CodexRateWidget"
[[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
  || fail "MARKETING_VERSION must be a dotted numeric version"
[[ "$CURRENT_PROJECT_VERSION" =~ ^[1-9][0-9]*$ ]] \
  || fail "CURRENT_PROJECT_VERSION must be a positive integer"
for app_group_file in \
  CodexRateWidget/App/Info.plist \
  CodexRateWidget/App/CodexRateWidget.entitlements \
  CodexRateWidget/Widget/Info.plist \
  CodexRateWidget/Widget/CodexRateWidgetExtension.entitlements; do
  grep -Fq '$(TeamIdentifierPrefix)$(CODEX_RATE_WIDGET_BUNDLE_ID)' "$app_group_file" \
    || fail "the App Group in $app_group_file must derive from the signing Team and shared bundle identifier"
done

echo "Checking localization and asset metadata..."
grep -Eq '"sourceLanguage"[[:space:]]*:[[:space:]]*"en"' CodexRateWidget/Shared/Localizable.xcstrings \
  || fail "English must remain the source language"
grep -q '"ja"' CodexRateWidget/Shared/Localizable.xcstrings \
  || fail "Japanese localization is missing"
test -f CodexRateWidget/App/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png \
  || fail "1024px AppIcon source is missing"

echo "Building and testing without a personal signing identity..."
ARCH="$(uname -m)"
DERIVED_DATA_PATH="${CODEX_RATE_WIDGET_DERIVED_DATA_PATH:-$ROOT/DerivedData/Verification}"
xcodebuild test \
  -project CodexRateWidget.xcodeproj \
  -scheme CodexRateWidget \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination "platform=macOS,arch=${ARCH}" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CODEX_RATE_WIDGET_BUNDLE_ID="$PUBLIC_BUNDLE_ID" \
  CODEX_RATE_WIDGET_DEVELOPMENT_TEAM= \
  DEVELOPMENT_TEAM=

APP_INFO="$DERIVED_DATA_PATH/Build/Products/Debug/CodexRateWidget.app/Contents/Info.plist"
WIDGET_INFO="$DERIVED_DATA_PATH/Build/Products/Debug/CodexRateWidget.app/Contents/PlugIns/CodexRateWidgetExtension.appex/Contents/Info.plist"
test -f "$APP_INFO" || fail "the verification app Info.plist is missing"
test -f "$WIDGET_INFO" || fail "the embedded widget Info.plist is missing"

APP_MARKETING_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_INFO")"
WIDGET_MARKETING_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$WIDGET_INFO")"
APP_BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "$APP_INFO")"
WIDGET_BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "$WIDGET_INFO")"
APP_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_INFO")"
WIDGET_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$WIDGET_INFO")"
APP_GROUP="$(plutil -extract CodexRateWidgetAppGroup raw -o - "$APP_INFO")"
WIDGET_GROUP="$(plutil -extract CodexRateWidgetAppGroup raw -o - "$WIDGET_INFO")"

[[ "$APP_MARKETING_VERSION" == "$MARKETING_VERSION" ]] \
  || fail "the built app marketing version does not match Shared.xcconfig"
[[ "$WIDGET_MARKETING_VERSION" == "$MARKETING_VERSION" ]] \
  || fail "the built widget marketing version does not match Shared.xcconfig"
[[ "$APP_BUILD_VERSION" == "$CURRENT_PROJECT_VERSION" ]] \
  || fail "the built app build number does not match Shared.xcconfig"
[[ "$WIDGET_BUILD_VERSION" == "$CURRENT_PROJECT_VERSION" ]] \
  || fail "the built widget build number does not match Shared.xcconfig"
[[ "$APP_BUNDLE_ID" == "$PUBLIC_BUNDLE_ID" ]] \
  || fail "the unsigned verification app must use the public placeholder bundle identifier"
[[ "$WIDGET_BUNDLE_ID" == "$PUBLIC_BUNDLE_ID.Widget" ]] \
  || fail "the unsigned verification widget must derive from the public placeholder bundle identifier"
[[ "$APP_GROUP" == "$WIDGET_GROUP" ]] \
  || fail "the built app and widget must resolve the same App Group"
[[ "$APP_GROUP" == *"$PUBLIC_BUNDLE_ID" ]] \
  || fail "the unsigned verification App Group must derive from the public placeholder bundle identifier"

echo "Verification succeeded."
