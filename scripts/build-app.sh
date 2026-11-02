#!/bin/zsh
# Builds Prune.app into ./build. Works with Command Line Tools alone (no Xcode needed).
set -euo pipefail
cd "${0:A:h}/.."

# Test before build: a build that fails its tests never becomes an app (PRUNE_SKIP_TESTS=1 skips
# this, for scripts/ci.sh, which has just run them).
if [[ -z "${PRUNE_SKIP_TESTS:-}" ]]; then
    ./scripts/test.sh > /tmp/prune-test-$$.log 2>&1 || { tail -40 /tmp/prune-test-$$.log; rm -f /tmp/prune-test-$$.log; echo "Tests failed; not building." >&2; exit 1; }
    grep -E "Test run with|helper:" /tmp/prune-test-$$.log; rm -f /tmp/prune-test-$$.log
fi

swift build -c release --build-system native
BIN="$(swift build -c release --build-system native --show-bin-path)/Prune"

APP=build/Prune.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Prune"
strip -x "$APP/Contents/MacOS/Prune"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The firewall helper runs as root through the password prompt; root:wheel-style read-only copy.
cp Resources/firewall-helper.sh "$APP/Contents/Resources/firewall-helper.sh"
chmod 555 "$APP/Contents/Resources/firewall-helper.sh"

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
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
