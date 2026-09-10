#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PasswallMac"
BUNDLE_NAME="Passwall"
BUNDLE_ID="com.passwall.mac"
MIN_SYSTEM_VERSION="14.0"
DESIGNATED_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\""
SIGNING_IDENTITY="${PASSWALL_SIGNING_IDENTITY:--}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(<"$ROOT_DIR/VERSION")"
DIST_DIR="$ROOT_DIR/dist"
if [[ "$MODE" == "--package" || "$MODE" == "package" ]]; then
  APP_BUNDLE="$ROOT_DIR/.build/$BUNDLE_NAME.app"
else
  APP_BUNDLE="$HOME/Applications/$BUNDLE_NAME.app"
fi
DIST_APP_BUNDLE="$DIST_DIR/$BUNDLE_NAME.app"
DIST_ARCHIVE="$DIST_DIR/$BUNDLE_NAME.zip"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Assets/Passwall.icns"
MENU_BAR_ICON_SOURCE="$ROOT_DIR/Assets/PasswallMenuBarTemplate.png"

if [[ "$MODE" != "--package" && "$MODE" != "package" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.build/ModuleCache" "$ROOT_DIR/.build/swiftpm-home" "$HOME/Applications" "$DIST_DIR"
DEVELOPMENT_HOME="$ROOT_DIR/.build/swiftpm-home"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/ModuleCache"
HOME="$DEVELOPMENT_HOME" swift build --disable-sandbox --product "$APP_NAME"
BUILD_BINARY="$(HOME="$DEVELOPMENT_HOME" swift build --disable-sandbox --show-bin-path)/$APP_NAME"
RESOURCE_BUNDLE="$(dirname "$BUILD_BINARY")/Passwall_PasswallMac.bundle"

if [[ -d "$APP_BUNDLE" ]]; then
  EXISTING_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$EXISTING_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
    echo "error: refusing to replace unexpected app at $APP_BUNDLE" >&2
    exit 1
  fi
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ICON_SOURCE" "$APP_RESOURCES/Passwall.icns"
cp "$MENU_BAR_ICON_SOURCE" "$APP_RESOURCES/PasswallMenuBarTemplate.png"
cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/Passwall_PasswallMac.bundle"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Passwall</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleIconFile</key>
  <string>Passwall.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>Passwall uses trackpad and mouse input to control your paired Windows PC.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Passwall discovers nearby Windows PCs for secure device pairing.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_passwall._tcp</string>
  </array>
</dict>
</plist>
PLIST

xattr -cr "$APP_BUNDLE"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "warning: using the local-development ad-hoc signature" >&2
  echo "warning: set PASSWALL_SIGNING_IDENTITY to an Apple-issued identity for stable production signing" >&2
  codesign --force --sign - --identifier "$BUNDLE_ID" --requirements "$DESIGNATED_REQUIREMENT" "$APP_BUNDLE"
else
  if ! security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null; then
    echo "error: PASSWALL_SIGNING_IDENTITY is not a valid code-signing identity: $SIGNING_IDENTITY" >&2
    exit 1
  fi
  codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE"
fi
codesign --verify --deep --strict "$APP_BUNDLE"
rm -rf "$DIST_APP_BUNDLE"
rm -f "$DIST_ARCHIVE"
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$APP_BUNDLE" "$DIST_ARCHIVE"
VERIFY_DIR="$(mktemp -d "${TMPDIR%/}/passwall-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$DIST_ARCHIVE" "$VERIFY_DIR"
xattr -cr "$VERIFY_DIR/$BUNDLE_NAME.app"
codesign --verify --deep --strict "$VERIFY_DIR/$BUNDLE_NAME.app"
(cd "$DIST_DIR" && shasum -a 256 "$BUNDLE_NAME.zip" > "$BUNDLE_NAME.zip.sha256")
rm -rf "$VERIFY_DIR"
trap - EXIT

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --package|package)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    if PROCESS_OUTPUT="$(pgrep -x "$APP_NAME" 2>&1)"; then
      :
    elif [[ "$PROCESS_OUTPUT" == *"Cannot get process list"* || "$PROCESS_OUTPUT" == *"sysmon"* ]]; then
      echo "warning: process inspection is unavailable; launch was accepted by LaunchServices" >&2
    else
      echo "error: $APP_NAME did not remain running" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [run|--package|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
