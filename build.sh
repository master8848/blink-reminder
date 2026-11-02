#!/bin/bash
set -euo pipefail

APP_NAME="BlinkReminder"
APP_BUNDLE="$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
VERSION="${1:-1.1.2}"
MIN_OS="13.0"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"

mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Generate Icon if missing
if [ ! -f "BlinkReminder.icns" ]; then
    echo "Generating Icon..."
    swift GenerateIcon.swift

    if [ -f "icon.png" ]; then
        mkdir -p BlinkReminder.iconset

        sips -z 16 16     icon.png --out BlinkReminder.iconset/icon_16x16.png
        sips -z 32 32     icon.png --out BlinkReminder.iconset/icon_16x16@2x.png
        sips -z 32 32     icon.png --out BlinkReminder.iconset/icon_32x32.png
        sips -z 64 64     icon.png --out BlinkReminder.iconset/icon_32x32@2x.png
        sips -z 128 128   icon.png --out BlinkReminder.iconset/icon_128x128.png
        sips -z 256 256   icon.png --out BlinkReminder.iconset/icon_128x128@2x.png
        sips -z 256 256   icon.png --out BlinkReminder.iconset/icon_256x256.png
        sips -z 512 512   icon.png --out BlinkReminder.iconset/icon_256x256@2x.png
        sips -z 512 512   icon.png --out BlinkReminder.iconset/icon_512x512.png
        sips -z 1024 1024 icon.png --out BlinkReminder.iconset/icon_512x512@2x.png

        iconutil -c icns BlinkReminder.iconset

        rm icon.png
        rm -rf BlinkReminder.iconset
        echo "Icon generated successfully."
    else
        echo "Warning: GenerateIcon.swift failed or did not produce icon.png"
    fi
fi

if [ -f "BlinkReminder.icns" ]; then
    cp "BlinkReminder.icns" "$RESOURCES/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.agamtech.blinkreminder</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_OS</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
</dict>
</plist>
EOF

# Compile universal binary (arm64 + x86_64) for macOS 13+.
echo "Compiling $APP_NAME v$VERSION (min macOS $MIN_OS, arm64+x86_64)..."
TMPDIR_BUILD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BUILD"' EXIT

swiftc -O -whole-module-optimization -sdk "$SDK_PATH" \
    -target "arm64-apple-macosx$MIN_OS" \
    -parse-as-library \
    BlinkReminder.swift \
    -o "$TMPDIR_BUILD/$APP_NAME-arm64"

swiftc -O -whole-module-optimization -sdk "$SDK_PATH" \
    -target "x86_64-apple-macosx$MIN_OS" \
    -parse-as-library \
    BlinkReminder.swift \
    -o "$TMPDIR_BUILD/$APP_NAME-x64"

lipo -create "$TMPDIR_BUILD/$APP_NAME-arm64" "$TMPDIR_BUILD/$APP_NAME-x64" -output "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

codesign --force --deep --sign - "$APP_BUNDLE"

rm -f "$APP_NAME.zip"
zip -qr "$APP_NAME.zip" "$APP_BUNDLE"

echo "Build complete: $APP_BUNDLE (v$VERSION)"
lipo -info "$MACOS/$APP_NAME"
shasum -a 256 "$APP_NAME.zip"
