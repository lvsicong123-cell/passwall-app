#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(<"$ROOT/VERSION")"
APP="$ROOT/.build/Passwall.app"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/passwall-pkg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == com.passwall.mac ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]]
[[ "$(lipo -archs "$APP/Contents/MacOS/PasswallMac")" == arm64 ]]
codesign --verify --deep --strict "$APP"
mkdir -p "$WORK/root/Applications" "$ROOT/dist"
ditto --norsrc "$APP" "$WORK/root/Applications/Passwall.app"
pkgbuild --root "$WORK/root" --component-plist "$ROOT/script/macos-components.plist" \
  --identifier com.passwall.mac.pkg --version "$VERSION" --install-location / \
  --ownership recommended "$WORK/Passwall-component.pkg"
productbuild --synthesize --package "$WORK/Passwall-component.pkg" "$WORK/Distribution.xml"
# Use XML parsing so generated package metadata is retained without text substitution.
/usr/bin/ruby -r rexml/document -e '
  path = ARGV.fetch(0)
  doc = REXML::Document.new(File.read(path))
  root = doc.root
  root.add_element("title").text = "Passwall"
  root.elements["options"].add_attributes("customize" => "never", "hostArchitectures" => "arm64")
  root.add_element("domains", {"enable_anywhere" => "false", "enable_currentUserHome" => "false", "enable_localSystem" => "true"})
  root.add_element("volume-check").add_element("allowed-os-versions").add_element("os-version", {"min" => "14.0"})
  root.elements.each("pkg-ref") { |ref| ref.add_element("must-close").add_element("app", {"id" => "com.passwall.mac"}) if ref.attributes["version"] }
  File.write(path, doc.to_s)
' "$WORK/Distribution.xml"
productbuild --distribution "$WORK/Distribution.xml" --package-path "$WORK" "$ROOT/dist/Passwall.pkg"
pkgutil --expand-full "$ROOT/dist/Passwall.pkg" "$WORK/expanded"
codesign --verify --deep --strict "$WORK/expanded/Passwall-component.pkg/Payload/Applications/Passwall.app"
diff -qr "$APP" "$WORK/expanded/Passwall-component.pkg/Payload/Applications/Passwall.app"
(cd "$ROOT/dist" && shasum -a 256 Passwall.pkg > Passwall.pkg.sha256)
echo "Unsigned PKG created; this is not Gatekeeper or first-install acceptance."
