#!/usr/bin/env bash
# Builds Mahlas.app into ./build. Works with just the Xcode Command Line Tools.
#   ./scripts/build-app.sh            # release build
#   ./scripts/build-app.sh --install  # also copy to /Applications
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Mahlas.app"
VERSION="1.0.0"
ARCH="$(uname -m)"

# Pick an SDK whose Swift version matches the installed compiler. Newer beta
# SDKs shipped next to an older compiler fail to import the stdlib.
pick_sdk() {
  local sdks_dir
  sdks_dir="$(xcrun --show-sdk-platform-path 2>/dev/null)/Developer/SDKs"
  [ -d "$sdks_dir" ] || sdks_dir="/Library/Developer/CommandLineTools/SDKs"
  local compiler
  compiler="$(swiftc --version 2>&1 | sed -nE 's/.*Apple Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)"
  for sdk in $(ls -d "$sdks_dir"/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
    local iface="$sdk/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
    [ -f "$iface" ] || iface="$(ls "$sdk"/usr/lib/swift/Swift.swiftmodule/*.swiftinterface 2>/dev/null | head -1)"
    if grep -q "swift-compiler-version: Apple Swift version $compiler" "$iface" 2>/dev/null; then echo "$sdk"; return; fi
  done
  xcrun --show-sdk-path
}

SDK="$(pick_sdk)"
echo "› SDK: $SDK"

echo "› Compiling ($ARCH)…"
mkdir -p "$ROOT/build/obj"
swiftc -O -wmo -swift-version 5 \
  -sdk "$SDK" \
  -target "$ARCH-apple-macos15.0" \
  -parse-as-library -module-name Mahlas \
  -file-prefix-map "$ROOT=." \
  $(find Sources -name '*.swift') \
  -o "$ROOT/build/obj/Mahlas"

echo "› Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/build/obj/Mahlas" "$APP/Contents/MacOS/Mahlas"
cp -R "$ROOT/Sources/Mahlas/Resources/Fonts" "$APP/Contents/Resources/Fonts"

echo "› Rendering icon…"
ICONSET="$ROOT/build/obj/Mahlas.iconset"
rm -rf "$ICONSET"
swift -sdk "$SDK" "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Mahlas.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mahlas</string>
  <key>CFBundleDisplayName</key><string>Mahlas</string>
  <key>CFBundleIdentifier</key><string>com.mahlas.app</string>
  <key>CFBundleExecutable</key><string>Mahlas</string>
  <key>CFBundleIconFile</key><string>Mahlas</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>tr</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Mahlas</string>
</dict>
</plist>
PLIST

echo "› Signing (ad-hoc, virtualization entitlement)…"
ENT="$ROOT/build/obj/Mahlas.entitlements"
cat > "$ENT" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.virtualization</key><true/>
  <key>com.apple.security.network.client</key><true/>
</dict>
</plist>
XML
codesign --force --deep --options runtime --entitlements "$ENT" --sign - "$APP" >/dev/null

echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Mahlas.app
  cp -R "$APP" /Applications/
  echo "✓ Installed to /Applications/Mahlas.app"
fi
