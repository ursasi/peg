#!/usr/bin/env bash
# Builds Peg.app. Uses swiftc directly because the SwiftPM shipped with the
# Command Line Tools on this machine is broken (BuildServerProtocol mismatch).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Peg.app"
BIN="$APP/Contents/MacOS/Peg"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "compiling for $TARGET"
swiftc -O \
    -swift-version 5 \
    -target "$TARGET" \
    -o "$BIN" \
    $(find Sources/Peg -name '*.swift')

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Peg</string>
    <key>CFBundleDisplayName</key>       <string>Peg</string>
    <key>CFBundleExecutable</key>        <string>Peg</string>
    <key>CFBundleIdentifier</key>        <string>com.zhangshuohua.peg</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>MIT. Built for personal use.</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Prefer a real signing identity: TCC remembers Screen Recording per identity,
# so re-granting after every rebuild is only necessary with ad-hoc signing.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"/\1/p' | head -1)"
if [ -n "${IDENTITY}" ]; then
    codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || \
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "built $APP"
