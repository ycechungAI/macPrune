#!/bin/zsh
# Builds Prune.app into ./build. Works with Command Line Tools alone (no Xcode needed).
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --build-system native
BIN="$(swift build -c release --build-system native --show-bin-path)/Prune"

APP=build/Prune.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Prune"
strip -x "$APP/Contents/MacOS/Prune"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Prune</string>
    <key>CFBundleDisplayName</key><string>Prune</string>
    <key>CFBundleIdentifier</key><string>com.ycechung.prune</string>
    <key>CFBundleExecutable</key><string>Prune</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
