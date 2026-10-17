#!/usr/bin/env bash
# Builds Peg.app. Prefers SwiftPM, falls back to a plain swiftc invocation if
# the toolchain's package manager is unusable.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"

APP="build/Peg.app"
rm -rf "$APP"
BIN="$APP/Contents/MacOS/Peg"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

COMPILED=""
if swift build -c "$CONFIG" >/tmp/peg-swiftpm.log 2>&1; then
    COMPILED="$(swift build -c "$CONFIG" --show-bin-path)/Peg"
    echo "built with SwiftPM ($CONFIG)"
else
    echo "SwiftPM failed, falling back to swiftc (see /tmp/peg-swiftpm.log)"
    mkdir -p build/bin
    swiftc -O -swift-version 5 -target "$TARGET" -o build/bin/Peg \
        $(find Sources/Peg -name '*.swift')
    COMPILED="build/bin/Peg"
fi

cp "$COMPILED" "$BIN"

# Generated icon: the mark lives in Tools/MakeIcon, not in a binary asset.
swiftc -O Tools/Design/PegMark.swift Tools/MakeIcon/main.swift \
    -o build/makeicon >/tmp/peg-icon.log 2>&1
if [ -x build/makeicon ] && build/makeicon "$APP/Contents/Resources" >/dev/null 2>&1; then
    echo "icon: generated"
else
    echo "icon: skipped (see Tools/MakeIcon/main.swift)"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Peg</string>
    <key>CFBundleDisplayName</key>       <string>Peg</string>
    <key>CFBundleExecutable</key>        <string>Peg</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleIdentifier</key>        <string>com.zhangshuohua.peg</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.4.0</string>
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
# `head` closes the pipe early, which under `pipefail` makes the whole
# substitution look like a failure and leaves IDENTITY empty.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"/\1/p' | sed -n '1p')"
if [ -n "${IDENTITY}" ]; then
    if ! codesign --force --sign "$IDENTITY" "$APP" 2>/tmp/peg-codesign.log; then
        echo "sign: could not sign with '$IDENTITY'"
        sed -n '1,5p' /tmp/peg-codesign.log
        codesign --force --sign - "$APP" || true
    fi
else
    codesign --force --sign - "$APP" || true
fi

echo "built $APP"
